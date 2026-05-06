# eks-platform-baseline

Production-grade Amazon EKS baseline that ships with a hardened VPC, an EKS 1.30
control plane with IRSA, a small managed system node group, and a curated Day-2
add-on stack. The intent is a single `terraform apply` followed by one
`scripts/bootstrap-cluster.sh` invocation that yields a cluster you would be
comfortable putting workloads on the next morning.

The platform is opinionated. The opinions are documented — see
[`docs/architecture.md`](docs/architecture.md) for the design decisions and the
trade-offs that were considered and rejected.

## What you get

* **Hardened networking** — three private + three public subnets across three
  AZs, NAT Gateway egress (single-NAT in dev, per-AZ in prod), and gateway
  endpoints for S3 and interface endpoints for ECR / STS / EC2 / Logs / SSM.
* **EKS 1.30 control plane** — private + public endpoints, public side
  CIDR-restricted, all four security-relevant control-plane log types enabled,
  IRSA OIDC provider provisioned at create time.
* **Karpenter node provisioning** — Spot-first NodePool + EC2NodeClass with
  Bottlerocket AMIs, an SQS interruption queue, and EventBridge rules that
  drain nodes ~2 minutes before AWS reclaims them.
* **Ingress + DNS + TLS** — AWS Load Balancer Controller, ExternalDNS scoped
  to specific Route 53 zones, cert-manager with Route 53 DNS-01 ClusterIssuers
  for Let's Encrypt staging and production.
* **Storage** — EBS CSI driver, an encrypted `gp3` default StorageClass that
  replaces the legacy `gp2`, and a VolumeSnapshotClass for backups.
* **Networking add-ons** — VPC CNI with prefix delegation enabled (~16x more
  pods per node), and metrics-server for HPA.
* **Reference workload** — a small nginx Deployment with HPA, PDB, and ALB
  Ingress that you can use to smoke-test the platform on day one.
* **CI** — Terraform fmt / validate / tflint / checkov / trivy, plus
  manifest validation with kubeconform.

## Architecture

```
                          +--------------------------------------+
                          |             Internet                 |
                          +--------------+-----------------------+
                                         |
                                  +------v------+
                                  |  Route 53   | <--- ExternalDNS
                                  +------+------+
                                         |
                                  +------v------+
                                  |     ALB     | <--- AWS LB Controller
                                  +------+------+
                                         |
                          +--------------v-----------------------+
                          |              VPC                     |
                          |  +--------------------------------+  |
                          |  |  Public subnets (3 AZs)        |  |
                          |  |   NAT GW   ALB   NAT GW        |  |
                          |  +--------------------------------+  |
                          |  +--------------------------------+  |
                          |  |  Private subnets (3 AZs)       |  |
                          |  |  +--------------------------+  |  |
                          |  |  |       EKS 1.30           |  |  |
                          |  |  |  +--------------------+  |  |  |
                          |  |  |  |  System NG (mng)   |  |  |  |
                          |  |  |  |  CoreDNS, addons,  |  |  |  |
                          |  |  |  |  Karpenter, LBC    |  |  |  |
                          |  |  |  +--------------------+  |  |  |
                          |  |  |  +--------------------+  |  |  |
                          |  |  |  | Karpenter Spot NG  |  |  |  |
                          |  |  |  | Application pods   |  |  |  |
                          |  |  |  +--------------------+  |  |  |
                          |  |  +--------------------------+  |  |
                          |  |  VPC endpoints: S3 ECR STS    |  |
                          |  |  Logs SSM EC2                  |  |
                          |  +--------------------------------+  |
                          +--------------------------------------+
                                         |
                                  +------v------+
                                  |     EBS     | <--- EBS CSI driver
                                  |   (gp3)     |
                                  +-------------+
```

The runtime add-on stack — Karpenter, AWS Load Balancer Controller,
ExternalDNS, cert-manager, EBS CSI, VPC CNI, and metrics-server — is wired up
by Helm releases driven from Terraform, with IRSA roles minted per-controller
so no add-on relies on node IAM permissions.

## Repository layout

```
.
├── terraform/
│   ├── modules/
│   │   ├── vpc/                 # 3-AZ VPC, NAT GWs, S3/ECR/STS/Logs/SSM endpoints
│   │   ├── eks/                 # EKS cluster, IRSA, managed system node group
│   │   ├── karpenter/           # IRSA, instance profile, SQS queue, Helm release
│   │   ├── alb-controller/      # AWS Load Balancer Controller (IRSA + Helm)
│   │   ├── external-dns/        # ExternalDNS (IRSA + Helm)
│   │   ├── cert-manager/        # cert-manager (IRSA for DNS-01 + Helm)
│   │   ├── ebs-csi/             # EBS CSI driver (IRSA + Helm)
│   │   ├── vpc-cni/             # VPC CNI prefix delegation (IRSA)
│   │   └── metrics-server/      # metrics-server (Helm)
│   └── environments/
│       └── dev/                 # Reference root module wiring everything
├── helm-values/                 # Pinned values files for each Helm release
├── manifests/
│   ├── karpenter/               # NodePool + EC2NodeClass
│   ├── storage/                 # gp3 StorageClass + VolumeSnapshotClass
│   ├── cert-manager/            # ClusterIssuer (Let's Encrypt staging + prod)
│   ├── reference-app/           # nginx Deployment + Service + HPA + PDB + Ingress
│   ├── examples/                # Sample workloads using ALB Ingress
│   └── system/                  # System namespace + RBAC scaffolding
├── scripts/
│   └── bootstrap-cluster.sh     # One-command provisioner (terraform + manifests)
├── docs/                        # Architecture, addon reference, upgrade guide
└── .github/workflows/           # CI: terraform-ci.yml + kubeval.yml
```

## Quickstart

You will need: `aws` CLI v2, `terraform` >= 1.6, `kubectl` >= 1.30,
`helm` >= 3.14, and credentials with permissions to create VPC + EKS + IAM
resources in the target account.

### 1. Configure the dev environment

```sh
cd terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars   # if present, otherwise inline
```

Minimum values you will want to set:

| Variable                | Why                                                                     |
|-------------------------|-------------------------------------------------------------------------|
| `cluster_name`          | Embedded into IAM resource names; must be unique within the account.    |
| `region`                | Defaults to `ap-south-1`; override for your geography.                  |
| `endpoint_public_cidrs` | Lock the public API endpoint to your office / VPN / bastion CIDRs.      |
| `route53_zone_ids`      | Hosted zones ExternalDNS is allowed to write into.                      |
| `lets_encrypt_email`    | Used by the cert-manager ClusterIssuer to register the ACME account.    |

### 2. One-command bootstrap

```sh
AWS_PROFILE=dev ./scripts/bootstrap-cluster.sh
```

The script runs `terraform init && apply`, configures kubeconfig, waits for
each add-on Deployment to be `Ready`, then applies the Karpenter NodePool,
storage, cert-manager, and reference-app manifests in the right order.

### 3. Smoke-test

```sh
kubectl get nodes
kubectl -n reference-app get pods,hpa,ingress
kubectl -n reference-app get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'
```

If the ALB DNS name resolves and the nginx welcome page comes back, the
platform is up. If you provided a Route 53 zone, the user-friendly hostname
configured on the Ingress should resolve within a minute.

### 4. Tear down

```sh
cd terraform/environments/dev
terraform destroy
```

The bootstrap script does not delete manifests on its own — `terraform
destroy` removes Helm releases and addons, then the cluster, then the VPC.
EBS volumes provisioned by PVCs are not destroyed by Terraform; delete the
PVCs first if you want them gone.

## Add-on reference (summary)

| Add-on                        | Module path                              | Helm chart                                                            | Default version |
|-------------------------------|------------------------------------------|-----------------------------------------------------------------------|-----------------|
| Karpenter                     | `terraform/modules/karpenter`            | `oci://public.ecr.aws/karpenter/karpenter`                            | 0.37.x          |
| AWS Load Balancer Controller  | `terraform/modules/alb-controller`       | `eks-charts` / `aws-load-balancer-controller`                         | 1.8.x           |
| ExternalDNS                   | `terraform/modules/external-dns`         | `kubernetes-sigs/external-dns`                                        | 1.14.x          |
| cert-manager                  | `terraform/modules/cert-manager`         | `jetstack/cert-manager`                                               | 1.15.x          |
| EBS CSI driver                | `terraform/modules/ebs-csi`              | EKS managed add-on                                                    | latest          |
| VPC CNI                       | `terraform/modules/vpc-cni`              | EKS managed add-on (prefix delegation enabled)                        | latest          |
| metrics-server                | `terraform/modules/metrics-server`       | `kubernetes-sigs/metrics-server`                                      | 3.12.x          |

For per-add-on tuning, IRSA scope, and operational notes, see
[`docs/addon-reference.md`](docs/addon-reference.md).

## Operations

* **Upgrading EKS** — see [`docs/upgrade-guide.md`](docs/upgrade-guide.md) for
  the supported procedure (control plane, then add-ons, then node groups,
  then Karpenter NodePools).
* **Karpenter** — see [`docs/karpenter-guide.md`](docs/karpenter-guide.md) for
  NodePool tuning, troubleshooting, and the SQS interruption-handling design.
* **Contributing** — see [`CONTRIBUTING.md`](CONTRIBUTING.md) for the local
  development loop, commit-message conventions, and CI expectations.

## Status

| Day | Theme                                                       | Status |
|-----|-------------------------------------------------------------|--------|
| 37  | VPC + EKS cluster + IRSA + system node group                | DONE   |
| 38  | Karpenter (IRSA + SQS + Helm + NodePool/EC2NodeClass)       | DONE   |
| 39  | AWS Load Balancer Controller + ExternalDNS + cert-manager   | DONE   |
| 40  | EBS CSI + VPC CNI prefix delegation + metrics-server        | DONE   |
| 41  | Reference workload + CI                                     | DONE   |
| 42  | Documentation + v1.0.0                                      | DONE   |

## License

MIT — see [LICENSE](LICENSE).
