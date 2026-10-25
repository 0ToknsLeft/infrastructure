SHELL := $(shell command -v bash)
rwildcard = $(foreach d,$(wildcard $(1:=/*)),$(call rwildcard,$d,$2) $(filter $(subst *,%,$2),$d))

APP_VERSION=0.3.0
REPOSITORY=0toknsleft/todo-app
APP_IMAGE = ghcr.io/$(REPOSITORY):$(APP_VERSION)
DEPLOY_SOURCE = git+https://github.com/$(REPOSITORY)@v$(APP_VERSION)\#subdirectory=deploy

TF_DIR=tf
INFRA_DIR=$(TF_DIR)/infra
DB_DIR=$(TF_DIR)/db
INFRA_OUTPUT = terraform -chdir=$(INFRA_DIR) output
DB_OUTPUT = terraform -chdir=$(DB_DIR) output
INSTANCE_TARGET = $(INFRA_OUTPUT) -json ec2_instances | \
	jq -er --arg id '$(host)' '.[$$id] // error("unknown instance \($$id)") | "\(.user)@\(.host)"'
DB_TUNNEL = scripts/db-tunnel.sh
DB_TUNNEL_VARS = -var db_host=127.0.0.1

SECRETS_DIR=secrets
PFX=$(SECRETS_DIR)/dataprotection.pfx
PFX_PASSWORD=$(SECRETS_DIR)/dataprotection.password

INFRA_FILES := $(call rwildcard,$(INFRA_DIR),*.tf)
DB_FILES := $(call rwildcard,$(DB_DIR),*.tf)

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z_-]+:.*## / { printf "  %-16s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

.PHONY: setup
setup: ## Unlock secrets and initialise terraform
	git-crypt unlock
	terraform -chdir=$(INFRA_DIR) init -lockfile=readonly
	terraform -chdir=$(DB_DIR) init -lockfile=readonly

.PHONY: infrastructure
infrastructure: ssh_key.pem ## Apply the infra and db terraform
	@terraform -chdir=$(INFRA_DIR) apply -auto-approve
	@$(DB_TUNNEL) terraform -chdir=$(DB_DIR) apply -auto-approve $(DB_TUNNEL_VARS)

.PHONY: infra-plan
infra-plan: ssh_key.pem ## Show pending infra and db changes
	@terraform -chdir=$(INFRA_DIR) plan
	@$(DB_TUNNEL) terraform -chdir=$(DB_DIR) plan $(DB_TUNNEL_VARS)

.PHONY: clean
clean: ## Remove the local SSH key
	rm -f ssh_key.pem

.PHONY: destroy
destroy: clean ## Tear down all infrastructure
	terraform -chdir=$(INFRA_DIR) destroy -auto-approve
	rm -f $(INFRA_DIR)/terraform.tfstate $(DB_DIR)/terraform.tfstate

.PHONY: ssh
ssh: ssh_key.pem ## SSH into an instance (host=<instance-id>)
	$(if $(host),,$(error usage: make ssh host=<instance-id>))
	@target="$$($(INSTANCE_TARGET))" && \
	exec ssh -i ssh_key.pem "$$target"

.PHONY: deploy-app
deploy-app: $(DB_DIR)/terraform.tfstate ssh_key.pem $(PFX) ## Deploy the app to every Role=app instance
	@targets="$$(aws ec2 describe-instances --region "$$($(INFRA_OUTPUT) -raw aws_region)" \
		--filters Name=tag:Role,Values=app Name=instance-state-name,Values=running \
		--query 'Reservations[].Instances[].PublicIpAddress' --output json | \
		jq -er 'if length > 0 then map("ubuntu@\(.)") | join(" ") else error("no running instances tagged Role=app") end')" && \
	env_file="$$(mktemp)" && trap 'rm -f "$$env_file"' EXIT && \
	printf 'ConnectionStrings__Default="%s"\n' "$$($(DB_OUTPUT) -raw connection_string_ef_core)" > "$$env_file" && \
	TODOAPP_CERTIFICATE_PASSWORD="$$(cat $(PFX_PASSWORD))" \
	ANSIBLE_PRIVATE_KEY_FILE="$(CURDIR)/ssh_key.pem" \
	ANSIBLE_HOST_KEY_CHECKING=False \
	uvx --from "$(DEPLOY_SOURCE)" setup-webapp $$targets --version v$(APP_VERSION) \
		--env-file "$$env_file" --certificate $(PFX)

.PHONY: setup-tls
setup-tls: ssh_key.pem ## Serve HTTPS on an instance (host=<instance-id> domain=<domain> [email=<address>])
	$(if $(and $(host),$(domain)),,$(error usage: make setup-tls host=<instance-id> domain=<domain> [email=<address>]))
	@target="$$($(INSTANCE_TARGET))" && \
	ANSIBLE_PRIVATE_KEY_FILE="$(CURDIR)/ssh_key.pem" \
	ANSIBLE_HOST_KEY_CHECKING=False \
	uvx --from "$(DEPLOY_SOURCE)" setup-tls "$$target" '$(domain)' $(if $(email),--email '$(email)')

.PHONY: migrate
migrate: $(DB_DIR)/terraform.tfstate ssh_key.pem ## Run database migrations
	@ConnectionStrings__Default="$$($(DB_OUTPUT) -raw connection_string_ef_core)" \
	$(DB_TUNNEL) docker run --rm --platform linux/amd64 -e ConnectionStrings__Default \
		--add-host "$$($(INFRA_OUTPUT) -raw db_address):host-gateway" $(APP_IMAGE) migrate

.PHONY: db-tunnel
db-tunnel: $(DB_DIR)/terraform.tfstate ssh_key.pem ## Open a tunnel to the database and print connection details
	@$(DB_TUNNEL)

$(DB_DIR)/terraform.tfstate: $(INFRA_DIR)/terraform.tfstate $(DB_FILES) ssh_key.pem
	@$(DB_TUNNEL) terraform -chdir=$(DB_DIR) apply -auto-approve $(DB_TUNNEL_VARS)

$(INFRA_DIR)/terraform.tfstate: $(INFRA_FILES)
	@terraform -chdir=$(INFRA_DIR) apply -auto-approve

ssh_key.pem: $(INFRA_DIR)/terraform.tfstate
	@(umask 077 && $(INFRA_OUTPUT) -raw ssh_private_key > $@)

$(PFX_PASSWORD):
	@(umask 077 && openssl rand -hex 32 > $@)

$(PFX): | $(PFX_PASSWORD)
	@TODOAPP_CERTIFICATE_PASSWORD="$$(cat $(PFX_PASSWORD))" uvx --from "$(DEPLOY_SOURCE)" generate-certificate $@
