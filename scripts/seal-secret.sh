#!/usr/bin/env bash
# Seals one Secret for one product + environment and writes it next to that
# environment's values file. Values are read from stdin as KEY=VALUE lines, so
# they never appear on the command line, on screen or on disk unencrypted.
#
# Usage (from the root of GitOps-Repo):
#   <KEY=VALUE lines> | ./scripts/seal-secret.sh <product> <env> <name> [type]
# Writes apps/<product>/envs/<env>/secrets/<name>.sealed.yaml, which only the
# cluster's controller can open, and only as Secret <name> in <product>-<env>.
#
# Examples:
#   printf 'JWT_SECRET=%s\n' "$(openssl rand -hex 32)" \
#     | ./scripts/seal-secret.sh logistics staging backend-secrets
#
#   # GHCR pull secret: a classic token with ONLY read:packages
#   read -rsp 'token: ' t; echo
#   printf '.dockerconfigjson={"auths":{"ghcr.io":{"auth":"%s"}}}\n' "$(printf '%s' "you:$t" | base64 -w0)" \
#     | ./scripts/seal-secret.sh logistics staging ghcr-pull kubernetes.io/dockerconfigjson
#
#   # Add a key to an existing sealed secret, keeping the others as they are
#   # (sealed values can't be read back, so re-sealing all of them isn't possible)
#   printf 'REDIS_URL=%s\n' "$url" | MERGE=1 ./scripts/seal-secret.sh logistics uat backend-secrets
#
# Options (environment variables):
#   KUBESEAL=kubeseal   path to kubeseal (default: on PATH, or ~/bin/kubeseal.exe)
#   MERGE=1             add or replace the given keys in the existing file
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ $# -ge 3 ] || die "usage: <KEY=VALUE lines> | $0 <product> <env> <name> [type]"
product=$1 env=$2 name=$3 type=${4:-Opaque}
[ -f bootstrap/sealed-secrets/pub-cert.pem ] || die "run this from the root of GitOps-Repo"
[ -f "apps/$product/envs/$env/values.yaml" ] || die "apps/$product/envs/$env/values.yaml not found"
[ -t 0 ] && die "pipe the KEY=VALUE lines in (see the usage at the top of this script)"
KUBESEAL="${KUBESEAL:-$(command -v kubeseal || echo "$HOME/bin/kubeseal.exe")}"
[ -x "$KUBESEAL" ] || command -v "$KUBESEAL" >/dev/null || die "kubeseal not found (set KUBESEAL)"

namespace="$product-$env"
out="apps/$product/envs/$env/secrets/$name.sealed.yaml"

# The Secret, built in memory: values base64-encoded as the API expects.
secret="$(
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: %s\ndata:\n' \
    "$name" "$namespace" "$type"
  count=0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    [ -n "$line" ] || continue
    key=${line%%=*} value=${line#*=}
    [[ $line == *=* && $key =~ ^[-._A-Za-z0-9]+$ ]] || die "not a KEY=VALUE line (key '$key')"
    printf '  %s: %s\n' "$key" "$(printf '%s' "$value" | base64 | tr -d '\r\n')"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || die "no KEY=VALUE lines on stdin"
)"

ann='    argocd.argoproj.io/sync-wave: "-2" # before the migration Job (-1) and the apps (0)'
if [ "${MERGE:-}" = 1 ]; then
  [ -f "$out" ] || die "MERGE=1 but $out doesn't exist yet"
  # kubeseal rewrites the file: existing encrypted values are kept as they are.
  "$KUBESEAL" --cert bootstrap/sealed-secrets/pub-cert.pem --format yaml --merge-into "$out" <<<"$secret"
  tmp="$(tr -d '\r' <"$out" | sed -E "s|^    argocd.argoproj.io/sync-wave: \"-2\"\$|$ann|")"
  printf '%s\n' "$tmp" >"$out"
  echo "merged into $out (Secret $name in namespace $namespace, keys: $(grep -cE '^    [^ ]+: Ag' "$out"))"
  exit 0
fi

mkdir -p "$(dirname "$out")"
# Seal with the repo's public cert (no cluster access needed), then add the
# sync wave Argo CD needs: secrets before the migration Job (-1) and the apps (0).
"$KUBESEAL" --cert bootstrap/sealed-secrets/pub-cert.pem --format yaml <<<"$secret" \
  | tr -d '\r' \
  | grep -v 'creationTimestamp: null' \
  | awk -v ann="$ann" '{ print } !done && /^  namespace: / {
      print "  annotations:"
      print ann
      done = 1 }' >"$out"
echo "wrote $out (Secret $name in namespace $namespace, keys: $(grep -cE '^    [^ ]+: Ag' "$out"))"
