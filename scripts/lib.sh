# shellcheck shell=bash
# ---------------------------------------------------------------------------
# scripts/lib.sh — shared library sourced by every script and pool hook.
#
# Contract: sourcing this file is side-effect-free except for setting `set`
# options and exporting the project constants below. It must never provision,
# destroy, or mutate anything. Behaviour lives in the callers.
# ---------------------------------------------------------------------------

set -euo pipefail

# --- Project identity (single source of truth for names + tags) ------------
# Every cloud resource the platform creates MUST carry these tags. Teardown's
# zero-orphan proof is only as trustworthy as this tagging discipline (ADR-0006).
export PROJECT="${PROJECT:-gpu-inference}"
export TAG_PROJECT="${PROJECT}"
export TAG_EPHEMERAL="true"
export TAG_MANAGED_BY="make"

# --- Repo layout -----------------------------------------------------------
# ROOT is the repo root regardless of the caller's CWD.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ROOT="$(cd "${LIB_DIR}/.." && pwd)"
export BIN_DIR="${ROOT}/bin"               # tool-local downloads (gitignored)
# Auto-downloaded tools (kind, helm) resolve before system ones; keeps the
# platform zero-install without touching the host.
export PATH="${BIN_DIR}:${PATH}"
export KUBECONFIG_PATH="${ROOT}/.kubeconfig"

# --- Platform selection ----------------------------------------------------
# POOL is the only provider/hardware-specific seam (ADR-0002). Everything else
# is invariant. Default to the $0 local substrate (ADR-0009).
export POOL="${POOL:-local-kind}"
export CLUSTER="${CLUSTER:-gpu-inference}"
export NAMESPACE="${NAMESPACE:-inference}"

# GPU profile selects platform/serving/gpus/<GPU>/ (model, quantization, TP)
# and the pool's instance-type row. Only consumed by GPU pools; the local mock
# ignores it. l4 is the Phase-1 default (ADR-0004; quota cleared 2026-07).
export GPU="${GPU:-l4}"

# SERVING is the pod behind the invariant `inference` Service. The local pool
# runs the CPU mock; every GPU pool runs vLLM. Derived, not asked.
if [[ -z "${SERVING:-}" ]]; then
  case "${POOL}" in
    local-kind|local-*) SERVING="mock" ;;
    *)                  SERVING="vllm" ;;
  esac
fi
export SERVING

export POOL_DIR="${ROOT}/infra/pools/${POOL}"

# Pool capability metadata (GPU_CAPABLE etc.) — how the invariant layer learns
# what a pool can host without learning what it is.
GPU_CAPABLE=0
[[ -f "${POOL_DIR}/pool.env" ]] && source "${POOL_DIR}/pool.env"
export GPU_CAPABLE

# Runtime seam data emitted by cloud pools at 'up' (weights bucket, region…);
# published into the cluster as the pool-context ConfigMap. Gitignored.
export POOL_CONTEXT_PATH="${ROOT}/.pool-context"

# OBS=1 installs Prometheus/Grafana (+DCGM dashboards on GPU pools). Defaults
# on for GPU pools (Phase 1 includes observability), off for local/CI speed.
export OBS="${OBS:-${GPU_CAPABLE}}"

# --- Logging ---------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  _c_reset=$'\033[0m'; _c_dim=$'\033[2m'; _c_red=$'\033[31m'
  _c_grn=$'\033[32m'; _c_ylw=$'\033[33m'; _c_blu=$'\033[36m'
else
  _c_reset=; _c_dim=; _c_red=; _c_grn=; _c_ylw=; _c_blu=
fi

log()  { printf '%s==>%s %s\n'  "${_c_blu}" "${_c_reset}" "$*" >&2; }
ok()   { printf '%s ok %s %s\n' "${_c_grn}" "${_c_reset}" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "${_c_ylw}" "${_c_reset}" "$*" >&2; }
dim()  { printf '%s    %s%s\n'  "${_c_dim}" "$*" "${_c_reset}" >&2; }
die()  { printf '%serr %s %s\n' "${_c_red}" "${_c_reset}" "$*" >&2; exit 1; }

# require <cmd> [hint] — fail fast with an actionable message if a tool is absent.
require() {
  local cmd="$1" hint="${2:-}"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  die "required tool '${cmd}' not found${hint:+ — ${hint}}"
}

# pool_hook <name> — run infra/pools/$POOL/<name>.sh if it exists.
# This is the dispatch that keeps the provider seam thin: up/down/verify never
# learn what a pool is, they just invoke its hooks.
pool_hook() {
  local name="$1"; shift || true
  local script="${POOL_DIR}/${name}.sh"
  [[ -x "$script" ]] || die "pool '${POOL}' has no '${name}' hook (${script})"
  log "pool[${POOL}] ${name}"
  "$script" "$@"
}

# k — kubectl bound to this platform's kubeconfig, never the caller's default.
k() { kubectl --kubeconfig "${KUBECONFIG_PATH}" "$@"; }
export -f k 2>/dev/null || true

banner() {
  printf '\n%s─── %s ───%s\n' "${_c_blu}" "$*" "${_c_reset}" >&2
}
