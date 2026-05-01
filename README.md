# eks-platform-baseline

Production-grade Amazon EKS baseline that ships with a hardened VPC, an EKS 1.30 control plane,
IRSA, a managed system node group, and a Day-2 add-on stack (Karpenter, AWS Load Balancer
Controller, ExternalDNS, cert-manager, EBS CSI, VPC CNI, metrics-server). The goal is a single
`terraform apply` that yields a cluster you would be comfortable putting workloads on the next
morning.

## Repository layout

```
.
├── terraform/
│   ├── modules/
│   │   ├── vpc/                 # 3-AZ VPC, NAT GWs, S3/ECR/STS endpoints
│   │   └── eks/                 # EKS cluster, IRSA, managed node group
│   └── environments/
│       └── dev/                 # Reference root module
├── helm-values/                 # Pinned values files for each Helm release
├── manifests/                   # Kubernetes manifests (system + reference workloads)
├── scripts/                     # Bootstrap and operational helpers
├── docs/                        # Architecture, addon reference, upgrade guide
└── .github/workflows/           # CI: terraform fmt/validate + manifest validation
```

## Status

| Day | Theme | Status |
|-----|-------|--------|
| 37  | VPC + EKS cluster + IRSA + system node group | DONE |
| 38  | Karpenter | TODO |
| 39  | AWS Load Balancer Controller + ExternalDNS + cert-manager | TODO |
| 40  | EBS CSI + VPC CNI prefix delegation + metrics-server | TODO |
| 41  | Reference workload + CI | TODO |
| 42  | Documentation + v1.0.0 | TODO |

## Quickstart (dev environment)

```sh
cd terraform/environments/dev
terraform init
terraform plan -var="cluster_name=dev-eks" -var="region=ap-south-1"
terraform apply -var="cluster_name=dev-eks" -var="region=ap-south-1"

# fetch the kubeconfig produced by Terraform
aws eks update-kubeconfig --name dev-eks --region ap-south-1
kubectl get nodes
```

## Design decisions (so far)

* **Three private + three public subnets across three AZs.** EKS managed node groups
  and Karpenter are placed in private subnets only; public subnets carry NAT GWs and
  load balancers.
* **VPC endpoints for S3, ECR, and STS.** Cuts NAT traffic for image pulls and IAM
  identity calls. (Day 40 expands this for the rest of the addon traffic.)
* **EKS 1.30 with both private and public endpoints**, with the public endpoint locked
  down to an explicit allow-list. Control-plane logging is on for the four log types
  that matter for incident response (api, audit, authenticator, controllerManager).
* **OIDC provider provisioned at cluster create time** so every Day-2 addon can use IRSA
  rather than node IAM roles.
* **One small managed node group** dedicated to system pods (CoreDNS, kube-proxy,
  metrics-server, the addon controllers themselves). Application pods will land on
  Karpenter-provisioned capacity from Day 38 onwards.

## License

MIT - see [LICENSE](LICENSE).
