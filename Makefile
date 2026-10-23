SHELL := $(shell command -v bash)
rwildcard = $(foreach d,$(wildcard $(1:=/*)),$(call rwildcard,$d,$2) $(filter $(subst *,%,$2),$d))

APP_VERSION=0.1.2
REPOSITORY=0toknsleft/todo-app
APP_IMAGE = ghcr.io/$(REPOSITORY):$(APP_VERSION)
DEPLOY_SOURCE = git+https://github.com/$(REPOSITORY)@v$(APP_VERSION)\#subdirectory=deploy

TF_DIR=tf
INFRA_DIR=$(TF_DIR)/infra
DB_DIR=$(TF_DIR)/db

SECRETS_DIR=secrets
PFX=$(SECRETS_DIR)/dataprotection.pfx
PFX_PASSWORD=$(SECRETS_DIR)/dataprotection.password

INFRA_FILES := $(call rwildcard,$(INFRA_DIR),*.tf)
DB_FILES := $(call rwildcard,$(DB_DIR),*.tf)

.PHONY: setup
setup:
	git-crypt unlock
	terraform -chdir=$(INFRA_DIR) init -lockfile=readonly
	terraform -chdir=$(DB_DIR) init -lockfile=readonly

.PHONY: infrastructure
infrastructure:
	@terraform -chdir=$(INFRA_DIR) apply -auto-approve
	@terraform -chdir=$(DB_DIR) apply -auto-approve

.PHONY: clean
clean:
	rm -f tf_outputs.json ssh_key.pem

.PHONY: destroy
destroy: clean
	terraform -chdir=$(INFRA_DIR) destroy -auto-approve
	rm -f $(INFRA_DIR)/terraform.tfstate $(DB_DIR)/terraform.tfstate

.PHONY: ssh
ssh: tf_outputs.json ssh_key.pem
	$(if $(host),,$(error usage: make ssh host=<instance-id>))
	@target="$$(jq -er --arg id '$(host)' '.ec2_instances[$$id] // error("unknown instance \($$id)") | "\(.user)@\(.host)"' $<)" && \
	exec ssh -i ssh_key.pem "$$target"

.PHONY: deploy-app
deploy-app: tf_outputs.json ssh_key.pem $(PFX)
	@targets="$$(aws ec2 describe-instances --region "$$(jq -er .aws_region $<)" \
		--filters Name=tag:Role,Values=app Name=instance-state-name,Values=running \
		--query 'Reservations[].Instances[].PublicIpAddress' --output json | \
		jq -er 'if length > 0 then map("ubuntu@\(.)") | join(" ") else error("no running instances tagged Role=app") end')" && \
	env_file="$$(mktemp)" && settings_file="$$(mktemp)" && trap 'rm -f "$$env_file" "$$settings_file"' EXIT && \
	jq -er '"ConnectionStrings__Default=\"\(.connection_string_ef_core)\""' $< > "$$env_file" && \
	jq -e '{TrustedProxies: {Networks: [.vpc_cidr_block]}}' $< > "$$settings_file" && \
	TODOAPP_CERTIFICATE_PASSWORD="$$(cat $(PFX_PASSWORD))" \
	ANSIBLE_PRIVATE_KEY_FILE="$(CURDIR)/ssh_key.pem" \
	ANSIBLE_HOST_KEY_CHECKING=False \
	uvx --from "$(DEPLOY_SOURCE)" setup-webapp $$targets --version v$(APP_VERSION) \
		--env-file "$$env_file" --settings "$$settings_file" --certificate $(PFX)

.PHONY: migrate
migrate: tf_outputs.json
	@ConnectionStrings__Default="$$(jq -r .connection_string_ef_core $<)" \
	docker run --rm --platform linux/amd64 -e ConnectionStrings__Default $(APP_IMAGE) migrate

$(DB_DIR)/terraform.tfstate: $(INFRA_DIR)/terraform.tfstate $(DB_FILES)
	@terraform -chdir=$(DB_DIR) apply -auto-approve

$(INFRA_DIR)/terraform.tfstate: $(INFRA_FILES)
	@terraform -chdir=$(INFRA_DIR) apply -auto-approve


tf_outputs.json: $(INFRA_DIR)/terraform.tfstate $(DB_DIR)/terraform.tfstate
	@jq -s '.[0] * .[1]' \
		<(terraform -chdir=$(INFRA_DIR) output -json | jq 'map_values(.value)') \
		<(terraform -chdir=$(DB_DIR) output -json | jq 'map_values(.value)') \
		> $@

ssh_key.pem: tf_outputs.json
	@(umask 077 && jq -r .ssh_private_key $< > $@)

$(PFX_PASSWORD):
	@(umask 077 && openssl rand -hex 32 > $@)

$(PFX): | $(PFX_PASSWORD)
	@TODOAPP_CERTIFICATE_PASSWORD="$$(cat $(PFX_PASSWORD))" uvx --from "$(DEPLOY_SOURCE)" generate-certificate $@
