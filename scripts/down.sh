#!/usr/bin/env bash
# down.sh — destroy the entire platform on POOL, then PROVE nothing is left.
#
# The teardown is not "done" until the zero-orphan check passes. That coupling
# is the cost guarantee (ADR-0006): you cannot leak a GPU node and call it torn
# down.
source "$(dirname "$0")/lib.sh"

banner "down — pool=${POOL}"

# Destroying the substrate removes everything inside it; no need to delete k8s
# objects first. The pool owns knowing how (kind delete / terraform destroy).
pool_hook down

# The proof. A non-zero exit here means the teardown lied.
"${ROOT}/scripts/verify-zero-orphans.sh"

banner "down complete — zero residual resources"
