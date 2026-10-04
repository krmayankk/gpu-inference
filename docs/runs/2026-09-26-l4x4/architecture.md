# Architecture — as deployed on 2026-09-26/27

Everything below is from the live cluster (see `evidence/`). The narrative walk-through
is `docs/tutorials/phase-2-l4x4-first-live-run.md`.

## Versions

| Layer | Component | Version |
|---|---|---|
| Cloud | EKS, us-east-1 | Kubernetes `v1.34.11-eks` |
| Nodes | 4× g6.2xlarge (1× NVIDIA L4 24GB, Ada 8.9) + 2× t3.medium | AMI `AL2023_x86_64_NVIDIA`, driver 580 |
| GPU stack | NVIDIA GPU Operator (device plugin, GFD, DCGM exporter) | `v26.7.1` |
| Distributed runtime | KubeRay operator / Ray | `1.7.1` / `2.48.0` |
| Serving | vLLM (`vllm/vllm-openai`) | `v0.24.0` |
| Model | `Qwen/Qwen3.8-27B-FP8` — 64 layers, hybrid Gated DeltaNet + attention | 30.9GB fp8 |
| Observability | kube-prometheus-stack | `91.7.0` |
| Deployed commit | tag `runs/2026-09-26-l4x4` | `d84ea1d` (evidence capture time; kept reachable by the tag — its changes are on master via PR #8) |

## Nodes and what runs on them

| Instance | Type | Zone | Role | Runs |
|---|---|---|---|---|
| i-0cc663d2dea6b8d94 | t3.medium | us-east-1a | system | CoreDNS, Grafana, KubeRay operator, NFD master |
| i-0ddce47180b3ddf96 | t3.medium | us-east-1b | system | Prometheus, GPU operator controller, chat UI |
| 4× g6.2xlarge | g6.2xlarge | us-east-1b | GPU (tainted `nvidia.com/gpu`) | one Ray pod each + NVIDIA DaemonSets (device plugin, GFD, DCGM exporter, validators) |

All four GPU nodes landed in one zone — by capacity luck, not design (incident #1).

## Namespaces

`inference` (vLLM on Ray, chat UI) · `kuberay` (operator) · `gpu-operator` (NVIDIA stack)
· `observability` (Prometheus, Grafana) · built-ins: `default`, `kube-system`,
`kube-public`, `kube-node-lease`. Every name is set explicitly by `scripts/up.sh`.

## Processes per pod

| | Head pod | Each of 3 worker pods |
|---|---|---|
| vLLM API server (`vllm serve`, PID 1) | ✅ | — |
| vLLM engine (`VLLM::EngineCore`) | ✅ | — |
| vLLM pipeline stage (`RayWorkerProc`) | ✅ stage 0 (`Worker_PP0`) | ✅ one stage each (PP1–PP3) |
| Ray GCS (control plane, :6379) | ✅ | — |
| Ray raylet + dashboard agent | ✅ | ✅ |
| `cache-sync` sidecar (aws-cli) | ✅ | — |

## Request flow

```
VS Code (Continue) / chat UI / curl
   │  OpenAI API, HTTP
   ▼
laptop:8000 ──kubectl port-forward──▶ Service "inference" :8000 (ClusterIP, selects the Ray head)
   ▼
head: vllm serve  ── tokenize, chat template, tool-call parsing (qwen3_coder)
   ▼
head: EngineCore  ── schedule + batch requests; each step fans out over vLLM's own
   │                  message queue (shm_broadcast → ZeroMQ), not through Ray
   ▼
stage 0 (head GPU) → stage 1 → stage 2 → stage 3   ← activations cross the VPC network
   │                                                   16 layers per stage
   └── next token back to the engine; repeat per token
```

Ray's role: join the four pods into one cluster (raylets register with GCS), grant the
engine's placement group (4 × 1 GPU, all-or-nothing), start and supervise the
`RayWorkerProc` stages. After start-up it is not in the per-token data path — confirmed
by the py-spy flame graph (`screenshots/14-…`).

## How a pod gets its GPU

Device-plugin model, not DRA: `resources.limits: nvidia.com/gpu: 1` + toleration for
the `nvidia.com/gpu` taint + `nodeSelector: nvidia.com/gpu.present=true`. The GPU is an
integer; which GPU (model, memory) lives only in GFD node labels. DRA's API is present
on 1.34 (GA) with no objects (`evidence/dra.txt`).

## Health and observability

- Head: startup / readiness / liveness all HTTP `GET /health` on vLLM.
- Workers: readiness / liveness HTTP `GET :52365/api/local_raylet_healthz`.
- KubeRay's injected init container and probes are **disabled** (they exec tools the
  image lacks — incidents #4, #7).
- Prometheus scrapes DCGM (per GPU, labelled with the owning pod) and vLLM (via the
  `vllm` ServiceMonitor). Dashboards: NVIDIA DCGM (#12239), vLLM official.
