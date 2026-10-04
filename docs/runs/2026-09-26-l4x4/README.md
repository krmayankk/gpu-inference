# Run: l4x4 first live boot — 2026-09-26/27

**Qwen3.8-27B-FP8 on 4× NVIDIA L4 across 4 EKS nodes, vLLM v0.24.0 pipeline-parallel
(PP=4) on KubeRay.** Phase 2's first live run: a model that cannot fit any single GPU,
served behind the same seam as the mock and the 1-GPU profile, driven from VS Code.

| | |
|---|---|
| Walk-through (blog draft) | [`docs/tutorials/phase-2-l4x4-first-live-run.md`](../../tutorials/phase-2-l4x4-first-live-run.md) |
| What ran where | [`architecture.md`](architecture.md) |
| Every problem hit, and its fix | [`incidents.md`](incidents.md) — 16 entries |
| Raw proof | [`evidence/`](evidence/) — captured live with `make evidence` |
| Screenshots | [`screenshots/`](screenshots/) — Grafana (DCGM, vLLM), Ray dashboard, VS Code |
| How the setup works (not run-specific) | [`platform/serving/gpus/l4x4/README.md`](../../../platform/serving/gpus/l4x4/README.md) |

## The story in 60 seconds

1. **Problem:** a 30.9GB model, GPUs with 24GB. It cannot run on one GPU.
2. **Design:** split it into 4 pipeline stages (16 layers each) on 4 L4s on 4 machines;
   vLLM uses Ray to place the stages; one Service keeps the endpoint identical to the
   1-GPU and mock setups.
3. **What broke:** 16 real problems — GPU capacity in the zone, missing namespace,
   KubeRay defaults that assume tools the vLLM image lacks, unscraped metrics,
   double-uploaded weights. Each has a raw symptom, a root cause, and a fix that is now
   on master.
4. **What it did:** contract 11/11, 8.1 tok/s per request, all 4 GPUs at 100% under
   concurrent load, used for real coding from VS Code.
5. **What it cost, and proof it's gone:** ~$20; 67 resources destroyed, zero residual.

## Mental map — what this folder proves, and where

| Question | Answer in | Look at |
|---|---|---|
| Did it really run on 4 GPUs on 4 machines? | `evidence/` | `instances.txt`, `nodes.txt` (GPU labels per node), `nvidia-smi.txt` (every GPU), `pods-all.txt` |
| How does a pod get a GPU? | `evidence/` | `gpu-request.txt`, `gpu-operator.txt`, `dra.txt` (DRA present, unused) |
| Did Ray form one cluster, and where does vLLM run? | `evidence/` | `raycluster.txt`, `ray-status.txt` (4/4 GPU), `processes-per-pod.txt`; `screenshots/12–13` |
| What's in the image, what's installed? | `evidence/` | `image-anatomy.txt`, `helm-releases.txt`, `namespaces.txt` |
| What went wrong, live? | `incidents.md`, `evidence/events.txt` | Kubernetes events (they expire after ~1h — captured during the run) |
| Does it behave like every other profile? | `evidence/contract.txt` | the same 11 assertions as mock and 1×L4 |
| How fast? | `evidence/bench.txt`, `evidence/vllm-metrics.txt` | `screenshots/08–11` (vLLM dashboard), `prometheus-session.json` |
| Were the GPUs actually busy? | `screenshots/01–07` | DCGM: temperature, clocks, utilization, tensor cores, all 4 at 100% |
| Is Ray in the per-token path? | `screenshots/14` | py-spy flame graph of the vLLM engine — no |
| Is it useful for real work? | `evidence/vscode-go/`, `evidence/codetest/` | code written via VS Code (Continue) on this model; `screenshots/05` |
| What did it cost; is anything left? | this README | Cost, Teardown proof (below) |

**How the evidence was captured:** `make evidence` (`scripts/evidence.sh`) — read-only
`kubectl`/`aws`/`helm` commands, each output file headed by the exact command, account id
and local paths redacted. Raw outputs, not summaries, so a reader can trust them.

## Results

| Measure | Value | Evidence |
|---|---|---|
| Seam contract (same 11 assertions as mock + 1×L4) | **11/11 pass** | `evidence/contract.txt` |
| Single-request decode | **8.1 tok/s** (Phase 1: 7B on 1×L4 = 28.8) | `evidence/bench.txt` |
| Time to first token, short prompt | **0.43 s** | `evidence/bench.txt` |
| Time to first token, ~5–10K-token agent prompts | up to **~7.5 s** (no prefix caching) | `screenshots/09-…` |
| Concurrent requests, per-request decode | 7.4 tok/s with 2–3 in flight; all 4 GPUs at 100% together | `evidence/codetest/`, `screenshots/07-…` |
| Prompt vs generation throughput | ~280 vs ~10 tok/s | `screenshots/08-…` |
| KV-cache peak | ~3% | `screenshots/09-…` |
| GPU memory per stage | 8.8–11.7 GB of 23 GB | `evidence/nvidia-smi.txt` |
| VS Code agent (Continue), requests served | 55; avg prompt 5,013 tokens (276K total) | session notes |
| Coding: Go binary search | compiled and ran first try | `evidence/vscode-go/binarysearch/` |
| Coding: Go + JS bouncing-ball game | works; "janky" (keyboard stutter, frame-rate-dependent paddle, tunnelling at speed) | `evidence/vscode-go/bounceball/` |
| Coding: Python log CLI, one shot, no feedback | program correct; own tests 5/8 (3 test bugs: float equality ×2, scoping ×1) | `evidence/codetest/` |
| Thinking mode (low), same task | spent ~2K tokens reasoning, hit the 6K cap before writing tests | `evidence/codetest/thinking-stats.json` |

**Quality verdict (reviewer's opinion, not a benchmark):** a competent mid-level first
draft — ~75–80% of the way to frontier on the game task; the gap is polish and edge-case
physics, not structure. A large step up from Phase 1's 7B, whose code did not compile.

## Timeline (PDT, approximate — from logs, events and instance launch times)

| Time | Event |
|---|---|
| ~22:25 | `make up POOL=aws GPU=l4x4` (VPC, then EKS control plane ~10 min) |
| 22:37–22:49 | system nodes up; GPU capacity exhausted in 1a/1b; 3 then 4 GPU nodes land in 1b |
| 22:50 | Terraform complete (67 resources); TTL armed (+6h) |
| 22:53 | RayCluster applied — into `default` (incident #2) |
| 22:57 | fixed; Ray head up; workers stuck on injected init (incident #4) |
| 23:13 | workers join; placement group 4/4 GPU |
| 23:21 | head Ready; contract 11/11; 8.1 tok/s |
| 23:24 | head killed by injected `wget` liveness (incident #7) |
| 23:37 | own HTTP probes; all pods Ready, workers Ready for the first time |
| 23:42–00:40 | VS Code (Continue) coding sessions, concurrent tests, dashboards |
| 00:44 | `make cache-weights`; `make down` |

## Cost

Credits remaining before the run settled: **$112.42** (`aws freetier get-account-plan-state`).
Estimated run cost ~$20: GPUs ~$8, NAT data for two model downloads ~$11, other ~$1.
Actual from Cost Explorer: *to be added once billing settles (~24h).*

## Teardown proof

`make down` (2026-09-27 ~01:05 PDT):

```
Destroy complete! Resources: 67 destroyed.
 ok  aws pool destroyed (verify-zero-orphans runs next)
─── verify zero orphans — pool=aws ───
==> tag sweep: Project=gpu-inference AND Ephemeral=true (liveness-resolved)
 ok  zero residual resources for pool 'aws'
─── down complete — zero residual resources ───
```

Independent account-wide check in us-east-1 afterwards (not tag-filtered):

```
EKS clusters       : 0
EC2 instances live : 0
  of which GPU (g*) : 0
Auto Scaling Groups: 0
Project VPCs       : 0
NAT gateways live  : 0
Security groups (non-default VPCs): 0
Load balancers     : 0 (v2), 0 (classic)
Unattached EBS     : 0
Elastic IPs        : 0
```

Persistent by design (ADR-0005/0007): the Terraform state backend and the weights
cache bucket (30.9GB after the de-duplication fix, ~$0.70/month).
