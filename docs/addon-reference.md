# Add-on reference

Operational reference for every component installed by the platform. Each
section follows the same shape: what the component does, how it's wired up,
the IRSA permissions it gets, and the most common tuning knobs.

For Karpenter, see [`karpenter-guide.md`](karpenter-guide.md) — that one is
deep enough to deserve its own document.

---

## EKS control plane (`terraform/modules/eks`)

### What it does

Provisions the EKS cluster, the IAM OIDC provider for IRSA, the cluster
service role, the worker-node IAM role, and a single small managed node
group sized for system workloads (CoreDNS, kube-proxy, the addon
controllers, metrics-server).

### Key inputs

| Variable                   | Default                                                  | Notes                                              |
|----------------------------|----------------------------------------------------------|----------------------------------------------------|
| `cluster_version`          | `1.30`                                                   | Bump in sync with the upgrade guide.               |
| `endpoint_public_access`   | `true`                                                   | Set to `false` for fully private clusters.         |
| `endpoint_public_cidrs`    | `[]` (empty — explicit allow-list)                       | Lock to your office / VPN / bastion CIDRs.         |
| `enabled_cluster_log_types`| `["api","audit","authenticator","controllerManager"]`    | `scheduler` is intentionally off.                  |
| `log_retention_days`       | `30`                                                     | Push to SIEM if you need longer retention.         |
| `system_node_group`        | `t3.medium` x2, taint `CriticalAddonsOnly=true:NoSchedule` | Application pods land on Karpenter, not here.    |

### IRSA outputs

The module emits `oidc_provider_arn` and `oidc_provider_host` for every
add-on module to consume. The OIDC thumbprint is computed via the `tls`
provider so it does not drift on regional rotations.

### Operational notes

* The system node group taint (`CriticalAddonsOnly=true:NoSchedule`)
  intentionally prevents application pods from scheduling there.
  Add-on Helm releases include the matching toleration.
* Cluster security-group rules allow the control plane → nodes ports
  (10250, 53/udp, 53/tcp) and reject everything else; the node SG starts
  empty and accepts traffic only from the cluster SG.
* The cluster role has the AWS-managed `AmazonEKSClusterPolicy` and
  `AmazonEKSVPCResourceController` policies; the worker node role has
  `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, and
  `AmazonSSMManagedInstanceCore`. CNI permissions are *not* attached
  here — the `vpc-cni` module mints an IRSA role instead.

---

## VPC (`terraform/modules/vpc`)

### What it does

Builds the network: VPC + 3 private + 3 public subnets across 3 AZs,
NAT Gateways (single-NAT or per-AZ), an Internet Gateway, route tables,
and VPC endpoints (gateway endpoints for S3 / DynamoDB; interface
endpoints for ECR API + ECR DKR + STS + EC2 + Logs + SSM + SSM Messages).

### Key inputs

| Variable           | Default          | Notes                                                                |
|--------------------|------------------|----------------------------------------------------------------------|
| `cidr`             | (required)       | Must be a valid IPv4 CIDR /16–/28.                                   |
| `azs`              | (required)       | Pick three from the region.                                          |
| `single_nat_gw`    | `true` in dev    | Set `false` in prod for per-AZ NAT.                                  |
| `enable_endpoints` | `true`           | Disable only when running over a Direct Connect / TGW egress design. |

### Subnet tagging

Public subnets are tagged `kubernetes.io/role/elb=1`; private subnets are
tagged `kubernetes.io/role/internal-elb=1`. The cluster ownership tag
(`kubernetes.io/cluster/<name>=shared`) is added on both. These tags let
the AWS Load Balancer Controller pick subnets automatically.

---

## AWS Load Balancer Controller (`terraform/modules/alb-controller`)

### What it does

Runs the Kubernetes controller that turns `Service type=LoadBalancer` and
`Ingress class=alb` objects into NLBs and ALBs. Deployed in the
`kube-system` namespace via Helm (chart `eks-charts/aws-load-balancer-controller`).

### IRSA scope

The controller's role is granted exactly the IAM actions the AWS-published
[load balancer controller policy](https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/main/docs/install/iam_policy.json)
defines (load balancer / target group / listener / WAF / Shield CRUD,
plus EC2 read for SG and subnet discovery). It is *not* granted
`iam:CreateServiceLinkedRole` — that's pre-created by the cluster role.

### Tuning

* Replicas default to `2` for HA; the values file pins anti-affinity
  across nodes.
* `replicaCount` and `resources` are exposed as module inputs.
* The webhook ports are kept at the upstream defaults (9443) so they
  don't collide with cert-manager (10260) or Karpenter (8443).

### Operational notes

* The controller uses TLS for its admission webhook; cert-manager is
  *not* required because the chart's webhook serves a self-signed cert
  rotated by a sidecar.
* Ingress objects without `ingressClassName: alb` are ignored. The
  default `IngressClass` is created by the module.

---

## ExternalDNS (`terraform/modules/external-dns`)

### What it does

Reconciles Kubernetes Ingress / Service objects into Route 53 records.

### IRSA scope

`route53:ChangeResourceRecordSets` is granted **only** on the hosted-zone
ARNs listed in the `route53_zone_ids` variable — not `*`. List operations
(`route53:List*`) are granted globally; you cannot scope those by zone.

### Tuning

* `domain_filters` defaults to the hosted zones you passed; setting it to
  a strict subset lets one cluster manage only `apps.dev.example.com`
  while another manages `apps.prod.example.com` in the same Route 53
  account.
* `txt_owner_id` is automatically `${cluster_name}-external-dns` so two
  clusters can co-exist in one zone without stepping on each other.
* `policy` defaults to `upsert-only`. Use `sync` if you want ExternalDNS
  to delete records when the source object disappears (riskier for
  production).
* `interval` defaults to `1m`. Tighten to `30s` for low-latency demos,
  loosen to `5m` for very large fleets.

---

## cert-manager (`terraform/modules/cert-manager`)

### What it does

Issues Kubernetes-native TLS certificates. The module installs the
controller via Helm and creates the IRSA role with Route 53 DNS-01
permissions. The actual `ClusterIssuer` resources (Let's Encrypt staging
+ prod) live under `manifests/cert-manager/` and are applied separately
so Terraform isn't pulled into the GitOps loop.

### IRSA scope

DNS-01 challenges only:

* `route53:GetChange` (any change ID — public from Route 53)
* `route53:ChangeResourceRecordSets` (only on the listed zones)
* `route53:ListHostedZonesByName` (global — list-only)

### ClusterIssuers shipped

| Name                         | ACME server                                            | When to use            |
|------------------------------|--------------------------------------------------------|------------------------|
| `letsencrypt-staging`        | `https://acme-staging-v02.api.letsencrypt.org/directory` | Smoke tests, CI runs.  |
| `letsencrypt-prod`           | `https://acme-v02.api.letsencrypt.org/directory`         | Production workloads.  |

The reference app uses `letsencrypt-staging` so first-time bootstraps
don't burn through the production rate-limit budget.

---

## EBS CSI driver (`terraform/modules/ebs-csi`)

### What it does

Lets PVCs provision EBS volumes and snapshots. Installed as an EKS
managed add-on so the underlying DaemonSet is reconciled by EKS itself
across version upgrades.

### IRSA scope

The AWS-managed `AmazonEBSCSIDriverPolicy` policy, attached to the
controller's service account. That policy permits `ec2:CreateVolume`,
`ec2:AttachVolume`, `ec2:DetachVolume`, `ec2:DeleteVolume`, snapshot
CRUD, and the matching `ec2:Describe*` reads, scoped via Condition
keys to the cluster.

### Storage objects

* `manifests/storage/storageclass-gp3.yaml` — `gp3`, encrypted at rest,
  set as the default class. `gp2` is removed from the default position.
* `manifests/storage/volume-snapshot-class.yaml` — used by Velero / other
  snapshot consumers.

### Operational notes

* The CSI driver is set as the default `csi.aws.amazon.com` provisioner
  via the EKS add-on manifest; legacy `kubernetes.io/aws-ebs` PVs in
  pre-existing clusters can still work but won't be migrated.
* Set `kmsKeyId` in the StorageClass parameters to use a customer-managed
  KMS key. The default uses the AWS-managed `aws/ebs` key.

---

## VPC CNI (`terraform/modules/vpc-cni`)

### What it does

Provisions the EKS managed VPC CNI add-on with prefix delegation enabled,
and the IRSA role the CNI controller uses for ENI / IP-prefix calls.

### Settings of note

* `ENABLE_PREFIX_DELEGATION=true` — the CNI claims `/28` IP prefixes
  per ENI instead of individual IPs. Pod density per node tracks the
  documented EKS limit.
* `WARM_PREFIX_TARGET=1` — keep at least one warm prefix per ENI so
  pod scheduling is not blocked by EC2 API latency.
* `ANNOTATE_POD_IP=true` — pod object annotated with the assigned IP,
  useful for VPC flow log correlation.

### IRSA scope

The AWS-managed `AmazonEKS_CNI_Policy` plus an in-line policy granting
the additional `ec2:UnassignPrivateIpAddresses` /
`ec2:UnassignIpv6Addresses` calls required by prefix delegation.

---

## metrics-server (`terraform/modules/metrics-server`)

### What it does

Powers `kubectl top` and the Horizontal Pod Autoscaler. Installed via
Helm (`kubernetes-sigs/metrics-server`) into `kube-system`.

### Tuning

* `--kubelet-insecure-tls` is **not** set; the module pins a serving
  certificate signed by the kube-apiserver CA via the
  `kubelet-serving-certs` flag.
* Resource requests are set to `100m` / `200Mi` to keep it from being
  evicted under memory pressure on the system node group.
* `priorityClassName: system-cluster-critical` so the kube-scheduler
  doesn't deprioritise it under load.

---

## Reference workload (`manifests/reference-app/`)

### What it is

A small nginx Deployment that exercises every layer the platform
provides:

* HPA with min 2 / max 10 / target CPU 60%
* PDB with `minAvailable: 1`
* `Ingress` with `kubernetes.io/ingress.class=alb`
* Liveness + readiness probes
* `securityContext.runAsNonRoot: true`
* Resource requests + limits

### Why nginx

Static, deterministic, and ARM-native — the manifests work on
Karpenter-launched Graviton (Spot) nodes without modification. If you
need something more representative of your real workloads, fork
`manifests/examples/` instead.

---

## Helm release pinning

Every Helm release in the platform is pinned to a chart version range
(e.g. `~> 1.8`). The `helm-values/` directory holds the values file for
each release. To bump a chart, change the version range in the module's
`main.tf` and the values file together — never one without the other —
and run the upgrade procedure described in
[`upgrade-guide.md`](upgrade-guide.md).
