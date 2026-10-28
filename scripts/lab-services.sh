#!/usr/bin/env bash
# Starts the lab's stateful services (lab-services/compose.yaml) on this machine,
# outside the cluster, and creates one database + role per app per environment.
#
# Usage (from the root of GitOps-Repo, with kubectl pointing at your minikube):
#   ./scripts/lab-services.sh
#
# Passwords come from team-secrets/secrets/lab-services.yaml, decrypted into
# this process only, never written to disk in plain text:
#   <PRODUCT>_<ENV>_DB_PASSWORD     Postgres database + role <product>_<env>
#   <PRODUCT>_<ENV>_REDIS_PASSWORD  Redis user <product>_<env>, allowed only
#                                   keys and channels starting <product>:<env>:
#   REDIS_ADMIN_PASSWORD            Redis admin (the default user)
#   <PRODUCT>_<ENV>_KAFKA_PASSWORD  Kafka user <product>_<env>, allowed only
#                                   topics and consumer groups <env>.<product>.*
# Kafka topics come from lab-services/kafka-topics.txt.
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
ok "redis running, published on $LAB_BIND:16379 (pods: host.minikube.internal:16379)"
ok "kafka running, published on $LAB_BIND:19092 (pods: host.minikube.internal:19092)"

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

# Redis users: one per <PRODUCT>_<ENV>_REDIS_PASSWORD, restricted to its own
# prefix (environments share this Redis but can't see each other). The file
# holds SHA-256 hashes, never passwords. Pub/sub isn't separated by Redis
# "databases", which is why isolation is per user. A pattern subscription
# must match an allowed pattern literally, hence the extra Socket.io pattern.
[ -n "${REDIS_ADMIN_PASSWORD:-}" ] || die "REDIS_ADMIN_PASSWORD missing from $SECRETS_FILE"
sha256() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1; }
acl="user default on #$(printf '%s' "$REDIS_ADMIN_PASSWORD" | sha256) ~* &* +@all"
users=()
for var in $(compgen -e | grep -E '^[A-Z0-9]+_[A-Z0-9]+_REDIS_PASSWORD$' || true); do
  name="$(tr 'A-Z' 'a-z' <<<"${var%_REDIS_PASSWORD}")"   # logistics_uat
  prefix="${name/_/:}:"                                  # logistics:uat:
  acl+=$'\n'"user $name on #$(printf '%s' "${!var}" | sha256) resetkeys ~$prefix* resetchannels &$prefix* &${prefix}socket.io#/#* +@all -@dangerous"
  users+=("$name")
done
"${COMPOSE[@]}" exec -T redis sh -c 'cat > /data/users.acl' <<<"$acl"
# Reload as the admin. The password goes in on stdin. (On the very first run
# the admin has no password yet; redis-cli says so and runs the command anyway.)
reload="$(printf '%s\n' "$REDIS_ADMIN_PASSWORD" \
  | "${COMPOSE[@]}" exec -T redis redis-cli --no-auth-warning --askpass ACL LOAD 2>&1)"
[ "$(tail -n1 <<<"$reload")" = "OK" ] || die "Redis did not load the users: $(tail -n1 <<<"$reload")"
for name in "${users[@]}"; do ok "redis user: $name (keys and channels ${name/_/:}:*)"; done

# Kafka: one user per <PRODUCT>_<ENV>_KAFKA_PASSWORD, allowed only topics and
# consumer groups starting <env>.<product>. (nothing is allowed by default).
# Admin commands use the broker's in-container admin listener, which needs no
# password. The password goes in on stdin and only reaches the tool inside the
# container.
kafka() { MSYS_NO_PATHCONV=1 "${COMPOSE[@]}" exec -T kafka "/opt/kafka/bin/$1" --bootstrap-server 127.0.0.1:9094 "${@:2}"; }
# The platform's Crossplane provider-kafka administers topics, users and ACLs
# through the client listener as SCRAM superuser "admin" (KAFKA_SUPER_USERS).
if [ -n "${KAFKA_ADMIN_PASSWORD:-}" ]; then
  printf '%s\n' "$KAFKA_ADMIN_PASSWORD" | MSYS_NO_PATHCONV=1 "${COMPOSE[@]}" exec -T kafka sh -c \
    'read -r pw; exec /opt/kafka/bin/kafka-configs.sh --bootstrap-server 127.0.0.1:9094 --alter --entity-type users --entity-name admin --add-config "SCRAM-SHA-512=[iterations=8192,password=$pw]"' >/dev/null
  ok "kafka admin user for Crossplane (provider-kafka)"
fi
for var in $(compgen -e | grep -E '^[A-Z0-9]+_[A-Z0-9]+_KAFKA_PASSWORD$' || true); do
  name="$(tr 'A-Z' 'a-z' <<<"${var%_KAFKA_PASSWORD}")"     # logistics_uat
  product="${name%%_*}" env="${name#*_}"
  prefix="$env.$product."                                # uat.logistics.
  printf '%s\n' "${!var}" | MSYS_NO_PATHCONV=1 "${COMPOSE[@]}" exec -T kafka sh -c \
    'read -r pw; exec /opt/kafka/bin/kafka-configs.sh --bootstrap-server 127.0.0.1:9094 --alter --entity-type users --entity-name "$0" --add-config "SCRAM-SHA-512=[iterations=8192,password=$pw]"' \
    "$name" >/dev/null
  kafka kafka-acls.sh --add --allow-principal "User:$name" --operation Read --operation Write \
    --operation Describe --topic "$prefix" --resource-pattern-type prefixed >/dev/null
  kafka kafka-acls.sh --add --allow-principal "User:$name" --operation Read \
    --group "$prefix" --resource-pattern-type prefixed >/dev/null
  topics=()
  while read -r p topic partitions; do
    [ "$p" = "$product" ] || continue
    kafka kafka-topics.sh --create --if-not-exists --topic "$prefix$topic" \
      --partitions "$partitions" --replication-factor 1 >/dev/null
    topics+=("$prefix$topic")
  done < <(grep -vE '^\s*(#|$)' lab-services/kafka-topics.txt)
  ok "kafka user: $name (topics and groups $prefix*; topics: ${topics[*]:-none})"
done

