# Cloak VPN — infra convenience targets (multi-region).
#
# All targets accept REGION=<slug> (default: fi1). Examples:
#   make deploy                 # deploys fi1
#   make deploy REGION=de1      # deploys de1
#   make ssh    REGION=de1
#   make destroy REGION=de1

SHELL := /usr/bin/env bash

REGION ?= fi1
TF_DIR := terraform/regions/$(REGION)
TF     := terraform -chdir=$(TF_DIR)

.PHONY: help
help:
	@echo "Cloak VPN infra targets (REGION=$(REGION); override with REGION=<slug>):"
	@echo "  make init                Initialize terraform for the selected region."
	@echo "  make plan                Show what terraform will change in the region."
	@echo "  make deploy              Provision + run setup.sh end-to-end for the region."
	@echo "  make setup               Re-run setup.sh on the existing box (no new server)."
	@echo "  make ssh                 Open an interactive SSH session to the concentrator."
	@echo "  make wg                  Show live WireGuard peer state on the box."
	@echo "  make regions             List all configured regions."
	@echo "  make destroy             Tear down the region's Hetzner server."
	@echo ""
	@echo "Tip: REGION defaults to 'fi1'. Pass REGION=de1 (etc.) for other regions."

.PHONY: regions
regions:
	@ls -1 terraform/regions 2>/dev/null || echo "(no regions configured)"

.PHONY: init
init: _check-region
	$(TF) init -input=false -upgrade

.PHONY: plan
plan: _check-region
	$(TF) plan -input=false

.PHONY: deploy
deploy: _check-region
	./deploy.sh $(REGION)

.PHONY: setup
setup: _check-region
	@IP=$$( $(TF) output -raw ipv4 ); \
	KEY=$$( awk -F'=' '/^ssh_public_key_path/{gsub(/[" ]/,"",$$2); print $$2}' $(TF_DIR)/terraform.tfvars | sed "s|~|$$HOME|" ); \
	PRIV=$${KEY%.pub}; \
	rsync -azP --delete -e "ssh -i $$PRIV -o StrictHostKeyChecking=accept-new" \
	  --exclude '.git' --exclude 'infra/out' \
	  ../server/ root@$$IP:/root/cloakvpn/server/; \
	ssh -i $$PRIV -o StrictHostKeyChecking=accept-new root@$$IP \
	  "chmod +x /root/cloakvpn/server/scripts/*.sh && /root/cloakvpn/server/scripts/setup.sh"

.PHONY: ssh
ssh: _check-region
	@IP=$$( $(TF) output -raw ipv4 ); \
	KEY=$$( awk -F'=' '/^ssh_public_key_path/{gsub(/[" ]/,"",$$2); print $$2}' $(TF_DIR)/terraform.tfvars | sed "s|~|$$HOME|" ); \
	PRIV=$${KEY%.pub}; \
	ssh -i $$PRIV root@$$IP

.PHONY: wg
wg: _check-region
	@IP=$$( $(TF) output -raw ipv4 ); \
	KEY=$$( awk -F'=' '/^ssh_public_key_path/{gsub(/[" ]/,"",$$2); print $$2}' $(TF_DIR)/terraform.tfvars | sed "s|~|$$HOME|" ); \
	PRIV=$${KEY%.pub}; \
	ssh -i $$PRIV root@$$IP "wg show wg0; echo; systemctl is-active cloak-rosenpass.service"

.PHONY: destroy
destroy: _check-region
	@echo "This will destroy Hetzner resources in region '$(REGION)'. Billing stops immediately."
	@read -p "Type the server name to confirm: " name; \
	   actual=$$( $(TF) output -raw server_name ); \
	   [ "$$name" = "$$actual" ] || { echo "Mismatch — aborting."; exit 1; }; \
	   $(TF) destroy -auto-approve

# Sanity check: fail early with a readable message if the region dir is missing.
.PHONY: _check-region
_check-region:
	@[ -d "$(TF_DIR)" ] || { \
	  echo "Region '$(REGION)' not found at $(TF_DIR)."; \
	  echo "Available regions:"; ls -1 terraform/regions 2>/dev/null | sed 's/^/  /'; \
	  exit 1; }
