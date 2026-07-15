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
##  Use `make terraform env=prod` to apply all layers in order (account → iam → eks → sok) per workspace.
##
########################################################################################################################
THIS_FILE := $(lastword $(MAKEFILE_LIST))
activate  = VIRTUAL_ENV_DISABLE_PROMPT=true . .venv/bin/activate;
pwd       := ${PWD}
dirname   := $(notdir ${PWD})

standard_terraform_layers := account iam eks sok

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

terraform: guard-env ## apply all layers in order (account -> iam -> eks -> sok)
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
## SOK (Splunk Operator for Kubernetes) — operations for the eks + sok layers.
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
	@aws secretsmanager get-secret-value --secret-id /$(env)/splunk/password --query SecretString --output text

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
