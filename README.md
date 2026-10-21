# GitOps-Repo (DEVOPS-CANARY)

Desired state of the lab cluster. Argo CD watches this repo and makes the
cluster match it; nobody runs `kubectl apply` for apps.

```
bootstrap/                 applied once per cluster (scripts/bootstrap-lab.sh)
  argocd/                  Argo CD, pinned release
  sealed-secrets/          Sealed Secrets controller + its public sealing cert
  argo-config/             AppProject "lab" + the ApplicationSet
apps/<product>/envs/<env>/
  values.yaml              chart version, image digests, config, host (rssb-app chart)
  secrets/                 sealed secrets for this product in this environment
lab-services/compose.yaml  LAB ONLY: databases in Docker, outside the cluster
scripts/                   bootstrap-lab.sh, lab-services.sh
```

The ApplicationSet turns every `apps/<product>/envs/<env>/values.yaml` into an
Argo CD Application `<product>-<env>`, deployed to its own namespace
`<product>-<env>` (e.g. `logistics-uat`). Products never share a namespace, so
their object names can't collide, and quotas, access and network rules can be
set per product.

Apps are rendered by the platform chart
[`rssb-app`](https://github.com/DEVOPS-CANARY/helm-charts) at the version in
`chart.version`, so there is no Kubernetes YAML to copy per app.

**Databases live outside the cluster**, as at RSSB, where they run on their own
VMs. In the lab they run in Docker on your machine (`lab-services/`), and pods
reach them at `host.minikube.internal:15432`. Deleting the cluster doesn't
touch the data.

## Your own lab cluster (teammates start here)

Everyone runs their own cluster from this repo. Clusters only **read** Git, so
yours can't affect anyone else's. The only shared thing is this repo's `main`.

**Before you start:**
- You have `kubectl`, `docker`, `git`, `openssl` and `sops`, and you are a member of
  `team-secrets` (see its README).
- A running minikube with an ingress controller:
  ```sh
  minikube start -p devops-lab --cpus 4 --memory 6144
  minikube -p devops-lab addons enable ingress
  ```
  One node is enough for the lab. Add `--nodes 3` to rehearse node failures; on
  some Linux hosts multi-node minikube has pod networking problems.

```sh
git clone git@github.com:DEVOPS-CANARY/GitOps-Repo.git
git clone git@github.com:DEVOPS-CANARY/team-secrets.git
cd GitOps-Repo
./scripts/bootstrap-lab.sh      # Windows: run it from Git Bash
```

What the script does, in order:

1. Loads the team's Sealed Secrets key from `team-secrets`, so your cluster can
   unlock the same `*.sealed.yaml` files.
2. Installs the Sealed Secrets controller, and checks it really uses that key.
3. Starts the lab databases in Docker (`scripts/lab-services.sh`), with the
   passwords from `team-secrets`.
4. Installs Argo CD.
5. Creates **your own** read-only deploy key. It shows you the public half to send to
   an org admin, then waits until the key works.
6. Asks which branch your cluster follows, and applies the ApplicationSet.

Re-running it is safe.

**Experimenting without affecting others:** push a branch such as `sandbox/<you>`,
then run the script with `BRANCH=sandbox/<you>`. Only your cluster deploys it.
Merge `main` into your branch now and then to pick up new UAT deploys. When an
experiment works, open a PR to `main`.

**Manual steps** (what the script automates):

```sh
sops -d ../team-secrets/secrets/sealed-secrets-key.yaml | kubectl apply -f -
kubectl apply -k bootstrap/sealed-secrets --server-side
./scripts/lab-services.sh
kubectl apply -k bootstrap/argocd --server-side
# repo access for Argo CD (read-only deploy key), then:
kubectl apply -k bootstrap/argo-config
```

## Deploying
- **UAT:** CI commits the new image digest to `apps/<product>/envs/uat/values.yaml` on
  every merge to the app's `develop` branch.
- **Staging:** promotion copies the digest already tested in UAT (no rebuild).
- **Rollback:** `git revert` the commit that changed the digest.

## Adding a product
1. `apps/<product>/envs/uat/values.yaml`: copy logistics' and change what differs.
2. A database: add `<PRODUCT>_UAT_DB_PASSWORD` to `team-secrets/secrets/lab-services.yaml`
   and re-run `./scripts/lab-services.sh`.
3. `apps/<product>/envs/uat/secrets/`: its sealed secrets, for namespace `<product>-uat`.

## Secrets
Never commit a plain Secret. Seal it with the public cert:
```sh
kubectl create secret generic NAME -n <product>-<env> --from-literal=KEY=VALUE --dry-run=client -o yaml \
  | kubeseal --cert bootstrap/sealed-secrets/pub-cert.pem --format yaml > NAME.sealed.yaml
```
Only the controller in the cluster can decrypt it, and only for that name and
namespace. Add `argocd.argoproj.io/sync-wave: "-2"` so it exists before the
migration Job and the pods that use it.
