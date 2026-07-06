#!/usr/bin/env bash
# aws pool preflight — tooling + working credentials before any spend.
source "$(dirname "$0")/../../../scripts/lib.sh"
require terraform
require aws
"${ROOT}/scripts/ensure-helm.sh"   # auto-downloads into ./bin if absent
require helm "GPU operator + observability install via Helm"
require jq

aws sts get-caller-identity >/dev/null 2>&1 || die "AWS credentials not configured"

# A cheap read probe: an identity that cannot list VPCs cannot run this
# Terraform. Catches locked-down users before terraform burns 20 minutes.
if ! aws ec2 describe-vpcs --max-items 1 --region "${AWS_REGION:-us-west-2}" >/dev/null 2>&1; then
  die "this AWS identity cannot even describe VPCs — it will not survive terraform apply. Fix IAM first."
fi

ok "aws preflight passed"
