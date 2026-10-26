SHELL := $(shell command -v bash)
rwildcard = $(foreach d,$(wildcard $(1:=/*)),$(call rwildcard,$d,$2) $(filter $(subst *,%,$2),$d))

APP_VERSION=0.3.1
REPOSITORY=0toknsleft/todo-app
APP_IMAGE = ghcr.io/$(REPOSITORY):$(APP_VERSION)
DEPLOY_SOURCE = git+https://github.com/$(REPOSITORY)@v$(APP_VERSION)\#subdirectory=deploy

AWS_REGION ?= eu-central-1
export AWS_REGION
export TF_VAR_aws_region = $(AWS_REGION)
STATE_BUCKET = 0toks-infrastructure-$(shell aws sts get-caller-identity --query Account --output text)-$(AWS_REGION)

TF_DIR=tf
INFRA_DIR=$(TF_DIR)/infra
DB_DIR=$(TF_DIR)/db
INFRA_OUTPUT = terraform -chdir=$(INFRA_DIR) output
DB_OUTPUT = terraform -chdir=$(DB_DIR) output
INSTANCE_TARGET = $(INFRA_OUTPUT) -json ec2_instances | \
	jq -er --arg id '$(host)' '.[$$id] // error("unknown instance \($$id)") | "\(.user)@\(.host)"'
DB_TUNNEL = scripts/db-tunnel.sh
SECRET = scripts/secret.sh $(STATE_BUCKET)
DB_TUNNEL_VARS = -var db_host=127.0.0.1 -var state_bucket=$(STATE_BUCKET)
INFRA_APPLIED = $(INFRA_DIR)/.terraform/applied
DB_APPLIED = $(DB_DIR)/.terraform/applied

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
setup: ## Unlock secrets, create the state bucket and initialise terraform
	git-crypt unlock
	@bucket=$(STATE_BUCKET) && \
	{ aws s3api head-bucket --bucket "$$bucket" 2>/dev/null || aws s3 mb "s3://$$bucket"; } && \
	aws s3api put-bucket-versioning --bucket "$$bucket" --versioning-configuration Status=Enabled && \
	terraform -chdir=$(INFRA_DIR) init -reconfigure -lockfile=readonly -backend-config="bucket=$$bucket" && \
	terraform -chdir=$(DB_DIR) init -reconfigure -lockfile=readonly -backend-config="bucket=$$bucket"
	rm -f $(INFRA_APPLIED) $(DB_APPLIED)

.PHONY: infrastructure
infrastructure: ssh_key.pem ## Apply the infra and db terraform
	@terraform -chdir=$(INFRA_DIR) apply -auto-approve
	@$(DB_TUNNEL) terraform -chdir=$(DB_DIR) apply -auto-approve $(DB_TUNNEL_VARS)
	@touch $(INFRA_APPLIED) $(DB_APPLIED)

.PHONY: infra-plan
infra-plan: ssh_key.pem ## Show pending infra and db changes
	@terraform -chdir=$(INFRA_DIR) plan
	@$(DB_TUNNEL) terraform -chdir=$(DB_DIR) plan $(DB_TUNNEL_VARS)

.PHONY: clean
clean: ## Remove the local SSH key and secrets
	rm -f ssh_key.pem $(PFX) $(PFX_PASSWORD)

.PHONY: destroy
destroy: clean ## Tear down all infrastructure
	terraform -chdir=$(INFRA_DIR) destroy -auto-approve
	aws s3 rm s3://$(STATE_BUCKET)/infra.tfstate
	aws s3 rm s3://$(STATE_BUCKET)/db.tfstate
	rm -f $(INFRA_APPLIED) $(DB_APPLIED)

.PHONY: ssh
ssh: ssh_key.pem ## SSH into an instance (host=<instance-id>)
	$(if $(host),,$(error usage: make ssh host=<instance-id>))
	@target="$$($(INSTANCE_TARGET))" && \
	exec ssh -i ssh_key.pem "$$target"

.PHONY: deploy-app
deploy-app: $(DB_APPLIED) ssh_key.pem $(PFX) ## Deploy the app to every Role=app instance
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
migrate: $(DB_APPLIED) ssh_key.pem ## Run database migrations
	@ConnectionStrings__Default="$$($(DB_OUTPUT) -raw connection_string_ef_core)" \
	$(DB_TUNNEL) docker run --rm --platform linux/amd64 -e ConnectionStrings__Default \
		--add-host "$$($(INFRA_OUTPUT) -raw db_address):host-gateway" $(APP_IMAGE) migrate

.PHONY: db-tunnel
db-tunnel: $(DB_APPLIED) ssh_key.pem ## Open a tunnel to the database and print connection details
	@$(DB_TUNNEL)

$(DB_APPLIED): $(INFRA_APPLIED) $(DB_FILES) ssh_key.pem
	@$(DB_TUNNEL) terraform -chdir=$(DB_DIR) apply -auto-approve $(DB_TUNNEL_VARS)
	@touch $@

$(INFRA_APPLIED): $(INFRA_FILES)
	@terraform -chdir=$(INFRA_DIR) apply -auto-approve
	@touch $@

ssh_key.pem: $(INFRA_APPLIED)
	@(umask 077 && $(INFRA_OUTPUT) -raw ssh_private_key > $@)

$(PFX_PASSWORD):
	@$(SECRET) $@ openssl rand -hex 32 -out $@

$(PFX): | $(PFX_PASSWORD)
	@TODOAPP_CERTIFICATE_PASSWORD="$$(cat $(PFX_PASSWORD))" $(SECRET) $@ uvx --from "$(DEPLOY_SOURCE)" generate-certificate $@
