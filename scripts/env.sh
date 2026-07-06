#!/usr/bin/env bash
# env.sh — print eval-able exports wiring a NEW terminal to the running
# platform. The platform deliberately never touches ~/.kube/config; this hands
# your shell the same isolated context the scripts use.
#
#   eval "$(make env)"            # or: eval "$(scripts/env.sh)"
#   kubectl -n inference get pods
#
# Notes:
#   - On the aws pool, kubectl auth shells out to `aws eks get-token`, which
#     needs the MFA session profile — exported here as AWS_PROFILE=mfa if that
#     profile exists.
#   - Output is ONLY export lines on stdout (everything else on stderr), so
#     eval is safe.
source "$(dirname "$0")/lib.sh"

[[ -f "${KUBECONFIG_PATH}" ]] || die "no kubeconfig at ${KUBECONFIG_PATH} — run 'make up' first"

echo "export KUBECONFIG=${KUBECONFIG_PATH}"
if grep -q "eks" "${KUBECONFIG_PATH}" 2>/dev/null && \
   grep -q "^\[mfa\]" "${HOME}/.aws/credentials" 2>/dev/null; then
  echo "export AWS_PROFILE=mfa"
fi
dim "wired. try: kubectl -n ${NAMESPACE} get pods"
