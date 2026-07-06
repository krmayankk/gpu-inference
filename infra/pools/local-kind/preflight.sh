#!/usr/bin/env bash
# local-kind preflight — docker daemon + kind available.
source "$(dirname "$0")/../../../scripts/lib.sh"
source "$(dirname "$0")/_kind.sh"
require docker "the local pool runs kind, which needs a Docker daemon"
require curl
docker info >/dev/null 2>&1 || die "docker daemon not reachable — start Docker and retry"
ensure_kind >/dev/null
ok "local-kind preflight: docker up, kind ready"
