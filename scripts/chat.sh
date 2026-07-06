#!/usr/bin/env bash
# chat.sh — port-forward the chat UI and hold it open. Ctrl-C to stop (nothing
# is torn down; use `make down` for that).
source "$(dirname "$0")/lib.sh"

PORT="${PORT:-8080}"
k cluster-info >/dev/null 2>&1 || die "no running cluster — run 'make up' first"

banner "chat UI"
dim "open http://localhost:${PORT}  (Ctrl-C to stop the forward; platform stays up)"
exec k -n "${NAMESPACE}" port-forward svc/chat "${PORT}:80"
