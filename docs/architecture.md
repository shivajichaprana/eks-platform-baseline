# Architecture

This document captures the design decisions baked into `eks-platform-baseline`,
and — for the contentious ones — the alternatives that were considered and
rejected. If you are debating whether to override one of the defaults, start
here.

## Goals (and explicit non-goals)

**Goals.**

1. A single `terraform apply` (plus `scripts/bootstrap-cluster.sh`) yields a
   cluster that can host application workloads safely.
2. Every add-on is provisioned via IRSA. No add-on relies on node-instance IAM
   for AWS API access.
3. Costs are kept honest. The default node footprint is a small managed node
   group for system pods; everything else lands on Karpenter Spot capacity.
4. Failure modes are predictable. SQS-based interruption handling, PDBs on
   every workload, control-plane logging on by default.

**Non-goals.**

* Multi-tenant isolation beyond namespace-level. If you need hard isolation,
  layer Kyverno / OPA Gatekeeper / network policies on top — they're called
  out where useful but not bundled.
* GitOps. The platform is intentionally Terraform + Helm-from-Terraform. A
  GitOps controller (Argo CD / Flux) is straightforward to add but is not
  this repo's job.
* Service mesh. Same reason. The reference workload uses native Kubernetes
  Services + ALB Ingress.

## Decision log

### 1. Karpenter over Cluster Autoscaler

Karpenter is the node provisioner. Cluster Autoscaler was considered and
rejected.

**Why Karpenter.**

* CA is bound to ASGs. Each ASG is a single instance type (or a small
  manually curated set), so over-provisioning is the norm — you pick a
  flavour that fits the largest pod and pay for it on every node. Karpenter
  picks the cheapest instance that fits the pending pods at scheduling time.
* Karpenter scales from zero in a single API call (RunInstances) — typically
  ~30s to a Ready node — vs. CA's 2–5 minutes through ASG indirection.
* Karpenter consolidates aggressively. An empty node is replaced by a
  smaller one rather than left running until the ASG cooldown expires.
* Spot interruption handling is a first-class feature. The SQS queue +
  EventBridge rules deployed by the `karpenter` module catch interruption
  notices, scheduled changes, and rebalance recommendations and drain the
  affected node ~2 minutes before AWS reclaims it.

**What we lose.** CA is more battle-tested on very large clusters
(>10k nodes) and has more conservative consolidation. The reference
NodePool is tuned for ≤500 nodes; very large fleets should split per-team
NodePools and consider `disruption.consolidationPolicy: WhenUnderutilized`.

### 2. Bottlerocket AMIs (with AL2023 fallback)

The default `EC2NodeClass` requests Bottlerocket. Amazon Linux 2023 is
supported but not the default.

**Why Bottlerocket.**

* Image-based updates rather than `yum`. There is no system package
  manager on a running node, which closes off a large class of "did
  somebody SSH in and change `/etc/sysctl.d`" drift.
* Read-only root filesystem and SELinux-enforcing by default.
* Smaller image (~700 MiB), faster boot.
* First-class kubelet args via the `[settings.kubernetes]` TOML, surfaced
  through `userData` in the EC2NodeClass.

**What we lose.** Bottlerocket's "no shell" model means debugging a node
goes through `aws-ssm-session-manager` + the admin container or
`apiclient`. Operators who haven't worked with Bottlerocket before should
read the [Bottlerocket admin container
docs](https://github.com/bottlerocket-os/bottlerocket/blob/develop/sources/host-containers/admin-container/README.md)
before relying on it in production.

### 3. VPC CNI prefix delegation, on by default

The VPC CNI module sets `ENABLE_PREFIX_DELEGATION=true`.

**Why.** Without prefix delegation, each pod consumes one secondary IP
on the ENI, and ENI capacity is tied to instance type. A `t3.medium`
caps at ~17 pods and a `c6i.large` at ~29. With prefix delegation
enabled, the CNI claims `/28` prefixes (16 IPs each) per ENI, multiplying
pod capacity ~16x and tracking the documented EKS limits much more
faithfully.

**What we lose.** Prefix delegation requires Nitro instance families
(it does not work on `t2`, `m4`, etc.), and it allocates IPs in /28
chunks — bursty short-lived pods can briefly waste up to 15 IPs. The
default subnets (`/19` private subnets per AZ in dev = 8190 IPs) have
plenty of headroom; ensure the same is true for production CIDRs before
turning it on.

### 4. Three subnets per tier, single NAT in dev / per-AZ in prod

Three private + three public subnets across three AZs are the default.
Dev environments share one NAT Gateway across AZs (cost) and production
uses one per AZ (resilience). The toggle is the `single_nat_gw` variable
on the `vpc` module.

**Why.** Two-AZ designs survive a single AZ outage but force EKS pods
into a single AZ in the worst case, which collides with most StatefulSets
and Karpenter spread constraints. Three AZs is the smallest topology that
keeps both AZ-failover and topology-spread happy without overpaying.

### 5. Public + private endpoint with CIDR allow-list

The control-plane endpoint is public *and* private, with the public side
gated by an explicit `endpoint_public_cidrs` allow-list (no default `0.0.0.0/0`).

**Why both.** Pure private requires a bastion or VPN to use `kubectl`
during incidents, which has bitten too many on-call rotations. Pure
public is unsafe even with strong auth: it leaks the cluster's existence
to the internet and exposes the control plane to credential-stuffing
attacks.

**Why the allow-list defaults to nothing.** Forces the operator to make
a deliberate choice. There is no good default — your office, VPN, and
bastion CIDRs are not predictable from inside this module.

### 6. Control-plane logging on for all four security types

The four log types `api`, `audit`, `authenticator`, `controllerManager`
are on by default. `scheduler` is off because its volume is high and
its forensic value is low.

This is the configuration the AWS EKS Best Practices guide and the CIS
Kubernetes Benchmark agree on. The 30-day retention default is short on
purpose — push to a SIEM via subscription filters if you need longer
retention.

### 7. IRSA per controller, never node IAM

Every add-on Helm release is wired to a dedicated IAM role via IRSA. The
worker node IAM role retains only what the kubelet itself needs (ECR
pull, EC2 describe-self, SSM session manager).

This means a compromised pod cannot escalate to "all the IAM that any
controller has". Karpenter can't `route53:ChangeResourceRecordSets`,
ExternalDNS can't `ec2:RunInstances`, and so on.

### 8. Spot-first NodePool with on-demand fallback

The default Karpenter NodePool sets:

```yaml
requirements:
  - key: karpenter.sh/capacity-type
    operator: In
    values: ["spot", "on-demand"]
```

Karpenter prefers Spot when the pricing engine says it's cheaper-with-headroom,
and silently falls back to on-demand when Spot is unavailable for the
selected instance shape. There is no `spot-fallback-grace-period` to tune —
the controller re-evaluates on every scheduling decision.

### 9. ExternalDNS bound to specific zones

The IRSA policy attached to the ExternalDNS role only allows
`route53:ChangeResourceRecordSets` on the hosted zones listed in the
`route53_zone_ids` variable. Leaving this empty creates a role with no
target zones — a fail-safe that surfaces misconfiguration as "ExternalDNS
keeps logging access denied" rather than "ExternalDNS quietly mutates
every zone in the account".

### 10. cert-manager DNS-01 over HTTP-01

DNS-01 was chosen over HTTP-01 because:

* Wildcard certificates require DNS-01.
* HTTP-01 challenges fail when the ALB Ingress is still being provisioned
  (chicken-and-egg).
* DNS-01 doesn't require any inbound traffic.

The IRSA role's policy lists Route 53 actions only on the same hosted
zones ExternalDNS is bound to.

## What is NOT in the baseline (intentionally)

* **A service mesh.** Add Istio or Linkerd if you need mTLS or multi-cluster
  routing. Plain Kubernetes Services + cert-manager + ALB Ingress covers
  90% of single-cluster TLS use cases.
* **A logging pipeline.** Pick FluentBit / Vector / OpenTelemetry per your
  destination. Day-to-day node logs are visible via `kubectl logs` and
  CloudWatch Logs (control plane).
* **A secret store.** External Secrets Operator + AWS Secrets Manager is
  the recommended pattern, but adding it would force a Secrets Manager
  prefix and KMS key into the IRSA policies — an opinion better left to
  application repos.
* **A monitoring stack.** That's a separate project (`aws-observability-stack`,
  Day 43 onwards) with its own opinions.
* **GitOps controllers.** Argo CD / Flux fit cleanly on top — the
  bootstrap script deliberately stops at "manifests applied once".

## Reading order for new contributors

1. This document, top to bottom.
2. [`README.md`](../README.md) for the layout + quickstart.
3. [`docs/karpenter-guide.md`](karpenter-guide.md) for the most
   operationally-active component.
4. [`docs/upgrade-guide.md`](upgrade-guide.md) before touching the cluster
   version variable.
5. The relevant `terraform/modules/<name>/main.tf` for whichever component
   you're modifying — modules are self-contained and average ~150 lines.
