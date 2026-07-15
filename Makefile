SHELL := /bin/bash
export AWS_PAGER :=
.DEFAULT_GOAL := help

help: ## show this help (default target)
	@echo "LiveHybrid Splunk cluster — make targets:" && echo
	@grep -hE '^[a-zA-Z][a-zA-Z0-9_-]*:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo && echo "Most targets need env=<prod|dev>; some need role=<role>."
########################################################################################################################
##
##  Makefile — top-level entry points for the LiveHybrid Splunk cluster.
##  Use `make terraform env=prod` to apply all layers in order (account → iam → cluster) per workspace.
##
########################################################################################################################
THIS_FILE := $(lastword $(MAKEFILE_LIST))
activate  = VIRTUAL_ENV_DISABLE_PROMPT=true . .venv/bin/activate;
pwd       := ${PWD}
dirname   := $(notdir ${PWD})

standard_terraform_layers := account iam cluster

SPLUNK_VERSION_LIST_URL := https://raw.githubusercontent.com/livehybrid/downloadSplunk/refs/heads/main/version.list

ensure-venv:
ifeq ($(wildcard .venv),)
	@$(MAKE) -f $(THIS_FILE) venv
endif

guard-%:
	@ if [ "${${*}}" = "" ]; then \
        echo "Environment variable $* not set"; \
        exit 1; \
    fi

venv:
	if [ -d .venv ]; then rm -rf .venv; fi
	python3.11 -m venv .venv --clear
	$(activate) pip3 install --upgrade pip

########################################################################################################################
## terraform
########################################################################################################################

terraform-clean:
	for layer in $(standard_terraform_layers); do \
		make -C terraform/layers/$$layer terraform-clean; \
	done

terraform: guard-env ## apply all layers in order (account -> iam -> cluster)
	for layer in $(standard_terraform_layers); do \
		env=$(env) make -C terraform/layers/$$layer terraform; \
	done

terraform-plan: guard-env ## plan all layers
	for layer in $(standard_terraform_layers); do \
		env=$(env) make -C terraform/layers/$$layer terraform-plan; \
	done

terraform-validate: guard-env ## validate all layers
	for layer in $(standard_terraform_layers); do \
		env=$(env) make -C terraform/layers/$$layer terraform-validate; \
	done

########################################################################################################################
## packer — builds the Splunk Enterprise AMI for the target workspace.
########################################################################################################################

packer-build-splunk: guard-env ## build the Splunk AMI
	$(MAKE) -C packer/splunk packer-build env=$(env)

packer-validate-splunk: guard-env ## validate the packer template
	$(MAKE) -C packer/splunk packer-validate env=$(env)

########################################################################################################################
## Splunk version list — refresh the cached release list and print the 10.x line.
########################################################################################################################

splunk-versions: ## list available Splunk 10.x versions
	@curl -fsSL $(SPLUNK_VERSION_LIST_URL) -o /tmp/splunk-versions.csv
	@echo "Splunk Enterprise 10.x:"
	@awk -F, '$$1 ~ /^10\./ {printf "  %s (build %s)\n", $$1, $$2}' /tmp/splunk-versions.csv

splunk-version-latest:
	@curl -fsSL $(SPLUNK_VERSION_LIST_URL) | awk -F, '$$1 ~ /^10\./ {v=$$1; b=$$2} END {printf "splunk_version = \"%s\"\nsplunk_build   = \"%s\"\n", v, b}'

########################################################################################################################
## infracost — repo-wide cost breakdown across both workspaces.
########################################################################################################################

infracost-breakdown: ## monthly cost breakdown (all projects)
	infracost breakdown --config-file=infracost.yml --format=table

infracost-diff:
	infracost diff --config-file=infracost.yml --compare-to=infracost-base.json --format=table

########################################################################################################################
## Recycle — terminate every Splunk instance in <env>. The ASGs immediately
##           launch fresh replacements from the latest launch template, so
##           this is the fast path to redeploy after an AMI rebuild or a
##           bootstrap-script change. SmartStore S3 data survives;
##           in-flight events on the local cache are lost.
##
##   make recycle env=prod                    — every Splunk role
##   make recycle env=prod role=indexer       — just one role
########################################################################################################################

role =

recycle: guard-env ## terminate instances; ASGs relaunch fresh (role=<r> to scope)
	@FILTERS='Name=tag:environment,Values=$(env) Name=instance-state-name,Values=running'; \
	if [ -n "$(role)" ]; then FILTERS="$$FILTERS Name=tag:role,Values=$(role)"; fi; \
	IDS=$$(aws ec2 describe-instances --filters $$FILTERS --query 'Reservations[].Instances[].InstanceId' --output text); \
	if [ -z "$$IDS" ]; then echo "No instances to recycle."; exit 0; fi; \
	echo "Terminating: $$IDS"; \
	aws ec2 terminate-instances --instance-ids $$IDS \
	  --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output table

########################################################################################################################
## Smoke / status / ssm — operational helpers.
##
##   make smoke env=prod                    — AWS-side health checks
##   make status env=prod                   — quick instance + ASG inventory
##   make ssm env=prod role=manager         — open an SSM session to a role
##                                            (picks the first running instance)
########################################################################################################################

smoke: guard-env ## AWS-side checks: ASGs, instances, target groups, DNS
	./scripts/smoke-test.sh $(env)

status: guard-env ## instance + ASG inventory
	@echo "=== ASGs ==="; \
	aws autoscaling describe-auto-scaling-groups \
	  --query "AutoScalingGroups[?starts_with(AutoScalingGroupName,\`$(env)-\`)].[AutoScalingGroupName,DesiredCapacity,length(Instances)]" \
	  --output table
	@echo "=== Instances ==="; \
	aws ec2 describe-instances \
	  --filters Name=tag:project,Values=splunk \
	            Name=tag:environment,Values=$(env) \
	            Name=instance-state-name,Values=running \
	  --query 'Reservations[].Instances[].[InstanceId,InstanceType,InstanceLifecycle,Tags[?Key==`role`]|[0].Value,PrivateIpAddress]' \
	  --output table

ssm: guard-env guard-role ## interactive shell on a role via SSM
	@ID=$$(aws ec2 describe-instances \
	  --filters Name=tag:project,Values=splunk \
	            Name=tag:environment,Values=$(env) \
	            Name=tag:role,Values=$(role) \
	            Name=instance-state-name,Values=running \
	  --query 'Reservations[0].Instances[0].InstanceId' --output text); \
	if [ -z "$$ID" ] || [ "$$ID" = "None" ]; then echo "no running $(role) instance found in env=$(env)"; exit 1; fi; \
	echo "Opening SSM session to $$ID..."; \
	aws ssm start-session --target $$ID

########################################################################################################################
## Splunk cluster operations — all via SSM, nothing inbound required.
##
##   make health env=prod                      — deep Splunk-side health report
##                                               (cluster RF/SF, SHC captaincy,
##                                               KV store sync, licence, MC)
##   make splunk-cmd env=prod role=manager cmd="show cluster-status"
##                                             — run any splunk CLI command
##   make push-cluster-bundle env=prod         — validate + apply the manager's
##                                               manager-apps bundle to peers
##   make push-shc-bundle env=prod             — deployer push of shcluster/apps
##                                               to the SHC (any member target)
##   make rolling-restart env=prod role=indexer    — CM-coordinated peer restart
##   make rolling-restart env=prod role=searchhead — SHC rolling restart
########################################################################################################################

health: guard-env ## deep Splunk checks: RF/SF, SHC captaincy, KV store, licence, MC
	./scripts/cluster-health.sh $(env)

splunk-cmd: guard-env guard-role guard-cmd ## run any splunk CLI command (cmd="...")
	./scripts/splunk-cmd.sh $(env) $(role) $(cmd)

push-cluster-bundle: guard-env ## validate + apply manager-apps bundle to indexers
	./scripts/splunk-cmd.sh $(env) manager validate cluster-bundle --check-restart
	./scripts/splunk-cmd.sh $(env) manager apply cluster-bundle --answer-yes
	./scripts/splunk-cmd.sh $(env) manager show cluster-bundle-status

push-shc-bundle: guard-env ## deployer push of shcluster/apps to the SHC
	@SH_IP=$$(aws ec2 describe-instances \
	  --filters Name=tag:project,Values=splunk \
	            Name=tag:environment,Values=$(env) \
	            Name=tag:role,Values=searchhead \
	            Name=instance-state-name,Values=running \
	  --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text); \
	if [ -z "$$SH_IP" ] || [ "$$SH_IP" = "None" ]; then echo "no running searchhead in env=$(env)"; exit 1; fi; \
	echo "Deployer push targeting SHC member https://$$SH_IP:8089"; \
	./scripts/splunk-cmd.sh $(env) deployer apply shcluster-bundle --answer-yes -target "https://$$SH_IP:8089"

rolling-restart: guard-env guard-role ## rolling restart (role=indexer|searchhead)
	@case "$(role)" in \
	  indexer)    ./scripts/splunk-cmd.sh $(env) manager rolling-restart cluster-peers ;; \
	  searchhead) ./scripts/splunk-cmd.sh $(env) searchhead rolling-restart shcluster-members ;; \
	  *) echo "role must be 'indexer' or 'searchhead'"; exit 1 ;; \
	esac

rotate-admin: guard-env ## rotate the splunkadmin password fleet-wide
	./scripts/rotate-splunk-admin.sh $(env)

deploy-apps: guard-env ## sync + push apps per tier: scope=idx|shc|ds|cm|all (default all)
	./scripts/deploy-apps.sh $(env) $(or $(scope),all)

mc-register: guard-env ## (re)register all nodes as MC search peers — run after recycles
	@ID=$$(aws ec2 describe-instances \
	  --filters Name=tag:project,Values=splunk \
	            Name=tag:environment,Values=$(env) \
	            Name=tag:role,Values=monitoring_console \
	            Name=instance-state-name,Values=running \
	  --query 'Reservations[0].Instances[0].InstanceId' --output text); \
	if [ -z "$$ID" ] || [ "$$ID" = "None" ]; then echo "no running MC in env=$(env)"; exit 1; fi; \
	CMD=$$(aws ssm send-command --instance-ids $$ID --document-name AWS-RunShellScript \
	  --parameters 'commands=["/opt/splunk/bin/mc-register-peers.sh"]' \
	  --query 'Command.CommandId' --output text); \
	until S=$$(aws ssm get-command-invocation --command-id $$CMD --instance-id $$ID --query Status --output text 2>/dev/null) && [ "$$S" != "InProgress" ] && [ "$$S" != "Pending" ]; do sleep 5; done; \
	aws ssm get-command-invocation --command-id $$CMD --instance-id $$ID --query StandardOutputContent --output text

password: ## print the current splunkadmin password (from Secrets Manager)
	@aws secretsmanager get-secret-value --secret-id /monitoring/splunk/password --query SecretString --output text

########################################################################################################################
## SOK (Splunk Operator for Kubernetes) — deployment_model=sok. Parallels the
## EC2 targets above (status/ssm/health/deploy-apps) for the eks+sok layers.
##
##   make kubeconfig env=dev                 — point kubectl at the SOK cluster
##   make sok-status env=dev                 — CR phases + pods
##   make kexec env=dev role=cm|indexer|sh|lm|mc — shell into a Splunk pod
##   make sok-health env=dev                 — deep Splunk checks (RF/SF, KV, licence)
##   make sok-deploy-apps env=dev [scope=all] — package apps -> S3 -> poll install
########################################################################################################################

kubeconfig: guard-env ## point kubectl at the SOK EKS cluster
	aws eks update-kubeconfig --name splunk-sok-$(env) --region eu-west-2

sok-password: guard-env ## print the SOK admin password (env-scoped secret)
	@if [ "$(env)" = "dev" ]; then SID=/dev/splunk/password; else SID=/monitoring/splunk/password; fi; \
	aws secretsmanager get-secret-value --secret-id $$SID --query SecretString --output text

sok-hec-token: guard-env ## print the HEC token (operator-generated; rotates each rebuild)
	@kubectl get secret splunk-splunk-secret -n splunk -o jsonpath='{.data.hec_token}' | base64 -d; echo

sok-urls: guard-env ## print external Splunk Web + HEC URLs (when sok_web_external_enabled) — read live from the ALB Ingresses
	@echo "=== external URLs (per-component ALB Ingress hosts) ==="; \
	kubectl get ingress -n splunk \
	  -o jsonpath='{range .items[*]}{range .spec.rules[*]}https://{.host}{"\n"}{end}{end}' 2>/dev/null \
	  | sort -u | sed '/^https:\/\/$$/d' \
	  || { echo "(no Ingress — external web disabled, or run 'make kubeconfig env=$(env)')"; exit 0; }; \
	echo "=== ALB DNS (CNAME target) ==="; \
	kubectl get ingress -n splunk \
	  -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress[*].hostname}{"\n"}{end}' 2>/dev/null | sort -u; \
	echo "(login: admin / \`make sok-password env=$(env)\`)"

sok-status: guard-env ## SOK CR phases + pods
	@echo "=== CRs ==="; \
	kubectl get clustermanager,indexercluster,searchheadcluster,standalone,licensemanager,monitoringconsole -n splunk 2>/dev/null || echo "(no cluster — run 'make kubeconfig env=$(env)' and ensure the eks/sok layers are applied)"; \
	echo "=== pods ==="; \
	kubectl get pods -n splunk -o wide 2>/dev/null

kexec: guard-env guard-role ## shell into a Splunk pod (role=cm|indexer|sh|lm|mc)
	@case "$(role)" in \
	  cm)      SEL=cluster-manager ;; \
	  indexer) SEL=indexer ;; \
	  sh)      SEL=standalone ;; \
	  lm)      SEL=license-manager ;; \
	  mc)      SEL=monitoring-console ;; \
	  *) echo "role must be cm|indexer|sh|lm|mc"; exit 1 ;; \
	esac; \
	POD=$$(kubectl get pods -n splunk -l "app.kubernetes.io/name=$$SEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ] && [ "$(role)" = "sh" ]; then \
	  POD=$$(kubectl get pods -n splunk -l "app.kubernetes.io/name=search-head" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	fi; \
	if [ -z "$$POD" ]; then echo "no $(role) pod found in namespace splunk (tried Standalone + SHC for sh)"; exit 1; fi; \
	echo "exec -> $$POD"; kubectl exec -it -n splunk "$$POD" -- /bin/bash

sok-health: guard-env ## deep Splunk-side checks on the SOK cluster (RF/SF, KV, licence)
	./scripts/sok-health.sh $(env)

sok-deploy-apps: guard-env ## package apps -> S3 -> poll install: scope=all|cm|sh|idx|shc
	./scripts/package-apps.sh $(env) $(or $(scope),all)

sok-kvstore-backup: guard-env ## back up the SHC KV store to S3 (prod)
	./scripts/sok-kvstore-backup.sh $(env)

sok-kvstore-restore: guard-env ## restore the SHC KV store from S3 (latest, or archive=<name>)
	./scripts/sok-kvstore-restore.sh $(env) $(archive)

sok-rf-remediate: guard-env ## fix the SmartStore cold-boot RF stall (safe no-op when healthy)
	./scripts/sok-rf-remediate.sh $(env)

# Guarded apply for the sok layer: plans, detects Splunk-CR changes, and — if
# the cluster is LIVE — lists exactly what the operator will restart (SHC rolls
# one member at a time; CM/LM/MC/deployer are singletons and blip) and requires
# a typed ROLL / CONFIRM=ROLL. Stage across CRs with target='<address>'.
sok-apply: guard-env ## apply sok layer with live-restart guardrail (target=<addr> to stage)
	./scripts/sok-apply-guard.sh $(env) $(target)

## docs — MkDocs Material site (docs/ + mkdocs.yml). Published to GitHub
##        Pages by .github/workflows/docs.yml once the repo is public.
docs-serve: ## live-preview the docs on http://127.0.0.1:8000
	@command -v mkdocs >/dev/null || pip install mkdocs-material
	mkdocs serve

docs-build: ## strict docs build (same as CI)
	@command -v mkdocs >/dev/null || pip install mkdocs-material
	mkdocs build --strict
