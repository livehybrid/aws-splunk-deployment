args =

guard-%:
	@ if [ "${${*}}" = "" ]; then \
        echo "Environment variable $* not set"; \
        exit 1; \
    fi

packer-init:
	packer init .

packer-build:  guard-env packer-init
	packer build -var-file=vars/$(env).pkrvars.json $(args) .

packer-validate:  guard-env
	packer validate -var-file=vars/$(env).pkrvars.json .

packer-fmt:
	packer fmt -recursive .
