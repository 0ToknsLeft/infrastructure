SHELL := $(shell command -v bash)
rwildcard = $(foreach d,$(wildcard $(1:=/*)),$(call rwildcard,$d,$2) $(filter $(subst *,%,$2),$d))

DB_PASS=$(file < .db-pass)

APP_VERSION=0.1.0
REPOSITORY=0toknsleft/todo-app
APP_IMAGE = ghcr.io/$(REPOSITORY):$(APP_VERSION)

TF_DIR=tf
INFRA_DIR=$(TF_DIR)/infra
DB_DIR=$(TF_DIR)/db

INFRA_FILES := $(call rwildcard,$(INFRA_DIR),*.tf)
DB_FILES := $(call rwildcard,$(DB_DIR),*.tf)

.PHONY: setup
setup:
	git-crypt unlock
	terraform -chdir=$(INFRA_DIR) init -lockfile=readonly
	terraform -chdir=$(DB_DIR) init -lockfile=readonly

.PHONY: clean
clean:
	rm -f tf_outputs.json

.PHONY: destroy
destroy: clean
	terraform -chdir=$(INFRA_DIR) destroy -auto-approve
	rm -f $(INFRA_DIR)/terraform.tfstate $(DB_DIR)/terraform.tfstate

.PHONY: migrate
migrate: tf_outputs.json
	@ConnectionStrings__Default="$$(jq -r .connection_string_ef_core $<)" \
	docker run --rm --platform linux/amd64 -e ConnectionStrings__Default $(APP_IMAGE) migrate

$(DB_DIR)/terraform.tfstate: $(INFRA_DIR)/terraform.tfstate $(DB_FILES)
	@TF_VAR_db_password=$(DB_PASS) \
	terraform -chdir=$(DB_DIR) apply -auto-approve

$(INFRA_DIR)/terraform.tfstate: $(INFRA_FILES)
	@terraform -chdir=$(INFRA_DIR) apply -auto-approve


tf_outputs.json: $(INFRA_DIR)/terraform.tfstate $(DB_DIR)/terraform.tfstate
	@jq -s '.[0] * .[1]' \
		<(terraform -chdir=$(INFRA_DIR) output -json | jq 'map_values(.value)') \
		<(terraform -chdir=$(DB_DIR) output -json | jq 'map_values(.value)') \
		> $@
