# Upgrade guide

How to move the cluster forward one Kubernetes minor version (e.g. 1.30 →
1.31) without cratering the platform. The procedure is conservative on
purpose: it errs on the side of doing one thing at a time and verifying
each step before the next.

## Before you start

* Re-read the [official Kubernetes deprecation guide for the target
  version](https://kubernetes.io/docs/reference/using-api/deprecation-guide/).
  Skim the EKS-specific [release notes](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html).
* Confirm every Helm chart and addon supports the target version. As of
  this writing the floor is:

  | Component                        | Tested floor                  |
  |----------------------------------|-------------------------------|
  | Karpenter                        | 0.36 (1.29) / 0.37 (1.30+)    |
  | AWS Load Balancer Controller     | 1.7+                          |
  | ExternalDNS                      | 0.14+                         |
  | cert-manager                     | 1.14+                         |
  | EBS CSI driver (managed addon)   | 1.30+                         |
  | VPC CNI (managed addon)          | 1.18+                         |
  | metrics-server                   | 0.7+                          |

* Run `kubectl get apiservice` and check for any `False` `Available`
  conditions — third-party API servers (e.g. cert-manager's, the metrics
  API) have to be healthy before EKS will let you upgrade.
* Run `pluto detect-helm --target-versions k8s=v1.<NEXT>.0` against the
  cluster to surface deprecated API uses in deployed Helm releases.

## The order of operations

EKS supports upgrades only one minor version at a time. The order
within a single minor bump is:

1. **Control plane.** Bump `cluster_version` in
   `terraform/environments/dev/terraform.tfvars`, `terraform plan`,
   inspect, `apply`. EKS performs an in-place upgrade; existing nodes
   continue running the old version (their kubelet skew is acceptable
   for one minor version).
2. **AWS managed add-ons** (`vpc-cni`, `ebs-csi`, `coredns`, `kube-proxy`).
   These have target versions per Kubernetes minor; the module pins them
   to the latest stable for the requested cluster version.
3. **Helm-deployed add-ons** (`alb-controller`, `external-dns`,
   `cert-manager`, `metrics-server`, `karpenter`). Bump chart versions
   in the module variables.
4. **Managed system node group.** Update the node group AMI to the new
   version's recommended Bottlerocket AMI. Terraform uses a rolling
   update that respects PDBs; expect ~6–8 minutes per AZ.
5. **Karpenter NodePools.** Delete the existing nodes via Karpenter
   drift evaluation — Karpenter notices the new AMI ID in the
   EC2NodeClass and rolls the fleet automatically. Set
   `disruption.budgets` to limit blast radius.

## Step-by-step procedure

### 1. Control plane

```sh
# In terraform/environments/dev
sed -i 's/cluster_version = "1.30"/cluster_version = "1.31"/' terraform.tfvars
terraform plan -out=upgrade.tfplan
terraform apply upgrade.tfplan
```

The control-plane upgrade typically takes 20–30 minutes. The cluster
remains available for `kubectl` traffic throughout — the upgrade is
blue/green at the AWS side.

Verify:

```sh
kubectl version --short
aws eks describe-cluster --name <cluster_name> --query 'cluster.version'
```

### 2. AWS managed add-ons

The Terraform `vpc-cni` and `ebs-csi` modules read the current cluster
version and select the latest compatible add-on version automatically.
A second `terraform apply` after step 1 will roll them forward.

```sh
terraform apply
```

If the add-on is already at the maximum supported version Terraform
will report a no-op. EKS will roll the add-on in-place; pods stay
running.

For CoreDNS and kube-proxy (provisioned outside the platform — they
ship with the EKS cluster), use:

```sh
aws eks update-addon --cluster-name <cluster_name> --addon-name coredns \
  --addon-version <NEW_VERSION>
aws eks update-addon --cluster-name <cluster_name> --addon-name kube-proxy \
  --addon-version <NEW_VERSION>
```

The `<NEW_VERSION>` values for the target Kubernetes minor are listed
in the EKS add-on docs.

### 3. Helm-deployed add-ons

Bump the chart version in each module's `main.tf` (or pass a value to
the `chart_version` variable). Apply one module at a time — easier
to bisect a bad release.

Recommended order (least to most disruptive):

1. `metrics-server` — read-only, breakage = `kubectl top` noisy
2. `external-dns` — read-only on cluster, mutating on Route 53
3. `cert-manager` — issuance pauses but existing certs keep working
4. `alb-controller` — pauses ALB reconciliation; existing ALBs keep
   serving
5. `karpenter` — pauses node provisioning; existing nodes keep running

For each, after `terraform apply`:

```sh
kubectl -n <namespace> rollout status deployment <release>
kubectl -n <namespace> get pods
```

### 4. System node group

Triggering the rolling update is a Terraform `apply` after bumping
the AMI release version (or `null` to take the latest).

The managed node group rolls one node at a time within the AZ
unless `update_config.max_unavailable_percentage` is set higher.
Each node:

1. Cordoned by EKS.
2. Drained respecting PDBs (this is where a bad PDB will deadlock
   the upgrade — see Troubleshooting below).
3. Terminated.
4. Replaced from the new AMI.

Watch with:

```sh
kubectl get nodes -w
```

### 5. Karpenter NodePools

After the AMI is updated in the EC2NodeClass:

```sh
kubectl edit nodepool default
# (Optional) Tighten disruption budget to control blast radius:
#   spec:
#     disruption:
#       budgets:
#         - nodes: "20%"
```

Karpenter detects drift on the EC2NodeClass and rolls the fleet
gradually, respecting your budgets and the PDBs of every pod on
each node. For a fleet of N nodes at 20% budget, expect roughly
N × 90 seconds of rollover wall-clock time.

## Verification checklist

After every upgrade, before declaring success:

* [ ] `kubectl version` shows new server version on every node.
* [ ] `kubectl get nodes -L node.kubernetes.io/instance-type,karpenter.sh/capacity-type`
  shows expected fleet shape.
* [ ] All Deployments / DaemonSets in `kube-system` are
  `Available=True`.
* [ ] Reference app (`kubectl -n reference-app get ingress`) returns
  HTTP 200 from the ALB.
* [ ] cert-manager has issued a fresh staging cert in the last 24h
  (or you've manually triggered a renewal): `kubectl get certificates -A`.
* [ ] `kubectl get apiservice | grep -v True` is empty.
* [ ] CloudWatch Logs / Container Insights show no spike in pod
  restarts in the last hour.

## Rollback

EKS does **not** support downgrading the control plane. Rollback for
the control plane means: stand up a new cluster on the previous
version and shift workloads via DNS / Route 53 weighted routing.
This is one of the reasons we use a Karpenter Spot fleet rather than
giant stateful node groups — re-bootstrapping a fresh cluster is
cheap.

For the Helm-deployed add-ons, rollback is just:

```sh
helm -n <namespace> rollback <release> <previous_revision>
```

The Terraform state will detect drift on the next plan; `terraform
apply` will reconcile it back to the desired version, so do **not**
leave a manual rollback in place — fix the underlying issue and roll
forward.

## Troubleshooting

### Node group upgrade stuck on "Updating"

Almost always a pod that can't be evicted because:

* Its PDB has `minAvailable: 1` and there is only one replica.
* It tolerates `node.kubernetes.io/unschedulable=NoSchedule` and
  refuses to leave.

Find it:

```sh
kubectl get events --field-selector reason=FailedDraining -A --sort-by=.metadata.creationTimestamp
```

Either scale the workload to two replicas temporarily, or delete the
pod manually after confirming it's safe.

### Karpenter doesn't roll any nodes after AMI update

Check `kubectl describe nodeclaim` — the `Drifted` condition should
flip to `True` within a few minutes. If it's still `False`, the
EC2NodeClass `amiSelectorTerms` likely point to a static AMI ID
rather than `aliases: [bottlerocket@latest]`; switch the alias and
retry.

### cert-manager certs stuck in `Pending`

Look for `cert-manager-cainjector` errors in the pod logs. The
DNS-01 challenge often blocks if Route 53 propagation lags; setting
`acme.solvers[].dns01.route53.maxRetries: 10` in the
ClusterIssuer manifest helps with cold zones.

### ALB stops reconciling new Ingress objects

Check the LB controller pod's logs for IRSA errors:

```sh
kubectl -n kube-system logs deploy/aws-load-balancer-controller | grep -i "AccessDenied\|sts"
```

If you see `sts:AssumeRoleWithWebIdentity` failures, the cluster's
OIDC provider thumbprint may have rotated — `terraform apply`
the `eks` module to refresh.
