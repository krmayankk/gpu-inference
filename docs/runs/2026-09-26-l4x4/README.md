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

*Filled from `make down` output.*
