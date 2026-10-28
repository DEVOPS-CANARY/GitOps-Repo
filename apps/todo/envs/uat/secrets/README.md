# Secrets for todo in UAT

Sealed secrets go in this folder. Each one can only be opened by the cluster, and only as
that Secret name in namespace `todo-uat`. Values are piped into the sealing script and
never appear on a command line, on screen or in Git. Run from the root of GitOps-Repo.

| Secret | Keys | Who provides the values |
|---|---|---|
| `ghcr-pull` | `.dockerconfigjson` | Platform team (registry read token) |
| `backend-secrets` | `JWT_SECRET` and every other secret the backend reads (the database connection is managed, see below) | The app's secret owners (readiness rule A18) |

```sh
# Registry pull secret (a token with ONLY read:packages)
read -rsp 'token: ' t; echo
printf '.dockerconfigjson={"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$(printf '%s' "bot:$t" | base64 -w0)" \
  | ./scripts/seal-secret.sh todo uat ghcr-pull kubernetes.io/dockerconfigjson

# Backend secrets (one KEY=VALUE per line; add every variable the app reads)
printf 'JWT_SECRET=%s\n' "$(openssl rand -hex 32)" \
  | ./scripts/seal-secret.sh todo uat backend-secrets

```

The database and its role (`todo_uat`) are declared in `../values.yaml`
(`database.managed`) and created by the platform's Crossplane provider on the
lab Postgres; the generated password reaches the pods as `DATABASE_URL`.
Nothing to request, nothing to seal.

Delete this file once the secrets are sealed, or keep it as the inventory.
