# reference-app

Production-style nginx workload that exercises every addon installed by the
`eks-platform-baseline` modules:

| Addon                  | Wired through                                       |
|------------------------|-----------------------------------------------------|
| Karpenter              | `nodeSelector: karpenter.sh/nodepool=default`       |
| ALB Controller         | `Ingress` with `ingressClassName: alb`              |
| cert-manager           | `cert-manager.io/cluster-issuer: letsencrypt-prod`  |
| ExternalDNS            | `external-dns.alpha.kubernetes.io/hostname` annot.  |
| metrics-server         | `HorizontalPodAutoscaler` (CPU + memory)            |
| EBS CSI / gp3 SC       | not required (stateless), but works alongside       |

## Deploy

```sh
kubectl apply -k manifests/reference-app
kubectl -n reference-app rollout status deploy/reference-app
```

## Test

```sh
# from outside (waits for ExternalDNS + ACM):
curl -fsS https://reference.example.com/healthz

# from inside the cluster:
kubectl -n reference-app port-forward svc/reference-app 8080:80
curl -fsS http://localhost:8080/
```

## Customise

* Replace `reference.example.com` in `ingress.yaml` with a hostname under a
  Route 53 zone managed by ExternalDNS.
* Lower `replicas` in `deployment.yaml` and `minAvailable` in `pdb.yaml`
  together if you need to fit a smaller cluster.
