# Tutorial: one model, four GPUs, four machines — the first live l4x4 run

*Run date: 2026-09-26, us-east-1. Qwen3.8-27B-FP8 served by vLLM v0.24.0 with
pipeline parallelism (PP=4) on a KubeRay cluster over 4× g6.2xlarge (1× NVIDIA L4
each). Every output below is raw, from this run.*

Phase 1 served a 7B model on one GPU. This run serves a 27B model that **cannot fit
any single L4** (30.9GB of fp8 weights vs 24GB of VRAM), so it is split across four
machines. What follows is what it took, what broke, and how to look inside.

- Layer map (how to run this level): `docs/phases.md` · procedure: `docs/runbooks/l4x4-live-test.md`
- Profile: `platform/serving/gpus/l4x4/` · decision record: ADR-0011 in `docs/decisions.md`

---

## 1. What gets built

```sh
AWS_PROFILE=mfa make up POOL=aws GPU=l4x4 CONFIRM_SPEND=1
```

Terraform (67 resources): VPC + NAT + S3 gateway endpoint, EKS 1.34, a system node
group (2× t3.medium) and a GPU node group (4× g6.2xlarge, tainted `nvidia.com/gpu`).
Then Helm: kube-prometheus-stack, the NVIDIA GPU Operator, the KubeRay operator. Then
the app: a `RayCluster` (1 head + 3 workers, 1 GPU each) and the chat UI.

## 2. Lesson one: GPU capacity, not quota, is the constraint

Quota was fine (32 vCPUs = 4 × 8). The GPU node group still sat for ~10 minutes:

```
Failed  Launching a new EC2 instance. Status Reason: Could not launch On-Demand Instances.
InsufficientInstanceCapacity - We currently do not have sufficient g6.2xlarge capacity in the
Availability Zone you requested (us-east-1a). ... You can currently get g6.2xlarge capacity by
not specifying an Availability Zone in your request or choosing us-east-1b, us-east-1c, ...
```

The VPC spanned only two zones, so the Auto Scaling Group could only retry. Capacity
reappeared in 1b and all four nodes landed there (good luck for PP: no cross-zone hops).
Fix for next time: the GPU node group spans every zone that *offers* the instance type
(PR #7). The production answer is Karpenter (any allowed type, any zone, gang in one zone)
or reserved capacity (EC2 Capacity Blocks).

## 3. What is installed, and where

```
$ kubectl get namespaces
NAME              STATUS   AGE
default           Active   30m      # built-in
gpu-operator      Active   11m      # ours (NVIDIA's docs use the same name)
inference         Active   10m      # ours: vLLM on Ray + chat UI
kube-node-lease   Active   30m      # built-in: node heartbeats
kube-public       Active   30m      # built-in
kube-system       Active   30m      # built-in: DNS, CNI, kube-proxy
kuberay           Active   10m      # ours: KubeRay operator
observability     Active   12m      # ours: Prometheus + Grafana
```

None of our four names are chart defaults — every Helm install passes `--namespace`
explicitly (`scripts/up.sh`). Section 5 shows why that discipline matters.

| Node | Role | Runs |
|---|---|---|
| 2× t3.medium | system | CoreDNS, Grafana, Prometheus, GPU-operator controller, KubeRay operator, chat |
| 4× g6.2xlarge | GPU | one `inference` Ray pod each, plus per-node NVIDIA DaemonSets: device plugin, GPU feature discovery, DCGM exporter, validators |

Pod-name patterns tell you the controller: `name-<hash>-<5>` = Deployment,
`name-<5>` per node = DaemonSet, `name-0` = StatefulSet, `<cluster>-head-*` /
`<cluster>-<group>-worker-*` = KubeRay.

## 4. How a pod asks for a GPU (and why this is not DRA)

```
== what the POD asks for (inference-gpu-workers-worker-47kjc)
resources.limits : {'nvidia.com/gpu': '1'}
nodeSelector     : {'nvidia.com/gpu.present': 'true'}
tolerations      : [{'effect': 'NoSchedule', 'key': 'nvidia.com/gpu', 'operator': 'Exists'}]
resourceClaims   : <none — not using DRA>

== what the NODE offers (ip-10-0-2-10)
capacity nvidia.com/gpu: 1
taints: [('nvidia.com/gpu', 'NoSchedule')]
  nvidia.com/gpu.product = NVIDIA-L4
  nvidia.com/gpu.memory = 23034
  nvidia.com/gpu.compute.major = 8      # Ada (8.9) — why hardware FP8 works; T4 is 7.5
  nvidia.com/gpu.compute.minor = 9
  nvidia.com/cuda.driver.major = 580

== DRA objects in the cluster (API is GA in 1.34):
No resources found
```

- **Taint** keeps ordinary pods off GPU nodes; **toleration** lets this pod on;
  **nodeSelector** makes it go there; **`limits: nvidia.com/gpu: 1`** is the request.
- The device plugin makes the GPU an **integer** — "1 of these". *Which* GPU (model,
  memory) lives only in node labels written by GPU Feature Discovery.
- **DRA** (a later layer) replaces the integer with a `ResourceClaim` — "a device of
  class `gpu.nvidia.com` where `productName == "NVIDIA L4"` and memory ≥ 20Gi" —
  matched against `ResourceSlices` the NVIDIA DRA driver publishes. The API exists on
  this 1.34 cluster; nothing uses it yet.

Inside the container, exactly one GPU is visible, idle before the model loads:

```
name, memory.used [MiB], memory.total [MiB], utilization.gpu [%], power.draw [W], temperature.gpu
NVIDIA L4, 3 MiB, 23034 MiB, 0 %, 16.89 W, 31
GPUs this container can see: 1
```

## 5. Bug found live: no namespace → everything in `default`

The single-GPU profiles inherit `namespace: inference` from `overlays/vllm`. The l4x4
profile is a RayCluster, not that Deployment, so it had **no namespace** and landed in
the kubectl context's (`default`). Symptoms:

```
chat  CrashLoopBackOff
nginx: [emerg] host not found in upstream "inference" in /etc/nginx/conf.d/default.conf:12
```

Chat (in `inference`) could not resolve the `inference` Service (in `default`). Fix:
`namespace: inference` in the l4x4 kustomization, plus a **lint rule** — every rendered
profile must put every object in `inference`. The rule was verified to fail on the old
file (`Service/inference RayCluster/inference`) and pass on the fix. Every gate had
passed the bug: lint only proved the manifests *render*, CI's e2e only deploys the mock,
and review missed it. Deterministic rules belong in lint, not in AI review.

Moving the objects exposed a second-order effect: the new pods sat **Pending**
(`4 Insufficient nvidia.com/gpu`) because the old pods still held all four GPUs while
terminating mid image pull. Nothing starts until *every* GPU is free — the gang
problem, visible.

## 6. Bug found live: "ray: command not found", forever

`vllm/vllm-openai:v0.24.0` does **not** ship Ray (an optional vLLM dependency). The
manifest installs a pinned Ray in the main container (verified in the image before
launch). But KubeRay also **injects** an init container into workers that waits for
the head using `ray health-check` — in the worker's own image:

```
$ kubectl -n inference logs <worker> -c wait-gcs-ready
/bin/bash: line 11: ray: command not found
800 seconds elapsed: Still waiting for GCS to be ready.
```

Its loop has no failure exit, so it waited forever. Fix: the operator runs with
`ENABLE_INIT_CONTAINER_INJECTION=false` (the documented switch), and the workers do
the same wait themselves after installing Ray. Three bugs in one day traced to one
fact about one image — the durable fix is a derived image with Ray baked in (backlog).

## 7. The gang, seen from inside Ray

Before the workers joined, the head's `ray status`:

```
Active:
 1 node_cb2698ab…
Total Demands:
 {'GPU': 1.0} * 4 (PACK): 1+ pending placement groups
```

vLLM had asked Ray for a **placement group**: four 1-GPU bundles, all or nothing. After
the fix:

```
Active:
 1 node_ad7d34dd…
 1 node_09c403d2…
 1 node_cb2698ab…
 1 node_c4f85086…
Resources
 4.0/4.0 GPU (4.0 used of 4.0 reserved in placement groups)
Total Demands:
 (no resource demands)
```

That is **application-level gang scheduling**. Kubernetes itself does not know these four
pods belong together — with three GPUs it would happily run three pods that wait
forever. Kueue (or the Workload API, beta in Kubernetes 1.37) moves that rule into
Kubernetes. That is the next layer.

## 8. vLLM vs Ray vs Kubernetes — who runs where

Processes per pod, raw (`ps` filtered to vLLM/Ray):

```
=== inference-head-cbd9q  [head]  node=ip-10-0-2-247
      1 /usr/bin/python3 /usr/local/bin/vllm serve Qwen/Qwen3.8-27B-FP8 --served-model-name=gpu-inference ...
     96 .../ray/gcs/gcs_server ...
    544 .../ray/raylet/raylet ...
    776 VLLM::EngineCore
    829-836 ray::IDLE (x8)
   1399 ray::RayWorkerProc.initialize_worker
=== inference-gpu-workers-worker-45t6w  [worker]  node=ip-10-0-2-10
    142 .../ray/raylet/raylet ...
    274 ray::RayWorkerProc.initialize_worker
(two more workers: same shape)
```

```
                        chat UI / IDE / curl
                               │  HTTP :8000
                               ▼
                 Service "inference" → head pod only
                               │
┌──── HEAD POD (GPU #1) ─────────────────────────────────────────────────────┐
│  vLLM   vllm serve (PID 1)    API server: HTTP, tokenizer, chat template    │
│  vLLM   VLLM::EngineCore      scheduling, batching, KV cache                │
│  vLLM   RayWorkerProc         one pipeline stage on this pod's GPU          │
│  Ray    gcs_server :6379      Ray's control plane — head only               │
│  Ray    raylet                Ray's per-node agent                          │
└───────────────┬────────────────────────────────────────────────────────────┘
                │ ① Ray: raylets register with GCS; the engine asks for
                │    "4 GPUs, all or none"; raylets start RayWorkerProc
                │ ② vLLM: activations flow stage → stage, every token
   ┌────────────┼──────────────────────┬──────────────────────┐
   ▼            ▼                      ▼                      ▼
 WORKER (GPU #2)            WORKER (GPU #3)           WORKER (GPU #4)
 raylet + RayWorkerProc     raylet + RayWorkerProc    raylet + RayWorkerProc
 (one stage each)
```

| | Kubernetes | Ray | vLLM |
|---|---|---|---|
| Owns | pods, nodes, GPUs as an integer | processes across pods, placement groups | the model: layers, KV cache, batching |
| Sees GPUs as | "this pod gets 1" | "reserve 4 together" | "this stage = these 16 layers" |

- **GCS** (Global Control Service): Ray's control plane, the analogue of the Kubernetes
  API server + etcd. Head only. Tracks live nodes, where every Ray process runs, and
  placement groups.
- **Stage**: the model's 64 layers cut into 4 consecutive blocks of 16, one per GPU.
  A token passes through all four in order; each GPU holds a quarter of the weights
  (~7.7GB), which is why a 31GB model fits 24GB cards.
- **RayWorkerProc**: a vLLM process that Ray launched and tracks — hence both names.
  After start-up, vLLM stages talk to each other directly; Ray keeps them alive.

## 9. Results

*To be filled from this run: model load time, contract test, decode tok/s, GPU memory
per stage (DCGM), Grafana screenshots, `make down` zero-orphan proof.*

## Try it yourself

```sh
eval "$(make env)"                                               # kubeconfig for this cluster
kubectl get pods -A -o wide                                      # everything, everywhere
kubectl -n inference get pods -L ray.io/node-type,ray.io/group   # head vs workers
kubectl -n inference exec <head-pod> -c ray-head -- ray status   # the gang, from Ray
kubectl -n inference exec <head-pod> -c ray-head -- nvidia-smi   # one GPU per pod
kubectl get clusterpolicy                                        # GPU operator health
```
