# Karpenter Guide

Karpenter is the cluster-autoscaler replacement that ships with this
platform. It watches for unschedulable pods, picks the cheapest EC2
instance type that fits them, and launches a node directly via the EC2
RunInstances API — no node-group rolling-update dance, no scale-from-zero
delay.

This guide covers day-2 operations: how Karpenter is wired up, how to
tune NodePools for different workloads, and how to debug the most common
failure modes.

## Architecture

The `terraform/modules/karpenter/` module deploys four pieces:

1. **IRSA role** for the Karpenter controller. The trust policy is scoped
   to exactly this cluster's OIDC provider and the
   `system:serviceaccount:karpenter:karpenter` subject. The attached
   policy lets the controller call `ec2:RunInstances`, `ec2:CreateFleet`,
   `ec2:TerminateInstances`, `iam:PassRole` on the worker-node role only,
   and read pricing + SSM AMI parameters.

2. **EC2 instance profile** wrapping the worker-node IAM role from the
   `eks` module. Every node Karpenter launches uses this profile, which
   means Karpenter-launched nodes and managed-node-group nodes have
   identical kubelet permissions.

3. **SQS interruption queue** + **EventBridge rules** for graceful
   handling of EC2 spot interruptions, scheduled-change events, and
   AZ-rebalance recommendations. The controller drains affected nodes
   ~2 minutes before AWS reclaims them.

4. **Helm release** of the Karpenter controller (chart from
   `oci://public.ecr.aws/karpenter/karpenter`). Pinned to a specific
   chart version via the `chart_version` variable.

The `manifests/karpenter/` directory holds the Kubernetes objects you
apply *after* terraform finishes:

- `ec2-nodeclass.yaml` — AWS-specific bits (AMI family, security
  groups, block device mappings, user-data).
- `nodepool.yaml` — Kubernetes-side scheduling constraints (taints,
  requirements, disruption budgets).

## Apply order

```bash
# 1. Provision the controller + IAM + SQS.
cd terraform/environments/dev
terraform apply

# 2. Apply the NodePool + EC2NodeClass. They reference CRDs that the
# Helm chart installed in step 1, so order matters.
kubectl apply -f ../../../manifests/karpenter/ec2-nodeclass.yaml
kubectl apply -f ../../../manifests/karpenter/nodepool.yaml

# 3. Verify the controller is up.
kubectl -n karpenter get pods
kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --tail=50
```

## Provisioning examples

### Example 1: A standard stateless deployment

The default NodePool taints nodes with `workload=stateless:NoSchedule`.
Workloads that should land on those nodes must tolerate the taint and
declare nodeSelector so they don't get scheduled onto the system MNG by
accident:

```yaml
spec:
  template:
    spec:
      tolerations:
        - key: workload
          value: stateless
          operator: Equal
          effect: NoSchedule
      nodeSelector:
        workload: stateless
      containers:
        - name: app
          image: ghcr.io/example/app:1.2.3
          resources:
            requests:
              cpu: 250m
              memory: 256Mi
            limits:
              cpu: 1
              memory: 512Mi
```

Karpenter inspects the resource requests, picks the cheapest spot
instance from the `c`/`m`/`r` families that fits the pod (plus any
pending pods it can co-schedule), and launches it.

### Example 2: A workload that must run on Graviton only

Add a node selector for the architecture:

```yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64
        workload: stateless
```

### Example 3: A workload that cannot tolerate spot interruptions

Add a node selector for capacity type:

```yaml
spec:
  template:
    spec:
      nodeSelector:
        karpenter.sh/capacity-type: on-demand
        workload: stateless
```

For workloads that need stronger guarantees (databases, queues with
local volumes), create a *separate* NodePool with `capacity-type: ["on-demand"]`,
`disruption.consolidationPolicy: WhenEmpty`, and a longer
`expireAfter` (e.g. `720h`). Reference it via a unique label or taint.

### Example 4: GPU workloads

The default NodePool excludes GPU instance categories. To run GPU
workloads, add a dedicated NodePool:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      taints:
        - key: nvidia.com/gpu
          value: "true"
          effect: NoSchedule
      requirements:
        - key: karpenter.k8s.aws/instance-family
          operator: In
          values: ["g5", "g6", "p4d"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
```

## Tuning the disruption budget

The default NodePool throttles consolidation to **10%** of the fleet
during business hours and **30%** off-hours. Tune for your appetite:

- **Cost-sensitive**, lots of churn ok: bump to `nodes: "50%"`. Karpenter
  rolls more aggressively, saving money but creating short
  capacity-availability gaps.
- **Stability-sensitive**, latency SLOs: drop to `nodes: "5%"` or set
  schedule-based budgets that keep disruption to overnight windows only.
- **No disruption ever**: `disruption.consolidationPolicy: WhenEmpty`
  and remove the `Drifted` budget entirely.

## Troubleshooting

### Pending pods, no nodes launching

1. Check the controller is running:
   ```bash
   kubectl -n karpenter get pods
   ```
2. Tail the controller log for scheduling decisions:
   ```bash
   kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter --tail=200 | grep -i "could not schedule"
   ```
   Common causes:
   - **No matching NodePool** — the pod's nodeSelector / tolerations
     don't match any NodePool's template. Karpenter logs the unmet
     constraint.
   - **`nodeClassRef` points at a missing EC2NodeClass** — Karpenter
     emits an event on the NodePool. `kubectl describe nodepool default`
     and look at the "Conditions" stanza.
   - **Subnet / SG selector returned zero matches** — the cluster's
     subnets and security groups need the
     `karpenter.sh/discovery: <cluster-name>` tag. Verify with:
     ```bash
     aws ec2 describe-subnets \
       --filters "Name=tag:karpenter.sh/discovery,Values=<cluster>"
     ```

### Nodes launch but pods stay pending

The node is up but kubelet hasn't joined yet. Walk through:

1. `kubectl get nodes` — does the node show up at all? If not, check
   the EC2 console for the instance's status.
2. `aws ec2 describe-instances --instance-id <id> --query 'Reservations[0].Instances[0].State'`
3. SSH (or SSM Session Manager) onto the node, check
   `/var/log/cloud-init-output.log` and `journalctl -u kubelet`.
   Bottlerocket: `apiclient get` + `journalctl -u kubelet`.

Most join failures are IAM: the worker-node role's trust policy or
attached policies are wrong. Re-verify with the CloudFormation reference
at https://karpenter.sh/docs/reference/cloudformation/.

### IRSA `Could not assume role` errors

Tail the Karpenter controller log; if you see lines like:

```
ERROR controller.aws AssumeRoleWithWebIdentity failed
```

The OIDC provider host string passed into the module doesn't match the
cluster's actual issuer. Check:

```bash
aws eks describe-cluster --name <cluster> \
  --query 'cluster.identity.oidc.issuer' --output text
```

The host part of that URL (everything after `https://`) must equal the
`oidc_provider_host` variable.

### Spot interruption notifications never reach the queue

```bash
# Confirm the rules exist and target the queue:
aws events list-targets-by-rule \
  --rule karpenter-<cluster>-spot-interruption

# Confirm the queue policy allows events.amazonaws.com to publish:
aws sqs get-queue-attributes \
  --queue-url $(aws sqs get-queue-url --queue-name karpenter-<cluster> --query QueueUrl --output text) \
  --attribute-names Policy
```

If both look fine but messages still don't arrive, the events likely
fired before the rule was created — they aren't replayed. Wait for the
next interruption (you can simulate one with the EC2 fault-injection
service) and verify.

### Drift rolling more nodes than you expected

Karpenter detects "drift" when an EC2 instance's actual configuration
diverges from what the NodePool / EC2NodeClass currently specifies (new
AMI, new security group, new subnet tag). The default policy rolls
drifted nodes during the disruption window. To freeze:

```yaml
disruption:
  budgets:
    - nodes: "0"
      reasons: ["Drifted"]
```

Then bump the `expireAfter` field instead — that triggers controlled
rollover on a fixed schedule.

## References

- Karpenter docs: https://karpenter.sh
- CRD reference: https://karpenter.sh/docs/concepts/
- Migration guide: https://karpenter.sh/docs/upgrading/upgrade-guide/
- IAM reference: https://karpenter.sh/docs/reference/cloudformation/
