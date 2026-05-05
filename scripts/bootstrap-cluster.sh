#!/usr/bin/env bash
#
# bootstrap-cluster.sh
#
# One-command bootstrap for the eks-platform-baseline.
#
# Workflow:
#   1. terraform init && apply (VPC, EKS, IRSA, Karpenter, ALB Ctrl, ExternalDNS,
#      cert-manager, EBS CSI, VPC CNI, metrics-server)
#   2. update-kubeconfig
#   3. wait for cluster + addons to be Ready
#   4. apply Karpenter NodePool / EC2NodeClass
#   5. apply storage manifests (gp3 StorageClass, VolumeSnapshotClass)
#   6. apply cert-manager ClusterIssuers
#   7. apply the reference application
#
# Usage:
#   AWS_PROFILE=staging ./scripts/bootstrap-cluster.sh
#   TF_DIR=terraform CLUSTER=eks-baseline REGION=us-east-1 ./scripts/bootstrap-cluster.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TF_DIR="${TF_DIR:-terraform}"
CLUSTER="${CLUSTER:-eks-baseline}"
REGION="${REGION:-us-east-1}"
SKIP_TERRAFORM="${SKIP_TERRAFORM:-false}"
SKIP_REFERENCE_APP="${SKIP_REFERENCE_APP:-false}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_PATH="${REPO_ROOT}/${TF_DIR}"

# tput colours, fall back to no-colour in non-TTY environments.
if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  C_RESET="$(tput sgr0)"
  C_BLUE="$(tput setaf 4)"
  C_GREEN="$(tput setaf 2)"
  C_YELLOW="$(tput setaf 3)"
  C_RED="$(tput setaf 1)"
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

log()    { echo "${C_BLUE}[bootstrap]${C_RESET} $*"; }
ok()     { echo "${C_GREEN}[bootstrap]${C_RESET} $*"; }
warn()   { echo "${C_YELLOW}[bootstrap]${C_RESET} $*" >&2; }
error()  { echo "${C_RED}[bootstrap]${C_RESET} $*" >&2; }

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--help]

Environment overrides:
  TF_DIR=terraform               Terraform root directory (relative to repo).
  CLUSTER=eks-baseline           EKS cluster name (matches Terraform output).
  REGION=us-east-1               AWS region.
  SKIP_TERRAFORM=false           Set true to reuse an existing cluster.
  SKIP_REFERENCE_APP=false       Set true to bootstrap the platform only.

Required tools on PATH: terraform, aws, kubectl, jq, helm.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "missing required tool: $1"
    exit 1
  fi
}

log "checking required tools..."
for tool in terraform aws kubectl jq helm; do
  require_tool "$tool"
done

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  error "AWS credentials are not configured. Set AWS_PROFILE or AWS_ACCESS_KEY_ID."
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ok "authenticated as account ${ACCOUNT_ID} in region ${REGION}"

# ---------------------------------------------------------------------------
# Cleanup hook
# ---------------------------------------------------------------------------

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Terraform
# ---------------------------------------------------------------------------

if [[ "${SKIP_TERRAFORM}" != "true" ]]; then
  log "running terraform in ${TF_PATH}"
  pushd "${TF_PATH}" >/dev/null

  terraform init -input=false -upgrade
  terraform validate
  terraform apply -input=false -auto-approve

  popd >/dev/null
  ok "terraform apply complete"
else
  warn "SKIP_TERRAFORM=true — assuming the cluster already exists"
fi

# ---------------------------------------------------------------------------
# 2. kubeconfig
# ---------------------------------------------------------------------------

log "writing kubeconfig for cluster ${CLUSTER} (${REGION})"
aws eks update-kubeconfig --name "${CLUSTER}" --region "${REGION}" --alias "${CLUSTER}"
kubectl config use-context "${CLUSTER}" >/dev/null

# ---------------------------------------------------------------------------
# 3. Wait for control plane + critical addons
# ---------------------------------------------------------------------------

log "waiting for cluster nodes to register..."
for i in {1..60}; do
  count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "${count}" -gt 0 ]]; then
    ok "${count} node(s) registered"
    break
  fi
  sleep 5
done

wait_rollout() {
  local ns="$1" kind="$2" name="$3"
  log "waiting for ${kind}/${name} in ${ns}..."
  if kubectl -n "${ns}" rollout status "${kind}/${name}" --timeout=10m; then
    ok "${kind}/${name} ready"
  else
    warn "${kind}/${name} did not become ready within timeout"
    return 1
  fi
}

# These are installed via Helm by Terraform; we still verify rollout.
wait_rollout kube-system deployment metrics-server || true
wait_rollout kube-system deployment aws-load-balancer-controller || true
wait_rollout kube-system deployment external-dns || true
wait_rollout cert-manager deployment cert-manager || true
wait_rollout cert-manager deployment cert-manager-webhook || true
wait_rollout karpenter deployment karpenter || true

# ---------------------------------------------------------------------------
# 4. Karpenter NodePool / EC2NodeClass
# ---------------------------------------------------------------------------

log "applying Karpenter NodePool and EC2NodeClass"
kubectl apply -f "${REPO_ROOT}/manifests/karpenter/ec2-nodeclass.yaml"
kubectl apply -f "${REPO_ROOT}/manifests/karpenter/nodepool.yaml"

# ---------------------------------------------------------------------------
# 5. Storage classes
# ---------------------------------------------------------------------------

log "applying storage manifests"
kubectl apply -f "${REPO_ROOT}/manifests/storage/storageclass-gp3.yaml"
kubectl apply -f "${REPO_ROOT}/manifests/storage/volume-snapshot-class.yaml"

# Make gp3 the default StorageClass (idempotent).
log "marking gp3 as the default StorageClass"
kubectl patch storageclass gp3 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' \
  >/dev/null 2>&1 || true

# Drop the default flag from gp2 if it exists.
if kubectl get storageclass gp2 >/dev/null 2>&1; then
  kubectl patch storageclass gp2 \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
    >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 6. cert-manager ClusterIssuers
# ---------------------------------------------------------------------------

log "applying cert-manager ClusterIssuers (after webhook is ready)"
# The webhook can race; retry a few times.
for i in 1 2 3 4 5; do
  if kubectl apply -f "${REPO_ROOT}/manifests/cert-manager/cluster-issuer.yaml"; then
    ok "ClusterIssuers applied"
    break
  fi
  warn "ClusterIssuer apply attempt ${i} failed; retrying in 10s..."
  sleep 10
done

# ---------------------------------------------------------------------------
# 7. Reference application
# ---------------------------------------------------------------------------

if [[ "${SKIP_REFERENCE_APP}" != "true" ]]; then
  log "deploying reference application"
  kubectl apply -k "${REPO_ROOT}/manifests/reference-app"

  if wait_rollout reference-app deployment reference-app; then
    ok "reference-app is healthy"
  else
    warn "reference-app rollout did not finish; check 'kubectl -n reference-app describe pods'"
  fi
else
  warn "SKIP_REFERENCE_APP=true — skipping reference application"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

cat <<SUMMARY

${C_GREEN}=========================================================
 eks-platform-baseline bootstrap complete
=========================================================${C_RESET}

  Cluster   : ${CLUSTER}
  Region    : ${REGION}
  Account   : ${ACCOUNT_ID}

Useful commands:

  kubectl get nodes
  kubectl get pods -A
  kubectl -n reference-app get ing reference-app
  kubectl -n karpenter logs -l app.kubernetes.io/name=karpenter -f

SUMMARY

ok "done"
