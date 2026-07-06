#!/usr/bin/env bash
# lint.sh — static checks that must pass before a PR. Degrades gracefully when
# an optional tool is missing (warns, does not fail), so it runs locally and in
# CI unchanged. Hard-fails only on real violations.
source "$(dirname "$0")/lib.sh"
rc=0

banner "lint"

# --- shell ---
if command -v shellcheck >/dev/null 2>&1; then
  log "shellcheck"
  # lib.sh is sourced, not executed; -x follows the source directives.
  shellcheck -x "${ROOT}/scripts/"*.sh "${ROOT}/infra/pools/"*/*.sh || rc=1
else
  warn "shellcheck not installed — skipping shell lint"
fi

# --- kustomize (via kubectl; no cluster needed) ---
log "kustomize build"
for overlay in \
  platform/serving/overlays/mock \
  platform/serving/gpus/t4 \
  platform/serving/gpus/l4 \
  platform/serving/gpus/h100 \
  platform/chat; do
  if kubectl kustomize "${ROOT}/${overlay}" >/dev/null; then
    ok "${overlay}"
  else
    warn "kustomize build failed: ${overlay}"; rc=1
  fi
done

# --- terraform ---
if command -v terraform >/dev/null 2>&1; then
  log "terraform fmt"
  if ! terraform fmt -check -recursive "${ROOT}/infra" >/dev/null 2>&1; then
    warn "terraform fmt would change files (run: terraform fmt -recursive infra/)"; rc=1
  fi
  # validate needs init; fmt is the cheap no-network guard for lint.
else
  warn "terraform not installed — skipping HCL checks"
fi

[[ $rc -eq 0 ]] && ok "lint passed" || die "lint found issues"
