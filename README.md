# k8s-devops-lab-gitops

Desired state of the lab cluster. Argo CD watches this repo and makes the
cluster match it; nobody runs `kubectl apply` for apps.

```
bootstrap/                 applied once by hand, in this order
  argocd/                  Argo CD, pinned release
  sealed-secrets/          Sealed Secrets controller + its public sealing cert
  argo-config/             AppProject "lab" + the ApplicationSet
apps/<app>/
  base/                    environment-independent manifests
  envs/<env>/              image digests, config, sealed secrets, host
infra/<component>/envs/<env>   lab stand-ins for external services (Postgres)
```

The ApplicationSet turns every `apps/*/envs/*` and `infra/*/envs/*` folder into
an Argo CD Application named `<app>-<env>`, deployed to namespace `<env>`.

## Bootstrap a cluster
```sh
kubectl apply -k bootstrap/argocd --server-side
kubectl apply -k bootstrap/sealed-secrets --server-side
kubectl apply -k bootstrap/lab-storage        # minikube lab only
# repo access for Argo CD (read-only deploy key), then:
kubectl apply -k bootstrap/argo-config
```

## Deploying
- **UAT:** CI commits the new image digest to `apps/<app>/envs/uat` on every
  merge to the app's `develop` branch.
- **Staging:** promotion copies the digest already tested in UAT (no rebuild).
- **Rollback:** `git revert` the commit that changed the digest.

## Secrets
Never commit a plain Secret. Seal it with the public cert:
```sh
kubectl create secret generic NAME -n ENV --from-literal=KEY=VALUE --dry-run=client -o yaml \
  | kubeseal --cert bootstrap/sealed-secrets/pub-cert.pem --format yaml > NAME.sealed.yaml
```
Only the controller in the cluster can decrypt it, and only for that name and
namespace.
