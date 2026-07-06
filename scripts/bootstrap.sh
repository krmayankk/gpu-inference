#!/usr/bin/env bash
# bootstrap.sh — one-time creation of the Terraform remote-state backend
# (S3 bucket + DynamoDB lock table). Only needed for cloud pools; the local
# pool keeps no remote state. Idempotent: safe to re-run.
#
# The bootstrap itself uses LOCAL state (chicken-and-egg: the bucket that backs
# remote state cannot live in the state it backs). Its footprint is tiny and is
# the one deliberate exception to full ephemerality — it is cheap and shared.
source "$(dirname "$0")/lib.sh"
require terraform
require aws

banner "bootstrap: remote state + weights cache (AWS)"
warn "this creates the two sanctioned persistent resources (Ephemeral=false):"
warn "  - TF state bucket + DynamoDB lock table (pennies/mo)"
warn "  - model weights cache bucket (60-day lifecycle, ADR-0005)"
# Non-interactive by design: the explicit `make bootstrap` invocation is the
# consent; these two resources are the sanctioned persistent tier (pennies/mo).
terraform -chdir="${ROOT}/infra/bootstrap" init -input=false
terraform -chdir="${ROOT}/infra/bootstrap" apply -auto-approve -input=false
ok "bootstrap ready — cloud pools can now 'terraform init' against it"
