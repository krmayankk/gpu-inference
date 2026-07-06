#!/usr/bin/env bash
# ensure-helm.sh — download helm into ./bin if the host has none (same
# zero-install pattern as kind in infra/pools/local-kind/_kind.sh).
source "$(dirname "$0")/lib.sh"

HELM_VERSION="${HELM_VERSION:-v3.16.4}"

command -v helm >/dev/null 2>&1 && exit 0

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) die "unsupported arch $(uname -m) for helm auto-download" ;;
esac

mkdir -p "${BIN_DIR}"
log "downloading helm ${HELM_VERSION} -> ${BIN_DIR}/helm"
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-${os}-${arch}.tar.gz" \
  | tar -xz -C "${BIN_DIR}" --strip-components=1 "${os}-${arch}/helm"
chmod +x "${BIN_DIR}/helm"
ok "helm ready at ${BIN_DIR}/helm"
