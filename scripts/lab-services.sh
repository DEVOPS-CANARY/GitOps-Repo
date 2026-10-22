#!/usr/bin/env bash
# Starts the lab's stateful services (lab-services/compose.yaml) on this machine,
# outside the cluster, and creates one database + role per app per environment.
#
# Usage (from the root of GitOps-Repo, with kubectl pointing at your minikube):
#   ./scripts/lab-services.sh
#
# Passwords come from team-secrets/secrets/lab-services.yaml: each
# <PRODUCT>_<ENV>_DB_PASSWORD there becomes database and role <product>_<env>.
# They are decrypted into this process only, never written to disk.
#
# Options (environment variables):
#   TEAM_SECRETS=../team-secrets   path to your clone of DEVOPS-CANARY/team-secrets
#   LAB_BIND=<ip>                  address to publish ports on (detected if unset)
#
# Safe to re-run: existing data is kept, passwords are updated to match team-secrets.
set -euo pipefail

TEAM_SECRETS="${TEAM_SECRETS:-../team-secrets}"
SECRETS_FILE="$TEAM_SECRETS/secrets/lab-services.yaml"
COMPOSE=(docker compose --progress quiet -f lab-services/compose.yaml)

ok()  { printf '   ok: %s\n' "$*"; }
die() { printf '\n   ERROR: %s\n' "$*" >&2; exit 1; }

[ -f lab-services/compose.yaml ] || die "run this from the root of GitOps-Repo"
[ -f "$SECRETS_FILE" ] || die "$SECRETS_FILE not found (clone team-secrets, or set TEAM_SECRETS)"
docker info >/dev/null 2>&1 || die "Docker is not running"

# Where pods find this machine. minikube publishes it in the cluster DNS as
# host.minikube.internal. With Docker Desktop that address forwards to the
# host's 127.0.0.1, so ports stay local. On Linux it is the minikube network's
# gateway, a real interface we can bind to (still not the office network).
if [ -z "${LAB_BIND:-}" ]; then
  host_ip="$(kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}' 2>/dev/null \
    | awk '$2 == "host.minikube.internal" {print $1}')"
  [ -n "$host_ip" ] || die "host.minikube.internal is not in the cluster DNS (is kubectl pointing at minikube?).
   Set LAB_BIND to an address of this machine that pods can reach."
  if docker info --format '{{.OperatingSystem}}' | grep -q "Docker Desktop"; then
    LAB_BIND=127.0.0.1
  else
    LAB_BIND="$host_ip"
  fi
fi
export LAB_BIND

# Load the passwords as environment variables of this script only.
set -a
# shellcheck disable=SC1090
source <(sops -d --output-type dotenv "$SECRETS_FILE")
set +a

"${COMPOSE[@]}" up -d --wait --quiet-pull >/dev/null
ok "postgres running, published on $LAB_BIND:15432 (pods: host.minikube.internal:15432)"

# One role + database per <PRODUCT>_<ENV>_DB_PASSWORD. Values go in on stdin
# (not the command line), and \gexec only creates what doesn't exist yet.
for var in $(compgen -e | grep -E '^[A-Z0-9]+_[A-Z0-9]+_DB_PASSWORD$' || true); do
  name="$(tr 'A-Z' 'a-z' <<<"${var%_DB_PASSWORD}")"
  "${COMPOSE[@]}" exec -T postgres psql -q -U postgres -v ON_ERROR_STOP=1 >/dev/null <<SQL
\set name '$name'
\set pw '${!var}'
SELECT format('CREATE ROLE %I LOGIN', :'name')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'name') \gexec
ALTER ROLE :"name" WITH LOGIN PASSWORD :'pw';
SELECT format('CREATE DATABASE %I OWNER %I', :'name', :'name')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'name') \gexec
REVOKE ALL ON DATABASE :"name" FROM PUBLIC;
SQL
  ok "database + role: $name"
done
