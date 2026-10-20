# GitOps-Repo (DEVOPS-CANARY)

Desired state of the lab cluster. Argo CD watches this repo and makes the
cluster match it; nobody runs `kubectl apply` for apps.

```
bootstrap/                 applied once by hand, in this order
  argocd/                  Argo CD, pinned release
  sealed-secrets/          Sealed Secrets controller + its public sealing cert
  argo-config/             AppProject "lab" + the ApplicationSet
apps/<app>/envs/<env>/
  values.yaml              chart version, image digests, config, host (rssb-app chart)
  secrets/                 sealed secrets for this app in this environment
infra/<component>/envs/<env>   lab stand-ins for external services (Postgres)
```

The ApplicationSet turns every `apps/*/envs/*/values.yaml` and `infra/*/envs/*`
folder into an Argo CD Application named `<app>-<env>`, deployed to namespace `<env>`.
Apps are rendered by the platform chart
[`rssb-app`](https://github.com/DEVOPS-CANARY/helm-charts) at the version in
`chart.version`, so there is no Kubernetes YAML to copy per app.

## Your own lab cluster (teammates start here)

Everyone runs their own cluster from this repo. Clusters only **read** Git, so
yours can't affect anyone else's. The only shared thing is this repo's `main`.

**Before you start:**
- You have `kubectl`, `git`, `openssl` and `sops`, and you are a member of `team-secrets`
  (see its README).
- A running cluster, e.g. `minikube start -p devops-lab --nodes 3 --cpus 2 --memory 4096`.

```sh
git clone git@github.com:DEVOPS-CANARY/GitOps-Repo.git
git clone git@github.com:DEVOPS-CANARY/team-secrets.git
cd GitOps-Repo
./scripts/bootstrap-lab.sh      # Windows: run it from Git Bash
```

What the script does, in order:

1. Loads the team's Sealed Secrets key from `team-secrets`, so your cluster can
   unlock the same `*.sealed.yaml` files.
2. Installs the Sealed Secrets controller, and checks it really has that key.
3. Installs lab storage, then Argo CD.
4. Creates **your own** read-only deploy key. It shows you the public half to send to
   an org admin, then waits until the key works.
5. Asks which branch your cluster follows, and applies the ApplicationSet.

Re-running it is safe.

**Experimenting without affecting others:** push a branch such as `sandbox/<you>`,
then run the script with `BRANCH=sandbox/<you>`. Only your cluster deploys it.
Merge `main` into your branch now and then to pick up new UAT deploys. When an
experiment works, open a PR to `main`.

**Manual steps** (what the script automates):

```sh
sops -d ../team-secrets/secrets/sealed-secrets-key.yaml | kubectl apply -f -
kubectl apply -k bootstrap/sealed-secrets --server-side
kubectl apply -k bootstrap/lab-storage        # minikube lab only
kubectl apply -k bootstrap/argocd --server-side
# repo access for Argo CD (read-only deploy key), then:
kubectl apply -k bootstrap/argo-config
```

## Deploying
- **UAT:** CI commits the new image digest to `apps/<app>/envs/uat/values.yaml` on every
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
