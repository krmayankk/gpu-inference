#!/usr/bin/env bash
# grafana.sh — port-forward Grafana (installed by OBS=1). DCGM dashboards show
# the metrics that matter for inference (PLAN §5): MEM_COPY_UTIL (the real
# decode bottleneck), FB_USED (KV-cache pressure), GPU_UTIL, POWER_USAGE.
source "$(dirname "$0")/lib.sh"

PORT="${PORT:-3000}"
k cluster-info >/dev/null 2>&1 || die "no running cluster — run 'make up' first"
k -n observability get svc obs-grafana >/dev/null 2>&1 || die "Grafana not installed — bring the platform up with OBS=1"

pass="$(k -n observability get secret obs-grafana -o jsonpath='{.data.admin-password}' | base64 -d)"
banner "grafana"
dim "open http://localhost:${PORT}  (admin / ${pass})"
dim "Ctrl-C stops the forward; platform stays up"
exec k -n observability port-forward svc/obs-grafana "${PORT}:80"
