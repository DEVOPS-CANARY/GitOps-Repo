# GitOps-Repo (DEVOPS-CANARY)

Desired state of the lab cluster. Argo CD watches this repo and makes the
cluster match it; nobody runs `kubectl apply` for apps.

```
bootstrap/                 applied once per cluster (scripts/bootstrap-lab.sh)
  argocd/                  Argo CD, pinned release
  sealed-secrets/          Sealed Secrets controller + its public sealing cert
  argo-config/             AppProjects "lab" and "platform", the ApplicationSet,
                           and the platform Applications (Gateway API, Traefik, KEDA)
platform/traefik/          Traefik settings: the cluster's entry point
platform/keda/             KEDA settings: autoscaling on events (e.g. Kafka lag)
platform/kyverno/          Kyverno settings: the policy engine
platform/policies/         our policies: walls, quota and limits per app namespace,
                           images pinned by digest, Traefik's admin port closed
apps/<product>/
  values.yaml              what is the same in every environment (rssb-app chart)
  envs/<env>/              uat, staging, prod
    values.yaml            chart version, image digests, host, per-env settings
    secrets/               sealed secrets for this product in this environment
lab-services/compose.yaml  LAB ONLY: databases in Docker, outside the cluster
scripts/                   bootstrap-lab.sh, lab-services.sh, seal-secret.sh, wall-test.sh
```

The ApplicationSet turns every `apps/<product>/envs/<env>/values.yaml` into an
Argo CD Application `<product>-<env>`, deployed to its own namespace
`<product>-<env>` (e.g. `logistics-uat`). Products never share a namespace, so
their object names can't collide, and quotas, access and network rules can be
set per product.

Apps are rendered by the platform chart
[`rssb-app`](https://github.com/DEVOPS-CANARY/helm-charts) at the version in
`chart.version`, so there is no Kubernetes YAML to copy per app. Argo CD gives
the chart two values files: the product's shared `values.yaml`, then the env's
own on top. An env file holds only what differs, so a setting can't be changed
in UAT and forgotten in prod.

**One entry point for every app:** Traefik, as a
[Gateway API](https://gateway-api.sigs.k8s.io/) controller, runs the shared Gateway
`gateway/public`. The chart gives each exposed app an `HTTPRoute` on its env's host
(e.g. `uat.logistics.local`: `/` to the frontend, `/api` to the backend). Apps never
name Traefik, so it can be replaced by another Gateway API implementation. Only
namespaces labelled `product` (app namespaces) can attach routes. To try it:
```sh
kubectl -n gateway port-forward svc/traefik 18080:80
curl -H 'Host: uat.logistics.local' http://127.0.0.1:18080/login
```
Swap the host for `staging.logistics.local` or `logistics.local` (prod). On Linux
you can also skip the port-forward and use `http://$(minikube -p devops-lab ip):30080`.

**Traefik dashboard** (read-only; admins with `kubectl` access only, never on the
public Gateway): `kubectl -n gateway port-forward deploy/traefik 9000:8080`, then open
http://localhost:9000/dashboard/. It shows every route, its host and path rule, and
the pods behind it.

**Autoscaling on events:** KEDA (namespace `keda`) scales a Deployment on the work
waiting for it, e.g. a Kafka consumer on its lag, not only on CPU. An app asks for it
in its values file (rssb-app chart); KEDA measures the metric and feeds it to a normal
HorizontalPodAutoscaler. To see what it is doing: `kubectl get scaledobject,hpa -A`.

**Walls between apps:** Kyverno (namespace `kyverno`, policies in `platform/policies/`) gives
every app namespace default-deny network rules (open only to the gateway, its own namespace,
DNS and the world outside the cluster), a quota and default limits, and refuses any image that
is not from our registry by digest. `scripts/wall-test.sh` proves it from a pod in UAT.

**Databases, Redis and Kafka live outside the cluster**, as at RSSB, where they run
on their own VMs. In the lab they run in Docker on your machine (`lab-services/`), and
pods reach them at `host.minikube.internal`: `:15432` (Postgres), `:16379` (Redis),
`:19092` (Kafka). Each app environment gets its own:
- Postgres database;
- Redis user, which may only use keys and channels starting `<app>:<env>:` (Redis
  "databases" don't separate pub/sub, so the separation is per user);
- Kafka user (SCRAM), which may only use topics and consumer groups starting
  `<env>.<app>.`. Nothing is allowed by default. Topics are declared in
  `lab-services/kafka-topics.txt`. Deleting the cluster doesn't
touch the data.

## Your own lab cluster (teammates start here)

Everyone runs their own cluster from this repo. Clusters only **read** Git, so
yours can't affect anyone else's. The only shared thing is this repo's `main`.

**Before you start:**
- You have `kubectl`, `docker`, `git`, `openssl` and `sops`, and you are a member of
  `team-secrets` (see its README).
- A running minikube (no ingress addon: Argo CD installs Traefik):
  ```sh
  minikube start -p devops-lab --cpus 4 --memory 6144 --cni calico
  ```
  Already have the ingress addon from an earlier setup? Nothing uses it any more.
  Disabling the addon doesn't remove it on a multi-node minikube, so also delete
  what it installed (the webhook first, or creating any Ingress would fail):
  ```sh
  minikube -p devops-lab addons disable ingress
  kubectl delete validatingwebhookconfiguration ingress-nginx-admission --ignore-not-found
  kubectl delete ingressclass nginx --ignore-not-found
  kubectl delete clusterrole,clusterrolebinding -l app.kubernetes.io/name=ingress-nginx
  kubectl delete namespace ingress-nginx --ignore-not-found
  ```
  `--cni calico` matters: minikube's default network plugin ignores NetworkPolicies,
  so the walls between apps (Kyverno, `platform/policies/`) would silently not exist.
  MicroK8s at RSSB ships Calico. A CNI can only be chosen when the cluster is created.
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
- **Staging:** on every merge to the app's `staging` branch, CI finds the image
  already built for UAT (same content, so same `tree-` tag) and commits its digest
  to `envs/staging/values.yaml`. Nothing is rebuilt.
- **Prod:** the app's approved *Release* workflow, run on `main`, commits the
  digest that Staging runs to `envs/prod/values.yaml`.
- **Rollback:** `git revert` the commit that changed the digest.

**Changing `bootstrap/argo-config`:** Argo CD does not manage its own ApplicationSet,
so after such a PR is merged, every cluster re-applies it:
`kubectl apply -k bootstrap/argo-config`, or re-run the bootstrap.
For a cluster that follows `sandbox/<you>`, merge `main` into that branch first and
re-run the bootstrap, so the branch is applied, not `main`.

## Adding a product
1. `apps/<product>/values.yaml` and `apps/<product>/envs/<env>/values.yaml`: copy
   logistics' and change what differs.
2. A database per env: add `<PRODUCT>_<ENV>_DB_PASSWORD` to
   `team-secrets/secrets/lab-services.yaml` and re-run `./scripts/lab-services.sh`.
3. `apps/<product>/envs/<env>/secrets/`: its sealed secrets (below).

## Secrets
Never commit a plain Secret. Pipe `KEY=VALUE` lines into `scripts/seal-secret.sh`,
which seals them with the public cert and adds the sync wave (so the secret exists
before the migration Job and the pods that use it):
```sh
printf 'JWT_SECRET=%s\n' "$(openssl rand -hex 32)" \
  | ./scripts/seal-secret.sh <product> <env> backend-secrets
```
Only the controller in the cluster can decrypt it, and only as that name in
namespace `<product>-<env>`. A file sealed for UAT is useless in prod. The script's
header shows how to seal the GHCR pull secret. Check a file against your cluster
with `kubeseal --validate --controller-namespace kube-system < FILE`.
