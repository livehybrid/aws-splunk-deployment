args =
tf-command = apply
# NO default env — guard-env must force an explicit env=<dev|prod> on every
# invocation. A `prod` default here meant a forgotten env= silently targeted
# PROD (guard-env passed because the variable was never empty) — DEP-12.
env =

guard-%:
	@ if [ "${${*}}" = "" ]; then \
        echo "Environment variable $* not set"; \
        exit 1; \
    fi

.ONESHELL:

terraform-init: guard-env
	terraform init -var-file=vars/$(env).tfvars -backend-config=conf/$(env).backend.conf
	if terraform workspace list | grep -q $(env); then terraform workspace select $(env); else terraform workspace new $(env); fi

terraform: guard-env
	rm -f .terraform/terraform.tfstate
	terraform init -var-file=vars/$(env).tfvars -backend-config=conf/$(env).backend.conf
	if terraform workspace list | grep -q $(env); then terraform workspace select $(env); else terraform workspace new $(env); fi
	@ if [ "$(tf-command)" != "output" ]; then \
		terraform $(tf-command) -var-file=vars/$(env).tfvars $(args); \
	else \
		terraform $(tf-command) $(args); \
	fi

terraform-validate: guard-env
	terraform init -backend=false -input=false >/dev/null
	terraform validate

terraform-plan: guard-env
	terraform plan -var-file=vars/$(env).tfvars -out=plan-$(env).tfplan $(args)

terraform-show: guard-env
	terraform show -json plan-$(env).tfplan > plan-$(env).json

terraform-import: guard-env guard-object guard-arn
	terraform init -var-file=vars/$(env).tfvars -backend-config=conf/$(env).backend.conf
	if terraform workspace list | grep -q $(env); then terraform workspace select $(env); else terraform workspace new $(env); fi
	terraform import -var-file=vars/$(env).tfvars $(object) $(arn)

terraform-rm: guard-env guard-object
	terraform init -var-file=vars/$(env).tfvars -backend-config=conf/$(env).backend.conf
	if terraform workspace list | grep -q $(env); then terraform workspace select $(env); else terraform workspace new $(env); fi
	terraform state rm $(object)

terraform-clean:
	rm -rf .terraform
	rm -f errored.tfstate

terraform-no-init: guard-env
	@ if [ "$(tf-command)" != "output" ]; then \
		terraform $(tf-command) -var-file=vars/$(env).tfvars $(args); \
	else \
		terraform $(tf-command) $(args); \
	fi

# Cost estimation — Infracost reads the merged plan and produces a baseline
# (breakdown) or a diff against a stored baseline (diff).
infracost-breakdown: guard-env
	infracost breakdown --path=. \
		--terraform-var-file=vars/$(env).tfvars \
		--terraform-workspace=$(env) \
		--format=table

infracost-diff: guard-env
	infracost diff --path=. \
		--terraform-var-file=vars/$(env).tfvars \
		--terraform-workspace=$(env) \
		--compare-to=infracost-base-$(env).json

infracost-baseline: guard-env
	infracost breakdown --path=. \
		--terraform-var-file=vars/$(env).tfvars \
		--terraform-workspace=$(env) \
		--format=json --out-file=infracost-base-$(env).json
