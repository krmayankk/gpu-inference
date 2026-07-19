# Runbook: l4x4 live test — 4 GPUs, one model (Phase 2's first spin-up)

What Phase 1 proved on one GPU, this run proves on four: Qwen3-32B-FP8 split
into 4 pipeline stages across 4 nodes, behind the same `inference` Service,
same chat UI, same contract test. Cost ≈ $4/hr (4× g6.2xlarge + EKS + NAT);
the TTL dead-man's switch arms at 6h. Cold boot 25–40 min the first time
(~33GB of weights per node from HF); after `make cache-weights`, subsequent
boots prefetch from S3 through the gateway endpoint (NAT-free, ~15 min).

## 0. Pre-flight
```sh
# fresh MFA session (infra/pools/aws/README.md), then:
aws service-quotas get-service-quota --service-code ec2 \
  --quota-code L-DB2E81BA --region us-east-1   # expect Value: 32
```

## 1. Up
```sh
make up POOL=aws GPU=l4x4 CONFIRM_SPEND=1
```
The assembly, in the order you'll see it (each is a checkpoint if it stalls):
1. terraform: VPC → EKS → **4-node** GPU group (`desired=4` from the profile)
2. helm: GPU operator (device plugin/GFD/DCGM), **KubeRay operator**, obs stack
3. RayCluster `inference`: head + 3 workers schedule onto the 4 tainted nodes
4. per-pod initContainers prefetch the HF cache from S3 (no-op on first boot)
5. head logs: Ray head up → workers join → vLLM places PP stages 0–3 → serve
6. head pod Ready == vLLM `/health` green == all 4 stages placed

## 2. Poke the hardware (the fun part)
```sh
export NS=inference   # scripts/lib.sh default namespace

# The cluster, GPU-eyes on: 4 nodes wearing GPUs
kubectl get nodes -L nvidia.com/gpu.present,node.kubernetes.io/instance-type
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.capacity.nvidia\.com/gpu'
kubectl get node -o json | jq -r '.items[].metadata.labels | to_entries[] | select(.key|startswith("nvidia.com")) | "\(.key)=\(.value)"' | sort -u   # GFD's fingerprint of the silicon

# The Ray cluster and its pods
kubectl -n $NS get raycluster,pods -o wide

# nvidia-smi on EVERY GPU in the fleet, one loop (driver is host-mounted
# into GPU containers, so nvidia-smi works inside the vLLM image):
for p in $(kubectl -n $NS get pods -l ray.io/cluster=inference -o name); do
  echo "=== ${p#pod/} ==="
  kubectl -n $NS exec "${p#pod/}" -- nvidia-smi \
    --query-gpu=name,memory.used,memory.total,utilization.gpu,power.draw --format=csv
done
# Expect: ~8GB fp8 weights + KV cache resident on each of the four L4s.
# Send a chat prompt and re-run: utilization ripples head→worker→worker→worker
# as tokens traverse the pipeline stages.

# The GPU device nodes themselves, inside a pod
HEAD=$(kubectl -n $NS get pod -l ray.io/node-type=head -o jsonpath='{.items[0].metadata.name}')
kubectl -n $NS exec "$HEAD" -- ls -l /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm
kubectl -n $NS exec "$HEAD" -- env | grep -E 'CUDA_VISIBLE|NVIDIA_'

# Ray's own view: 4 nodes, 4 GPUs, one logical machine
kubectl -n $NS exec -it "$HEAD" -- ray status
kubectl -n $NS port-forward "$HEAD" 8265:8265 &   # Ray dashboard → http://localhost:8265
#   Cluster tab: 4 nodes; Actors: the 4 vLLM PP-stage workers and their placement

# vLLM's serving metrics (tokens/sec, KV cache, queue — raw Prometheus text)
kubectl -n $NS port-forward svc/inference 8000:8000 &
curl -s localhost:8000/metrics | grep -E 'vllm:(num_requests|gpu_cache_usage|prompt_tokens|generation_tokens)'

# DCGM in Grafana: all four GPUs on one panel
make grafana   # FB_USED, GPU_UTIL, POWER_USAGE per GPU (PLAN §5 metrics)
```

## 3. Prove the seam (Phase 2's actual test)
```sh
make chat                       # same UI — now a 32B reasoning model answers
python3 scripts/contract.py     # the SAME assertions that passed the mock and 1×L4
```
The contract passing unchanged against 4-way-distributed serving IS the
ADR-0002/0009 claim, proven at Phase-2 scale.

## 4. Measure (record in the PR/phase notes)
```sh
# tokens/sec under a fixed prompt, vs the Phase-1 single-GPU numbers
curl -s localhost:8000/metrics | grep -E 'vllm:generation_tokens_total'
# sample before/after a timed run; PP adds inter-stage latency — expect better
# THROUGHPUT capacity than 1×L4-that-couldn't-fit-this-model (it couldn't run
# it at all); the honest comparison is vs TP=4-in-one-box when quota clears.
```

## 5. Persist, then prove zero
```sh
make cache-weights   # push ~33GB to S3 once — next boot is NAT-free
make down            # destroy all 4 nodes + cluster
make verify          # zero-orphan sweep (tags cover ASG-launched capacity)
```

## Likely first-boot failure points (this is the learning, not a bug list)
- Workers can't reach the head GCS → check the KubeRay-generated head svc and
  that all pods landed on GPU nodes (`kubectl -n $NS get pods -o wide`).
- vLLM stalls at "waiting for placement group" → a worker isn't Ready or a GPU
  isn't visible on one node (`nvidia-smi` loop above finds which).
- ImagePull slowness: ~10GB vLLM image × 4 nodes through one NAT — patience
  before diagnosis; `kubectl describe pod` shows pull progress events.
