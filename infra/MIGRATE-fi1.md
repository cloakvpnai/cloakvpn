# Migrate live `cloak-fi1` from flat layout → module + regions layout

## What this does

Before: terraform state for the live fi1 box lives in `infra/terraform/terraform.tfstate`, with resources at flat addresses (`hcloud_ssh_key.admin`, etc.).

After: state lives in `infra/terraform/regions/fi1/terraform.tfstate`, with resources at module addresses (`module.concentrator.hcloud_ssh_key.admin`, etc.).

**The running Hetzner VM is not touched.** `terraform state mv` only moves terraform's bookkeeping. The server keeps running, the tunnel keeps up, no reboot, no IP change.

After migration, `terraform plan` will show three small in-place updates — those are cosmetic renames (not destroy/recreate):

- `hcloud_ssh_key.admin.name`: `"cloakvpn-admin"` → `"cloakvpn-admin-cloak-fi1"`
- `hcloud_firewall.cloak.name`: `"cloakvpn-fw"` → `"cloakvpn-fw-cloak-fi1"`
- `hcloud_server.concentrator.labels`: add `region = "cloak-fi1"`

Hetzner allows renaming SSH keys and firewalls in-place (the resource ID is what the server references, not the name), and labels are pure metadata. **No downtime.**

## Run it

From the repo root on your Mac:

```bash
cd infra/terraform/regions/fi1

# 1. Carry forward your existing tfvars (token + SSH key path + admin CIDRs).
if [ ! -f terraform.tfvars ]; then
  cp ../../terraform.tfvars ./terraform.tfvars
  echo "Copied tfvars from old location."
fi

# 2. Carry forward the existing state.
cp ../../terraform.tfstate ./terraform.tfstate

# 3. Initialize terraform in the new dir (downloads provider, reads the state).
terraform init -input=false

# 4. Move resources into the module address space.
terraform state mv hcloud_ssh_key.admin        module.concentrator.hcloud_ssh_key.admin
terraform state mv hcloud_firewall.cloak       module.concentrator.hcloud_firewall.cloak
terraform state mv hcloud_server.concentrator  module.concentrator.hcloud_server.concentrator

# 5. Sanity-check the plan. Should show the three in-place updates above, NOTHING with "destroy" or "replace".
terraform plan
```

**STOP** and read the plan output. Expected:

```
  # module.concentrator.hcloud_firewall.cloak will be updated in-place
  # module.concentrator.hcloud_server.concentrator will be updated in-place
  # module.concentrator.hcloud_ssh_key.admin will be updated in-place

Plan: 0 to add, 3 to change, 0 to destroy.
```

If you see **`destroy`** or **`must be replaced`** anywhere, *do not apply*. Paste the plan back to me — something drifted between the old config and the new module (most likely the `user_data` block) and we need to reconcile the difference before applying. A destroy/replace on the server would kill your live concentrator.

## Apply the cosmetic renames

```bash
terraform apply
```

Type `yes` when it asks. Hetzner will PATCH the SSH-key and firewall names and PATCH the server label. The VM is untouched.

## Verify

```bash
# Tunnel is still up?
make wg REGION=fi1

# Terraform bookkeeping is clean?
terraform -chdir=terraform/regions/fi1 plan   # should say: "No changes."
```

## Clean up the old flat layout

Once the plan above says "No changes" and `make wg REGION=fi1` shows a healthy peer, the old files in `infra/terraform/` root are dead. Remove them:

```bash
cd infra/
rm -f terraform/main.tf terraform/variables.tf terraform/outputs.tf terraform/versions.tf
rm -f terraform/terraform.tfvars terraform/terraform.tfvars.example
rm -f terraform/terraform.tfstate terraform/terraform.tfstate.backup
rm -rf terraform/.terraform terraform/.terraform.lock.hcl
```

Leave `terraform/modules/` and `terraform/regions/` alone — those are the new home.

## If something goes wrong

The old state file still exists as `terraform/terraform.tfstate` until you delete it in the cleanup step. Until then you can always:

```bash
rm -rf infra/terraform/regions/fi1/terraform.tfstate infra/terraform/regions/fi1/.terraform
# and you're back to the old layout driving the same live box
```

The live server itself is never in danger from a failed migration — terraform state commands only edit local JSON. The server cares about Hetzner API state, which neither `state mv` nor a failed apply touches.
