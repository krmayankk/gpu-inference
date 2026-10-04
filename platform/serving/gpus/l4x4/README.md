# profile: l4x4

**One model across 4 GPUs on 4 machines.** `Qwen/Qwen3.8-27B-FP8` is 30.9GB; an L4
has 24GB — no single GPU can hold it. So the model is split into 4 pieces, 16 of its
64 layers per GPU: **pipeline parallelism, PP=4** (ADR-0011). Everything below exists
to make those 4 pieces behave like one model behind one endpoint.

This page explains how the layers fit together, bottom to top. The manifests
(`raycluster.yaml`, `service.yaml`) carry the per-line rationale.

## 1. Machines — Terraform (`infra/pools/aws`)

- **4× g6.2xlarge, one L4 each** (`gpu_profiles.l4x4.node_count = 4`), **tainted**
  `nvidia.com/gpu` so only pods that explicitly tolerate it land there.
- **2× t3.medium** for everything else (DNS, Prometheus, Grafana, operators, chat UI).
- The `AL2023_x86_64_NVIDIA` AMI already has the NVIDIA driver and container toolkit.

## 2. Making GPUs schedulable — NVIDIA GPU Operator (Helm, `scripts/up.sh`)

Kubernetes doesn't know what a GPU is. On every GPU node the operator runs:

- **device plugin** — advertises `nvidia.com/gpu: 1` as a resource a pod can request
- **GFD** — node labels such as `nvidia.com/gpu.present=true` and the GPU model
- **DCGM exporter** — per-GPU metrics for Prometheus

A pod gets a GPU with `limits: nvidia.com/gpu: "1"`, plus the toleration and a
`nodeSelector` on that label.

## 3. Ray and KubeRay

- **Ray** is a distributed runtime: several machines join one *Ray cluster* — a
  **head** running the control plane (**GCS**, :6379) and **workers**, each running a
  **raylet** that reports "I have 1 GPU". Programs then ask Ray to "run this on a GPU
  somewhere".
- **vLLM uses Ray** (`--distributed-executor-backend=ray`) to start one pipeline stage
  per GPU, across machines.
- **KubeRay** is a Kubernetes operator (Helm, `scripts/up.sh`, pinned 1.7.1). It adds the
  **`RayCluster`** resource: declare "1 head + 3 workers with this pod template" and it
  creates the pods, the head's Service (`inference-head-svc`), and the commands that
  join them.

A `RayCluster` is roughly *a Deployment for a Ray cluster*: you describe the shape, the
operator makes pods that find each other.

## 4. This RayCluster (`raycluster.yaml`)

Four pods, one per GPU node, all on **`vllm/vllm-openai:v0.24.0`** — vLLM is "installed"
by using vLLM's own image. Each pod boots in order:

| Step | Head pod | Each of 3 worker pods |
|---|---|---|
| 1. init `weights-prefetch` | `aws s3 sync` weights from the cache bucket → `/cache` (node-local) | same, its own copy |
| 2. install Ray | `uv pip install ray==2.48.0` — **the vLLM image has no Ray**, so it's added at boot | same |
| 3. join | `ray start --head` (starts GCS) | **wait** until the head's GCS answers, then `ray start` |
| 4. serve | `exec vllm serve Qwen/Qwen3.8-27B-FP8 --pipeline-parallel-size=4 …` | nothing more — Ray hands it work |

### Who starts vLLM? (the head pod runs two different things)

Ray does not decide to run vLLM. **vLLM is the boss; Ray is the mechanism it uses to run
code on other machines.**

1. **Ray comes up in all 4 pods — nothing else yet.** Head: `ray start --head` (GCS +
   raylet). Workers: `ray start` (raylet) and join. Result: a 4-GPU Ray cluster, **no
   vLLM anywhere**.
2. **The head pod's own script then runs `vllm serve`.** Not started by Ray — it is the
   next line of the same shell (`exec` replaces the shell, so vLLM becomes the
   container's main process). This is the **main vLLM process**: API server + engine.
3. **The main vLLM process uses Ray as a remote process launcher.** It tells Ray:
   "reserve 4 GPUs, all-or-nothing (a *placement group*), and run my pipeline-stage code
   on each." Ray's raylets then start one **vLLM stage process** per GPU — in the head
   pod too — and each stage loads **its 16 layers** from the local `/cache`.
4. **From then on the main vLLM process drives everything:** it takes requests and
   pushes tokens through the 4 stages over vLLM's own channel. Ray just keeps the stage
   processes alive; it is not in the per-token path.

```
head pod:    Ray (GCS + raylet)   +  vllm serve (main process) ──asks Ray──┐
                                  +  stage 0, layers  1-16  ◀── Ray starts ─┤
worker 1:    Ray (raylet)         +  stage 1, layers 17-32  ◀── Ray starts ─┤
worker 2:    Ray (raylet)         +  stage 2, layers 33-48  ◀── Ray starts ─┤
worker 3:    Ray (raylet)         +  stage 3, layers 49-64  ◀── Ray starts ─┘
```

So yes, Ray starts vLLM on the workers — but only the *stage* processes, and only
because the main vLLM process on the head asked it to.

`ray.io/overwrite-container-cmd: "true"` tells KubeRay "use our command, not yours" —
that is how "install Ray first" and "then run vLLM after `ray start`" fit in.

## 5. Health

- **Head:** `GET /health` on vLLM — *startup* (up to ~30 min to load), *readiness*
  (no traffic until serving), *liveness* (restart if hung).
- **Workers:** `GET :52365/api/local_raylet_healthz` (Ray's own health endpoint).
- KubeRay's injected versions of these are **turned off** in `scripts/up.sh`
  (`ENABLE_INIT_CONTAINER_INJECTION`, `ENABLE_PROBES_INJECTION`): they assume `ray`
  and `wget` exist in the image, and this image has neither.

## 6. One endpoint — the seam (`service.yaml`)

Service **`inference` :8000** selects **only the head pod**, where the OpenAI-compatible
API runs. Same name and port as every other profile, so the chat UI, the contract test,
and IDE agents cannot tell one GPU from four Ray stages behind it (ADR-0002).

## 7. One request, end to end

```
client (chat UI / VS Code / curl)
  → Service inference:8000 → head pod: vllm serve
      tokenize, chat template, tool-call parsing (qwen3_coder)
  → engine batches requests, then for each next token:
      GPU0 (layers 1-16) → GPU1 (17-32) → GPU2 (33-48) → GPU3 (49-64)
        └── activations cross the network between machines
  → token back to head → streamed to client; repeat
```

The trade-off in one line: PP=4 lets a model that doesn't fit one GPU run at all, but
every token crosses 3 network hops — decode is several times slower than a model that
fits on one GPU (~8 tok/s here on the first live run vs 28.8 tok/s for Phase 1's 7B on
one L4).

## 8. Bring-up order (`make up POOL=aws GPU=l4x4` → `scripts/up.sh`)

1. Terraform — cluster + 4 GPU nodes
2. Prometheus + Grafana (`OBS=1`)
3. NVIDIA GPU Operator — GPUs become requestable
4. KubeRay operator — `RayCluster` type exists (two injections off)
5. `inference` namespace + `pool-context` ConfigMap (carries the S3 weights bucket)
6. `kubectl apply -k platform/serving/gpus/l4x4` → RayCluster + Service; then chat UI
   and the vLLM ServiceMonitor
7. wait for the head pod Ready = all 4 stages loaded, `/health` passes

**In short:** Terraform gives 4 GPU machines; the NVIDIA operator makes their GPUs
requestable; KubeRay turns 4 pods into one Ray cluster; vLLM on the head uses Ray to
place a quarter of the model on each GPU; one Service exposes it as a single
OpenAI-compatible endpoint.
