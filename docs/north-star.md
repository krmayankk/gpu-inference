# North star — an AI-native GPU platform

**Where this repo is going, what "at scale" means, and the path from here.** PLAN.md
states the thesis (an ephemeral, portable GPU platform that manages itself through AI
agents); `docs/phases.md` is the build ladder. This page reconciles both with what the
live runs taught us, and turns it into the next PRs. Part 1 is the picture; Part 2 the
details.

---

# Part 1 — the picture

## In one paragraph

Model a small **frontier-lab inference service**: open-weight models served on GPUs
from any cloud, behind one OpenAI-compatible front door, scaled and routed by load. On
top of it, an **agent runtime** whose workloads are themselves agents — up to a
*software factory* that turns specs into merged PRs. And around all of it, **agents
that operate the platform**: Sentinel reviews every change, an operator agent fixes
drift, cost and incidents by opening PRs. The loop closes when the agents that build
and run the platform think with tokens the platform itself serves.

## The layers

```
 ┌─ AI-native operations (around everything) ───────────────────────────────┐
 │  Sentinel: reviews every PR (built)   operator agent: drift/cost/incidents │
 │  → PRs (Phase 4)   the agents' own tokens served by this platform (loop)  │
 └───────────────────────────────────────────────────────────────────────────┘
 L4  agent workloads      software factory: spec → code → PR → gate → deploy
 L3  agent runtime        sandboxes, tool gateway (MCP), durable runs, budgets
 L2  inference service    front door (auth, limits, metering) · KV-aware routing
                          · replicas + autoscaling · multi-model · canaries
 L1  serving              vLLM · parallelism (TP / PP / DP) · KV cache · quantization
 L0  substrate            pools (EKS today; GKE, H100 burst) · GPU operator · capacity
```

**Built so far: L0 + L1** — one model per cluster, proven on mock → 1×L4 → 4×L4 (PP=4)
with the same endpoint and contract. Everything above L1 is the path below.

## Where we are against the plan

| Phase | Plan | Status |
|---|---|---|
| 0 | scaffolding, `make up/down`, Sentinel gate, zero-orphan proof | **built** |
| 1 | 1 GPU, FP8, observability | **built** — 7B on 1×L4, 28.8 tok/s |
| 2 | distributed inference | **PP across nodes built** (27B on 4×L4, 8.1 tok/s). **TP within a node: not yet** (needs quota) |
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
| 3 | **`l40s` profile: 27B on one g6e (L40S 48GB)** | same model, no network hops: tests the bandwidth math (Part 2) | fits current quota |
| 4 | **`l4x4tp`: TP=4 inside one g6.12xlarge** | the TP-vs-PP comparison Phase 2 promised | **needs quota 32→48 vCPU** |
| 5 | **Replicas + KV-aware routing** (2+ copies behind llm-d / GIE) | first real L2 piece | fits current quota |
| 6 | **Ingress + API keys** | retire port-forward; first front-door piece | $0 GPU |
| 7 | **GKE pool** (`infra/pools/gke`) | second provider; compare GPU ergonomics | new project + GPU quota |
| 8 | **Sentinel on OpenRouter / self-hosted** (sentinel repo) | cheaper reviews; dogfood our own endpoint | OpenRouter pay-per-token |

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
  that cost is the point of PR 4.
- **One bigger GPU:** L40S (48GB, ~864GB/s) holds the whole 30.9GB model → ceiling
  ~28 tok/s with zero network (PR 3).
- **Without new hardware:** prefix caching (skip recomputing a shared prompt prefix —
  agent prompts repeat heavily) and speculative decoding (a small draft model proposes
  tokens, the big one verifies several per step) (PR 2).

## Quota and budget reality

AWS G/VT on-demand quota in us-east-1: **32 vCPUs** (L-DB2E81BA). P-family (A100/H100)
is a separate quota, never requested. AWS credits remaining: ~$90 after the l4x4 run
(estimate — verify before spending).

| Capability | Needs | Fits 32 vCPU G? |
|---|---|---|
| Replicas, autoscaling, KV-aware routing | 2–4 small GPU nodes (7B on L4, or 27B on L40S) | **yes** |
| Prefix caching, speculative decoding | config only | **yes** |
| 27B on one L40S | g6e.xlarge / 2xlarge (4 / 8 vCPU) | **yes** |
| TP=4 in one node | g6.12xlarge or g6e.12xlarge (48 vCPU) | **no** → request 48 |
| Prefill/decode disaggregation (meaningful) | fast KV transfer (NVLink / EFA) | no → Phase 5 |
| 8×H100 NVLink (TP=8) | P quota + Capacity Block | no → Phase 5 |
| Ingress, auth, SLOs, GitOps, agents | no GPU | **yes** |

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

## From inference service to agent platform (L3–L4)

- **Agent runtime (L3):** isolated sandboxes for agent tool execution (gVisor / Kata /
  Firecracker), a tool gateway (MCP), durable long-running runs, per-agent token and
  dollar budgets, traces per agent.
- **Agent workloads (L4):** the software factory — agents take a spec, write code, open
  PRs, Sentinel gates them, GitOps deploys. This repo is already built that way by
  hand; the factory automates the same loop.
- **Closing the loop:** the agents that review and operate this platform run on tokens
  this platform serves.

## AI-native operations: Sentinel and the operator agent

**Learnings from the l4x4 run → Sentinel rules** (PR 1). Mechanical rules become
deterministic lint (Sentinel's own demotion principle); judgment stays in skills.

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

**Sentinel's model provider.** Today Sentinel calls the Anthropic API (and its CI check
currently fails on API credit, not findings). Sentinel's own plan already has a
pluggable provider layer (`LLMProvider`, its v0.6). OpenRouter speaks the OpenAI API, so
one OpenAI-compatible adapter with a configurable base URL covers OpenRouter (cheap
open-weight models in CI) *and* our own vLLM endpoint (the platform reviewing its own
PRs during a live run). Sentinel's bake-off (`docs/bake-off.md` there) then measures
open vs frontier models on the same skills.

**Operator agent** (Phase 4): first job is orphan / cost-drift detection → cleanup PRs;
then capacity (a node group stuck on capacity → PR adding zones or a fallback type);
then SLO breaches → PR with the scaling change. Every action is a PR — GitOps stays the
only mutation path.

## How to tell this story (interview)

- **30 seconds:** "I built an ephemeral GPU inference platform where the hardware is
  the only variable: the same endpoint and contract from a $0 mock to 4 GPUs on 4
  machines serving a model too big for any one of them. Every change is gated by an AI
  reviewer, every run leaves evidence, and teardown proves zero cost left behind."
- **The number that shows understanding:** 8.1 tok/s measured vs ~10 predicted from
  bandwidth (7.7GB per stage at 300GB/s, 4 stages in sequence) — and why TP or a bigger
  GPU, not more nodes, is the fix.
- **The war stories:** capacity not quota (#1); operator defaults that assume tools
  your image lacks (#4, #7); metrics nobody scraped (#12). Each: symptom → cause → fix →
  a rule so it can't recur.
- **What at scale adds:** the seven gaps above, in order of what you'd build first.
