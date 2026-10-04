# North star — gpu-inference at scale

**Where this repo is going, what "at scale" means, and the path from here.** PLAN.md
states the thesis (an ephemeral, portable GPU platform that manages itself); 
`docs/phases.md` is the build ladder. This page reconciles both with what the live runs
taught us, and turns it into the next PRs. Part 1 is the picture; Part 2 the details.

---

# Part 1 — the picture

## In one paragraph

Model a small **frontier-lab inference service**: open-weight models served on GPUs
from any cloud, behind one OpenAI-compatible front door, scaled and routed by load,
torn down to zero when idle — and an **operator agent** that keeps it healthy and cheap
by opening PRs, never by mutating it directly.

## The layers

```
 L2  inference service    front door (auth, limits, metering) · KV-aware routing
                          · replicas + autoscaling · multi-model · canaries
 L1  serving              vLLM · parallelism (TP / PP / DP) · KV cache · quantization
 L0  substrate            pools (EKS today; GKE, H100 burst) · GPU operator · capacity
 ── self-management       operator agent watches L0–L2, acts only via PRs (Phase 4)
```

**Built so far: L0 + L1** — one model per cluster, proven on mock → 1×L4 → 4×L4 (PP=4)
with the same endpoint and contract. L2 and the operator agent are the path below.

## Two things, kept separate

This repo is *built by* an agent-native development platform; it is not that platform.

| | Agent-native dev platform | gpu-inference (this repo) |
|---|---|---|
| What | **how** we ship infra and code: agents do the work with almost no hand-holding; validations and tests (not necessarily PRs) drive each change; a guardrails framework decides what may land | **what** we build: a GPU inference service |
| Today | one agent — Sentinel, a PR reviewer — on GitHub Actions + hosted LLM APIs | ephemeral EKS (GKE later) |
| Direction | more agents (planner, implementer, operator); triggers beyond PRs (agent commits, pre-receive, merge queue); human oversight through channels (e.g. Slack) only when needed; cheaper models (OpenRouter) | the path in this doc |
| Lives in | `krmayankk/sentinel` today; the wider fleet gets its own home (sentinel PLAN.md) | here |
| Relationship | builds many projects — gpu-inference, revbench, and more to come | one of those projects |

Here, Sentinel appears only as this repo's PR gate and its rules (`CLAUDE.md`,
`.sentinel/skills/`). **Someday, explicitly not planned:** this service grows an agent
runtime (agents, swarms, IDE inference) on top of L2, and perhaps serves the dev
platform's own tokens. Out of scope until L2 exists.

## Where we are against the plan

| Phase | Plan | Status |
|---|---|---|
| 0 | scaffolding, `make up/down`, Sentinel gate, zero-orphan proof | **built** |
| 1 | 1 GPU, FP8, observability | **built** — 7B on 1×L4, 28.8 tok/s |
| 2 | distributed inference | **PP across nodes built** (27B on 4×L4, 8.1 tok/s). **TP within a node: not yet** (quota now allows it) |
| 3 | GitOps + chat UI + agentic layer | not started |
| 4 | autoscaling + cost-autonomy operator agent | not started |
| 5 | multi-cloud H100 burst | not started |
| 6 | CRD-driven fleet + self-management | not started |

## What "at scale" adds — seven gaps, mapped to the ladder

| # | Gap | Today | At scale | Lands in |
|---|---|---|---|---|
| 1 | **Replicas + autoscaling** | one model copy | N replicas scaled on queue depth / KV-cache use; GPU nodes 0→N→0 (KEDA + Karpenter); fast cold start | Phase 4 |
| 2 | **Smart routing** | Service picks pods round-robin; no prefix cache | KV/prefix-aware routing (llm-d / Gateway API Inference Extension); prefix caching on | Phase 2→3 |
| 3 | **Right parallelism per hardware** | PP over the network | TP inside a node; PP only when forced; prefill/decode split at large scale | Phase 2 (TP), 5 |
| 4 | **Reliability** | one head = single point of failure | ≥2 replicas across zones; zero-downtime upgrades; model canaries | Phase 3–4 |
| 5 | **Getting GPUs** | one region, one type; capacity outages hit (incident #1) | all zones (PR #7), multi-provider (GKE), reservations / Capacity Blocks | Phase 5 |
| 6 | **Front door** | `kubectl port-forward` | ingress + TLS, API keys, per-tenant rate limits and token budgets, metering | Phase 3 |
| 7 | **Operations** | dashboards only | SLOs on TTFT / inter-token latency, alerts, long-term metrics, **cost per 1M tokens** | Phase 3–4 |

## Next PRs, in order

Each is small, reviewed on its own, and ships a README in the style of
`platform/serving/gpus/l4x4/README.md` (flow first, details last).

| # | PR | Why now | Quota / cost |
|---|---|---|---|
| 1 | **Sentinel rules from the l4x4 run** (CLAUDE.md, skills, lint) | lessons are fresh; cheap | $0 |
| 2 | **Prefix caching + speculative decoding knobs** on l4x4 / l4 | biggest latency win for agent prompts (TTFT up to 7.5s) | $0 to write; live check rides the next run |
| 3 | **One g6.12xlarge (4×L4), three layouts: TP=4, PP=4, TP=2×PP=2** | same 4 GPUs as today, no network: separates the cost of *the network* from the cost of *the parallelism type* | fits (48 of 64 vCPU) |
| 4 | **PP, faster: concurrency benchmark + cluster placement group** on l4x4 | learn where PP time goes; measure hop cost | fits (32 of 64) |
| 5 | **`l40s` (1×L40S) and `l40sx4` (PP=4 over 4×L40S)** | one fast GPU vs PP on fast GPUs — shows hop cost dominating | fits (4 / 16 vCPU) |
| 6 | **Replicas + KV-aware routing** (2+ copies behind llm-d / GIE) | first real L2 piece | fits |
| 7 | **Ingress + API keys** | retire port-forward; first front-door piece | $0 GPU |
| 8 | **GKE pool** (`infra/pools/gke`) | second provider; compare GPU ergonomics | new billed project + GPU quota |

Dev-platform work (Sentinel on OpenRouter, work intake) is tracked in the sentinel repo,
not this queue.

---

# Part 2 — the details

## Speed: why more PP nodes won't help, and what will

Decode (generating each token) is **memory-bandwidth-bound**: each token reads every
weight once. So, roughly, **tok/s ≈ bandwidth ÷ bytes read per token**.

- **4×L4, PP=4 (today):** stages run *one after another*; each reads 7.7GB at 300GB/s ≈
  26ms → ~100ms/token → **ceiling ~10 tok/s**. Measured **8.1** (network hops are the
  rest). The model explains the measurement.
- **PP=8 on 8 nodes:** same total bytes, still sequential, more hops → *not faster*.
  PP adds throughput when many requests are in flight, not single-request speed.
- **TP=4 inside one node:** every GPU reads its quarter of *every* layer **at the same
  time** → bandwidths add (4×300GB/s). Needs a fast GPU-to-GPU link, hence one machine
  (g6.12xlarge, PCIe). Expect a large gain, minus all-reduce cost over PCIe — measuring
  that cost is the point of PR 3.
- **One bigger GPU:** L40S (48GB, ~864GB/s) holds the whole 30.9GB model → ceiling
  ~28 tok/s with zero network (PR 5).
- **Without new hardware:** prefix caching (skip recomputing a shared prompt prefix —
  agent prompts repeat heavily) and speculative decoding (a small draft model proposes
  tokens, the big one verifies several per step) (PR 2).

## Making PP faster on 4 nodes (and learning PP properly)

Where a token's time goes today (estimates from the run): 1 token ≈ 123ms at 8.1 tok/s;
reading weights ≈ 4 × 26ms = 104ms; the remaining **~20ms is the pipeline's hand-offs**
— roughly 5ms per hop, mostly software overhead (serialize, send, wake the next stage),
not network bandwidth: a hop carries one token's activations, kilobytes, not gigabytes.

| Lever | What it changes | Expected |
|---|---|---|
| **Concurrency** (fill the pipeline) | with N requests in flight, all 4 stages work at once on different requests | aggregate tok/s up to ~4× a single request; per-request speed roughly flat. The run already showed 7.4 tok/s each with 2–3 in flight, all 4 GPUs at 100% |
| **Cluster placement group** | nodes on the same rack → lower hop latency | shaves part of the ~20ms; worth measuring |
| **Faster GPUs per stage** (4×L40S) | each stage reads 7.7GB at ~864GB/s ≈ 9ms | ceiling ~28 tok/s, **but** the ~20ms of hops becomes half the token time — PP's fixed cost dominates as GPUs get faster |
| **Speculative decoding** | one pass through the pipeline yields several accepted tokens | amortizes the hops; check vLLM v0.24 supports it with PP > 1 |
| **Fewer bytes** (INT4) | ~half the weight bytes per token | ~2× ceiling, some quality cost — and 27B INT4 (~15GB) fits one L4, removing the reason for PP |
| **TP inside, PP across** (hybrid) | the frontier multi-node pattern: TP over NVLink in each node, PP between nodes | needs 2+ multi-GPU nodes (≥96 vCPU) → Phase 5 |

The lesson to be able to explain: **PP buys capacity (a model bigger than one GPU) and
throughput under load; it costs per-token latency.** Use it when a model doesn't fit
one node, and fill the pipeline.

## Quota and budget reality

Checked 2026-10-04, us-east-1: G/VT on-demand quota **64 vCPUs** (L-DB2E81BA, raised
from 32); G/VT spot 8 (request for 32 open); P-family (A100/H100) **0**. AWS credits
remaining: **$80.29**. Every type below is offered in at least 4 us-east-1 zones.

| Capability | Needs | Fits 64 vCPU G? |
|---|---|---|
| Replicas, autoscaling, KV-aware routing | 2–4 small GPU nodes (7B on L4, or 27B on L40S) | **yes** |
| Prefix caching, speculative decoding | config only | **yes** |
| 27B on one L40S | g6e.xlarge / 2xlarge (4 / 8 vCPU) | **yes** |
| TP=4 in one node | g6.12xlarge (4×L4) or g6e.12xlarge (4×L40S), 48 vCPU each | **yes** — one at a time |
| Prefill/decode disaggregation (meaningful) | fast KV transfer (NVLink / EFA) | no → Phase 5 |
| 8×H100 NVLink (TP=8) | P quota + Capacity Block | no → Phase 5 |
| Ingress, auth, SLOs, GitOps, operator agent | no GPU | **yes** |

**GKE:** the `magic-487821` project has billing disabled; a GKE pool needs a dedicated
project with billing, the Compute + GKE APIs, and a GPU quota request (new projects
usually start at 0 GPUs; free-trial accounts can't use GPUs at all). Worth it for: L4
on `g2` machines, H100 via `a3` with DWS flex-start (on-demand burst without a
reservation), and comparing how GKE handles GPU nodes versus EKS.

## The seven gaps, one level down

1. **Replicas + autoscaling.** Scale on what limits LLM serving — waiting requests and
   KV-cache occupancy (vLLM exports both; we scrape them since #8) — not CPU. Two layers:
   KEDA/HPA for replicas, Karpenter for GPU nodes (scale to zero is the cost guarantee).
   The hard part is **cold start**: 10GB image + 30.9GB weights. Fixes: a pre-built
   image with Ray baked in, local NVMe, model streaming.
2. **Smart routing.** Round-robin wastes the KV cache: the replica that just processed a
   conversation already holds its prefix. llm-d / the Gateway API Inference Extension
   route by prefix and by load; NVIDIA Dynamo does the same plus prefill/decode split.
   The seam holds — this is a `platform/` tenant in front of the same `inference`
   Service (phases.md, Phase 2).
3. **Parallelism.** TP within NVLink/PCIe islands, PP across them, DP (replicas) for
   throughput. At frontier scale, prefill (compute-bound) and decode (bandwidth-bound)
   run on separate GPU pools and hand off the KV cache.
4. **Reliability.** Today any one of 4 stages failing takes the model down. Replicas in
   different zones, a PodDisruptionBudget, rolling upgrades that drain in-flight
   streams, and canarying a new model version on a slice of traffic.
5. **Getting GPUs.** Capacity, not quota, failed us first (incident #1). Span every
   zone that offers the type (PR #7), keep a second provider ready (GKE, Nebius), and
   buy short reservations (Capacity Blocks) for big runs.
6. **Front door.** Ingress with TLS, API keys, per-tenant rate limits and token
   budgets, usage metering — what makes it a *service* and not a cluster.
7. **Operations.** SLOs on TTFT and inter-token latency (p99), alerts on them,
   remote-write metrics so history survives teardown (e.g. Amazon Managed Prometheus),
   and **cost per 1M tokens** as the headline number for every profile.

## Sentinel rules and the operator agent

**Learnings from the l4x4 run → Sentinel rules** (PR 1). Mechanical rules become
deterministic lint (Sentinel's own demotion principle); judgment stays in skills.
These are rules *for this repo*; the reviewer itself belongs to the dev platform.

| Learning (incident) | Rule | Where |
|---|---|---|
| Profile without a namespace landed in `default` (#2) | every profile renders into `inference` | lint — **done in #8** |
| Parallelism rule only covers TP | TP × PP = total `nvidia.com/gpu` across the profile's pods = `node_count` × GPUs per node | CLAUDE.md + `serving_contract` |
| KubeRay injected init/probes that exec `ray` / `wget`, absent from the image (#4, #7) | operator-managed workloads declare their own probes; never rely on injected containers that exec tools the image lacks | `serving_contract` skill |
| Versions that must move together | `rayVersion` = installed Ray pin; vLLM dashboard tag = vLLM image tag | lint |
| GPU capacity outage in the VPC's zones (#1) | GPU node groups span every zone offering the type | CLAUDE.md (with PR #7) |
| vLLM metrics weren't scraped (#12) | every serving Service keeps `app: inference` + port `http` (the ServiceMonitor's contract) | lint |
| Live runs must leave proof | a `docs/runs/` PR carries `make evidence` output + teardown proof | `cost_teardown_proof` skill |
| Contract passed against the wrong backend (Phase 1) | contract pins backend identity | contract test (backlog) |

**Operator agent** (Phase 4): first job is orphan / cost-drift detection → cleanup PRs;
then capacity (a node group stuck on capacity → PR adding zones or a fallback type);
then SLO breaches → PR with the scaling change. Every action is a PR — GitOps stays the
only mutation path.

## How to tell this story (interview)

- **30 seconds:** "I built an ephemeral GPU inference platform where the hardware is
  the only variable: the same endpoint and contract from a $0 mock to 4 GPUs on 4
  machines serving a model too big for any one of them. It's built with an agentic
  workflow — an AI reviewer gates every PR — every run leaves evidence, and teardown
  proves zero cost left behind."
- **The number that shows understanding:** 8.1 tok/s measured vs ~10 predicted from
  bandwidth (7.7GB per stage at 300GB/s, 4 stages in sequence) — and why TP or a bigger
  GPU, not more nodes, is the fix — and where the other ~20ms goes (pipeline hops).
- **The war stories:** capacity not quota (#1); operator defaults that assume tools
  your image lacks (#4, #7); metrics nobody scraped (#12). Each: symptom → cause → fix →
  a rule so it can't recur.
- **What at scale adds:** the seven gaps above, in order of what you'd build first.
