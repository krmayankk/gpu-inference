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
  # -S warning: info-level notes (SC1091 unfollowable sources, SC2015 style)
  # are noise here — the header's contract is "hard-fails only on real
  # violations", and warning+ is that line.
  shellcheck -x -S warning "${ROOT}/scripts/"*.sh "${ROOT}/infra/pools/"*/*.sh || rc=1
else
  warn "shellcheck not installed — skipping shell lint"
fi

# --- kustomize (via kubectl; no cluster needed) ---
OVERLAYS=(
  platform/serving/overlays/mock
  platform/serving/gpus/t4
  platform/serving/gpus/l4
  platform/serving/gpus/h100
  platform/chat
)
log "kustomize build"
for overlay in "${OVERLAYS[@]}"; do
  if kubectl kustomize "${ROOT}/${overlay}" >/dev/null; then
    ok "${overlay}"
  else
    warn "kustomize build failed: ${overlay}"; rc=1
  fi
done

# --- kubeconform (manifest schema validation; CRDs skipped) ---
if command -v kubeconform >/dev/null 2>&1; then
  log "kubeconform"
  for overlay in "${OVERLAYS[@]}"; do
    if kubectl kustomize "${ROOT}/${overlay}" 2>/dev/null \
        | kubeconform -strict -ignore-missing-schemas -summary=false -; then
      ok "${overlay}"
    else
      warn "kubeconform failed: ${overlay}"; rc=1
    fi
  done
else
  warn "kubeconform not installed — skipping manifest schema validation"
fi

# --- actionlint (GitHub Actions workflows) ---
if command -v actionlint >/dev/null 2>&1; then
  log "actionlint"
  if actionlint; then ok "workflows"; else warn "actionlint found issues"; rc=1; fi
else
  warn "actionlint not installed — skipping workflow lint"
fi

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

# --- repo invariants (the mechanical subset of the sentinel skills) ---------
# Deterministic checks need no LLM and no trust ladder: they block from day
# one. Sentinel keeps the judgment residue (seam leakage, blast radius);
# these are the rules a grep can enforce (ADR-0002/0004/0006).
log "repo invariants"

# Every pool must ship the lifecycle triple — a pool without orphans.sh
# cannot prove teardown (ADR-0006).
pool_rc=0
for pool in "${ROOT}"/infra/pools/*/; do
  for f in up.sh down.sh orphans.sh; do
    if [[ ! -f "${pool}${f}" ]]; then
      warn "pool $(basename "${pool}") missing ${f} — cannot prove teardown"; pool_rc=1; rc=1
    fi
  done
done
[[ $pool_rc -eq 0 ]] && ok "pools ship up.sh/down.sh/orphans.sh"

# Every GPU profile must pin the public model id (ADR-0002).
prof_rc=0
for prof in "${ROOT}"/platform/serving/gpus/*/; do
  if ! grep -rq -- "--served-model-name=gpu-inference" "${prof}"; then
    warn "profile $(basename "${prof}") does not pin --served-model-name=gpu-inference"; prof_rc=1; rc=1
  fi
done
[[ $prof_rc -eq 0 ]] && ok "profiles pin served-model-name=gpu-inference"

# fp8 must never land in the t4 profile — Turing silently emulates it
# (ADR-0004). Matches any quantization/kv-cache-dtype fp8 setting in any YAML
# shape (list item, env value, inline string); comment lines are excluded so
# prose ABOUT fp8 ("Turing has no hw FP8") doesn't trip it.
if grep -rhE -- '(quantization|kv-cache-dtype)[=: ]+"?fp8' "${ROOT}/platform/serving/gpus/t4/" \
    | grep -vE '^\s*#' | grep -q .; then
  warn "fp8 setting in the t4 profile (Turing has no hardware FP8)"; rc=1
else
  ok "no fp8 settings in t4"
fi

[[ $rc -eq 0 ]] && ok "lint passed" || die "lint found issues"
