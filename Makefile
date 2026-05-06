###############################################################################
# eks-platform-baseline — top-level Makefile
#
# Wraps the same checks CI runs so the local loop matches the pipeline.
#
# Usage:
#   make fmt          terraform fmt across all modules
#   make validate     terraform init (no backend) + validate every module
#   make lint         tflint + checkov + trivy + kubeconform + shellcheck
#   make manifests    validate Kubernetes manifests with kubeconform
#   make plan         terraform plan in environments/dev (read-only review)
#   make apply        terraform apply in environments/dev (interactive)
#   make destroy      terraform destroy in environments/dev (interactive)
#   make bootstrap    run scripts/bootstrap-cluster.sh
#   make all          fmt + validate + lint + manifests
###############################################################################

SHELL              := bash
.SHELLFLAGS        := -eu -o pipefail -c
.DEFAULT_GOAL      := all

REPO_ROOT          := $(shell git rev-parse --show-toplevel 2>/dev/null || pwd)
TF_DIR             := $(REPO_ROOT)/terraform
ENV_DIR            := $(TF_DIR)/environments/dev
MODULES_DIR        := $(TF_DIR)/modules
MANIFESTS_DIR      := $(REPO_ROOT)/manifests
SCRIPTS_DIR        := $(REPO_ROOT)/scripts

TF                 ?= terraform
TFLINT             ?= tflint
CHECKOV            ?= checkov
TRIVY              ?= trivy
KUBECONFORM        ?= kubeconform
SHELLCHECK         ?= shellcheck

K8S_VERSION        ?= 1.30.0
KUBECONFORM_FLAGS  := -strict -summary -kubernetes-version $(K8S_VERSION) \
                     -schema-location default \
                     -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{ .Group }}/{{ .ResourceKind }}_{{ .ResourceAPIVersion }}.json'

# ANSI colour helpers — disabled if NO_COLOR is set or stdout is not a TTY.
ifeq ($(NO_COLOR),)
ifeq ($(shell test -t 1 && echo tty),tty)
C_RESET := $(shell tput sgr0)
C_BLUE  := $(shell tput setaf 4)
C_GREEN := $(shell tput setaf 2)
endif
endif

define section
	@printf "$(C_BLUE)==> %s$(C_RESET)\n" "$(1)"
endef

###############################################################################
# Top-level targets
###############################################################################

.PHONY: all
all: fmt validate lint manifests
	$(call section,All checks passed)

.PHONY: help
help:
	@grep -E '^[A-Za-z_-]+:.*?##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  $(C_GREEN)%-15s$(C_RESET) %s\n", $$1, $$2}'

###############################################################################
# Terraform
###############################################################################

.PHONY: fmt
fmt: ## terraform fmt across the tree
	$(call section,terraform fmt)
	@$(TF) fmt -recursive $(TF_DIR)

.PHONY: fmt-check
fmt-check: ## terraform fmt -check (CI mode — fails on drift)
	$(call section,terraform fmt -check)
	@$(TF) fmt -recursive -check $(TF_DIR)

.PHONY: validate
validate: ## terraform init (no backend) + validate every module
	$(call section,terraform validate (modules))
	@for d in $(MODULES_DIR)/*; do \
	  echo "  validating $$d"; \
	  $(TF) -chdir=$$d init -backend=false -input=false >/dev/null; \
	  $(TF) -chdir=$$d validate; \
	done
	$(call section,terraform validate (environments/dev))
	@$(TF) -chdir=$(ENV_DIR) init -backend=false -input=false >/dev/null
	@$(TF) -chdir=$(ENV_DIR) validate

.PHONY: plan
plan: ## terraform plan in environments/dev
	@$(TF) -chdir=$(ENV_DIR) init -input=false
	@$(TF) -chdir=$(ENV_DIR) plan

.PHONY: apply
apply: ## terraform apply in environments/dev (interactive)
	@$(TF) -chdir=$(ENV_DIR) init -input=false
	@$(TF) -chdir=$(ENV_DIR) apply

.PHONY: destroy
destroy: ## terraform destroy in environments/dev (interactive)
	@$(TF) -chdir=$(ENV_DIR) destroy

###############################################################################
# Linters / scanners
###############################################################################

.PHONY: lint
lint: tflint checkov trivy shellcheck ## All linters

.PHONY: tflint
tflint: ## tflint with AWS plugin across modules
	$(call section,tflint)
	@command -v $(TFLINT) >/dev/null || { echo "tflint not installed"; exit 1; }
	@$(TFLINT) --init >/dev/null
	@for d in $(MODULES_DIR)/* $(ENV_DIR); do \
	  echo "  tflint $$d"; \
	  $(TFLINT) --chdir=$$d --config=$(REPO_ROOT)/.tflint.hcl; \
	done

.PHONY: checkov
checkov: ## checkov scan of terraform/
	$(call section,checkov)
	@command -v $(CHECKOV) >/dev/null || { echo "checkov not installed"; exit 1; }
	@$(CHECKOV) -d $(TF_DIR) --quiet --compact --framework terraform

.PHONY: trivy
trivy: ## trivy IaC scan
	$(call section,trivy)
	@command -v $(TRIVY) >/dev/null || { echo "trivy not installed"; exit 1; }
	@$(TRIVY) config --severity HIGH,CRITICAL --exit-code 1 $(TF_DIR)

.PHONY: shellcheck
shellcheck: ## shellcheck on every script
	$(call section,shellcheck)
	@command -v $(SHELLCHECK) >/dev/null || { echo "shellcheck not installed"; exit 1; }
	@find $(SCRIPTS_DIR) -name '*.sh' -print0 | xargs -0 $(SHELLCHECK)

###############################################################################
# Kubernetes manifests
###############################################################################

.PHONY: manifests
manifests: ## kubeconform validate every manifest
	$(call section,kubeconform manifests/)
	@command -v $(KUBECONFORM) >/dev/null || { echo "kubeconform not installed"; exit 1; }
	@find $(MANIFESTS_DIR) -name '*.yaml' -print0 | xargs -0 $(KUBECONFORM) $(KUBECONFORM_FLAGS)

###############################################################################
# Operational
###############################################################################

.PHONY: bootstrap
bootstrap: ## scripts/bootstrap-cluster.sh
	@$(SCRIPTS_DIR)/bootstrap-cluster.sh

.PHONY: clean
clean: ## remove .terraform / lock files
	$(call section,clean)
	@find $(TF_DIR) -type d -name '.terraform' -exec rm -rf {} +
	@find $(TF_DIR) -name '.terraform.lock.hcl' -delete
