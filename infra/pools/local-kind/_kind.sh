# shellcheck shell=bash
# _kind.sh — helpers shared by the local-kind pool hooks. Sourced after lib.sh.

KIND_VERSION="${KIND_VERSION:-v0.24.0}"

# ensure_kind — echo a path to a usable `kind`, downloading into ./bin if the
# host has none. Keeps the $0 substrate zero-install for the user.
ensure_kind() {
  if command -v kind >/dev/null 2>&1; then command -v kind; return 0; fi
  local kb="${BIN_DIR}/kind"
  if [[ -x "${kb}" ]]; then echo "${kb}"; return 0; fi

  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported arch $(uname -m) for kind auto-download" ;;
  esac
  mkdir -p "${BIN_DIR}"
  log "downloading kind ${KIND_VERSION} -> ${kb}"
  curl -fsSL "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${os}-${arch}" -o "${kb}"
  chmod +x "${kb}"
  echo "${kb}"
}
