# Cloak VPN — infra convenience targets.
# All targets are thin wrappers so `make <target>` Just Works from repo root.

SHELL := /usr/bin/env bash

.PHONY: help
help:
	@echo "Cloak VPN infra targets:"
	@echo "  make init        Initialize terraform (idempotent, run after a clone)."
	@echo "  make plan        Show what terraform will change, apply nothing."
	@echo "  make deploy      Provision Hetzner box + run setup.sh end-to-end."
	@echo "  make setup       Re-run setup.sh on the existing box (no new server)."
	@echo "  make ssh         Open an interactive SSH session to the concentrator."
	@echo "  make wg          Show live WireGuard peer state on the box."
	@echo "  make destroy     Tear down the Hetzner server (billing stops immediately)."

TF := terraform -chdir=terraform

.PHONY: init
init:
	$(TF) init -input=false -upgrade

.PHONY: plan
plan:
	$(TF) plan -input=false

.PHONY: deploy
deploy:
	./deploy.sh

.PHONY: setup
setup:
	@IP=$$( $(TF) output -raw ipv4 ); \
	KEY=$$( awk -F'=' '/^ssh_public_key_path/{gsub(/[" ]/,"",$$2); print $$2}' terraform/terraform.tfvars | sed "s|~|$$HOME|" ); \
	PRIV=$${KEY%.pub}; \
	rsync -azP --delete -e "ssh -i $$PRIV -o StrictHostKeyChecking=accept-new" \
	  --exclude '.git' --exclude 'infra/out' \
	  ../server/ root@$$IP:/root/cloakvpn/server/; \
	ssh -i $$PRIV -o StrictHostKeyChecking=accept-new root@$$IP \
	  "chmod +x /root/cloakvpn/server/scripts/*.sh && /root/cloakvpn/server/scripts/setup.sh"

.PHONY: ssh
ssh:
	@IP=$$( $(TF) output -raw ipv4 ); \
	KEY=$$( awk -F'=' '/^ssh_public_key_path/{gsub(/[" ]/,"",$$2); print $$2}' terraform/terraform.tfvars | sed "s|~|$$HOME|" ); \
	PRIV=$${KEY%.pub}; \
	ssh -i $$PRIV root@$$IP

.PHONY: wg
wg:
	@IP=$$( $(TF) output -raw ipv4 ); \
	KEY=$$( awk -F'=' '/^ssh_public_key_path/{gsub(/[" ]/,"",$$2); print $$2}' terraform/terraform.tfvars | sed "s|~|$$HOME|" ); \
	PRIV=$${KEY%.pub}; \
	ssh -i $$PRIV root@$$IP "wg show wg0; echo; systemctl is-active cloak-rosenpass.service"

.PHONY: destroy
destroy:
	@echo "This will destroy the Hetzner server. Billing stops immediately."
	@read -p "Type the server name to confirm: " name; \
	   actual=$$( $(TF) output -raw server_name ); \
	   [ "$$name" = "$$actual" ] || { echo "Mismatch — aborting."; exit 1; }; \
	   $(TF) destroy -auto-approve
