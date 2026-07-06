#!/usr/bin/env bash
# verify-zero-orphans.sh — prove POOL owns zero residual resources.
#
# Each pool knows how to prove its own emptiness (kind: no cluster/containers;
# aws: tag sweep + explicit EBS/EIP/LB/NAT checks). This wrapper just dispatches
# and turns "not empty" into a hard failure.
source "$(dirname "$0")/lib.sh"

banner "verify zero orphans — pool=${POOL}"

if [[ ! -x "${POOL_DIR}/orphans.sh" ]]; then
  die "pool '${POOL}' cannot prove teardown (no orphans.sh) — refusing to claim zero"
fi

if "${POOL_DIR}/orphans.sh"; then
  ok "zero residual resources for pool '${POOL}'"
else
  die "ORPHANS DETECTED for pool '${POOL}' — see above. The platform is NOT torn down."
fi
