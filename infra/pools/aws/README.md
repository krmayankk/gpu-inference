# pool: aws

The cloud substrate: **EKS with a system node group + one GPU node group.**
Pool = provider; hardware = profile. `GPU=t4|l4` selects a row in `local.gpu_profiles`
(`g4dn.2xlarge` / `g6.2xlarge`) — T4 and L4 are *not* separate pools, and adding H100-class
hardware later is a new row + a new `platform/serving/gpus/<profile>/`, not new infrastructure code.

## What it builds
- VPC (2 AZ, single NAT) + **S3 gateway endpoint** — weight pulls from the cache bucket bypass NAT ($0.045/GB → free)
- EKS (`kubernetes_version` pinned inside standard support — extended support bills ~6×)
- `system` node group (t3.medium ×2, untainted) — CoreDNS, GPU-operator controllers, chat, Prometheus
- `gpu` node group (`AL2023_x86_64_NVIDIA` AMI: driver+toolkit baked in; tainted `nvidia.com/gpu=present:NoSchedule`)
- Node-role RW policy on the **weights cache bucket** (created by `infra/bootstrap`; deliberate Phase-1 trade-off — IRSA is the Phase-3 hardening)
- **TTL dead-man's switch**: an ASG schedule zeroes the GPU node group `ttl_hours` (default 6) after the last apply — a forgotten cluster stops burning GPU money by itself

## Credentials: the MFA-gated session pattern

The account's IAM policy **explicitly denies all mutating access without MFA**
(`aws:MultiFactorAuthPresent`). Deliberate and good: leaked long-term access
keys are inert on their own. The CLI user therefore cannot run Terraform
directly — mint a short-lived MFA session first:

```bash
aws iam list-mfa-devices                      # find your serial (allowed sans MFA)
aws sts get-session-token \
  --serial-number arn:aws:iam::<ACCOUNT_ID>:mfa/<device> \
  --token-code <6-digit-code> \
  --duration-seconds 43200                    # 12h: covers build+demo+teardown
```

Store the returned credentials as a **separate `[mfa]` profile** in
`~/.aws/credentials` — never overwrite the long-term keys — then run everything
through it:

```bash
AWS_PROFILE=mfa make bootstrap
AWS_PROFILE=mfa make up POOL=aws GPU=l4 CONFIRM_SPEND=1
AWS_PROFILE=mfa make down POOL=aws
```

If the session expires mid-work, mint a new one — Terraform state is remote, so
nothing is lost. This layers with the platform's own guards (`CONFIRM_SPEND=1`,
the TTL dead-man's switch): stolen keys can't create infrastructure, and
forgotten infrastructure can't keep billing.

## Lifecycle
```bash
make bootstrap                                  # once: state backend + weights bucket
make up   POOL=aws GPU=l4 CONFIRM_SPEND=1       # ~$1.15/hr all-in (L4)
make down POOL=aws                              # destroy + zero-orphan proof
```
`CONFIRM_SPEND=1` is mandatory; preflight probes that the AWS identity can actually
create infrastructure before Terraform burns 20 minutes finding out.

## Cost anatomy (us-east-1, on-demand)
| Item | $/hr |
|---|---|
| g6.2xlarge (L4 24GB) | ~0.98 |
| EKS control plane | 0.10 |
| NAT gateway | ~0.05 |
| t3.medium ×2 (system) | ~0.08 |
| **Total while up** | **~1.2** |

Torn down: $0/hr. Persistent (sanctioned, `Ephemeral=false`): state backend + weights bucket — pennies/month.
