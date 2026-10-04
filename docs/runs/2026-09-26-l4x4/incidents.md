# Incidents — first live l4x4 run (2026-09-26/27)

Every problem hit on the run, in order: the raw symptom, the root cause, the fix, and
where it landed. Nothing here was simulated. Commits are on master via PR #8 unless noted.

| # | Found | Symptom | Root cause | Fix |
|---|---|---|---|---|
| 0 | pre-launch review | (would have been) `ray: command not found` at first boot | `vllm/vllm-openai:v0.24.0` does not ship Ray — an optional vLLM dependency | install pinned `ray[cgraph,default]==2.48.0` in every pod; verified in the real image first (`405387f`, PR #4) |
| 1 | `make up` | GPU node group stuck ~10 min | `InsufficientInstanceCapacity` for g6.2xlarge in both of the VPC's zones | GPU group spans every zone offering the type (PR #7) |
| 2 | first pods | chat `CrashLoopBackOff`: `host not found in upstream "inference"` | l4x4 kustomization had no `namespace:`; RayCluster + Service landed in `default` | `namespace: inference` + lint rule "every profile renders into `inference`" (`4ce3ed2`) |
| 3 | after #2 | new Ray pods `Pending`: `4 Insufficient nvidia.com/gpu` | old pods still held all 4 GPUs while terminating mid image pull | none needed — fallout of #2; the gang problem, visible |
| 4 | workers | `Init:1/2` for 15 min; `ray: command not found` in a loop | KubeRay-**injected** `wait-gcs-ready` init container runs `ray health-check` in the worker's own image (no Ray); its loop has no failure exit | `ENABLE_INIT_CONTAINER_INJECTION=false`; workers wait for GCS themselves after installing Ray (`660d316`) |
| 5 | fixing #4 | workers recreated with the *old* template | `helm` not on the shell's PATH; `helm … \| tail` masked the failure, so the chain continued | used the repo's `bin/helm` with `set -o pipefail`; operator upgraded first, workers recreated after |
| 6 | end of `make up` | `scripts/up.sh: line 116: unexpected EOF while looking for matching '` | `up.sh` was edited while `make up` was executing it; bash reads scripts incrementally | none to the code — lesson: never edit a running script. Platform was already up |
| 7 | ~10 min after serving | head restarted; `RuntimeError: Executor failed.`; `Liveness probe failed: bash: line 1: wget: command not found` | with no liveness declared, KubeRay **injects** exec probes that run `wget`; the image has no `wget`, so a healthy head was killed | `ENABLE_PROBES_INJECTION=false`; own HTTP probes: head `/health`, workers `:52365/api/local_raylet_healthz` (`4368f7b`) |
| 8 | `make chat` / `make grafana` | `exec: k: not found`, exit 127 | scripts did `exec k …`; `k` is a shell function, `exec` needs a program | call `kubectl --kubeconfig` directly (`4368f7b`) |
| 9 | `make cache-weights` | would fail: no `deploy/inference` | script knew only the single-pod shape | cache-sync sidecar on the Ray head; script targets it (`4368f7b`) |
| 10 | GPU metrics | `kubectl get --raw …/pods/<dcgm>:9400/proxy/metrics` hung | the EKS control plane can't reach pods on arbitrary ports (security groups open 443/10250) | use `kubectl port-forward` (tunnels via the kubelet) |
| 11 | Grafana | DCGM dashboard showed one GPU; every series "GPU 0" | dashboard #12239's `instance` variable shows one exporter by default; each node's single GPU is index 0 | select all instances; backlog: own dashboard keyed by node/stage |
| 12 | Grafana | no tokens/s, TTFT, queue or KV-cache metrics anywhere | nothing scraped vLLM's `/metrics` — in any profile | `vllm` ServiceMonitor on the `inference` Service + vLLM's official dashboard (`8c385eb`) |
| 13 | VS Code | Continue stopped mid-file; server `json.decoder.JSONDecodeError: Unterminated string` | client `maxTokens: 2048` cut a file off *inside* a tool call; the `qwen3_coder` parser got half a JSON string | client config 8192 / 12288 (not repo code) |
| 14 | `make cache-weights` | 61.8GB in S3 for a 30.9GB model | HF cache = `blobs/` + `snapshots/` symlinks; S3 has no symlinks, so every file uploaded twice | `--exclude "*/blobs/*"`; duplicate prefix deleted (`69d611f`) |
| 15 | vLLM metrics | `prefix_cache_queries_total 0` | prefix caching not active for this hybrid (DeltaNet) model on v0.24.0 — every turn re-reads the whole conversation (~5K tokens avg) | **open**: investigate enabling it; biggest TTFT win available |

## Patterns worth more than the individual fixes

- **Four failures, one assumption.** #0, #4 and #7 all trace to *what is inside the
  image*: no Ray, no `wget`. (Correction to commit `4368f7b`'s message: the vLLM image
  *does* have `curl`; the missing `curl` was the DCGM exporter image. See
  `evidence/image-anatomy.txt`.) Durable fix: a derived image with Ray baked in, plus
  probes that need no tools (HTTP, not exec).
- **Operators inject things.** KubeRay silently added an init container and probes
  written for *its* images. When your image differs, the injected parts fail in ways
  that look like your bug. Know what your operator adds (`kubectl get pod -o yaml`).
- **Rendering is not deploying.** Lint proved the manifests *build*; only a live run
  showed where they *land* (#2). Mechanical invariants become lint rules immediately.
- **Silence is not success.** #4 looped forever with no failure exit; #5 had its
  failure masked by a pipe. Every wait needs a deadline and every pipeline `pipefail`.
- **Capacity is the real constraint** (#1): quota was fine; the zone was empty.

## Cost of the incidents

The two model downloads through the NAT (4 pods × 31GB, twice — the second forced by
#7's pod recreation) cost roughly $10, about half the run. The S3 cache (#14 fixed)
removes that from the next boot.
