#!/usr/bin/env bash
# Sets up a lab cluster from nothing: team sealing key -> Sealed Secrets ->
# lab databases (Docker, outside the cluster) -> Argo CD -> repo access ->
# ApplicationSet. After that Argo CD deploys everything in this repo by itself.
#
# Usage (from the root of GitOps-Repo, with kubectl pointing at YOUR cluster):
#   ./scripts/bootstrap-lab.sh
#
# Options (environment variables):
#   TEAM_SECRETS=../team-secrets   path to your clone of DEVOPS-CANARY/team-secrets
#   BRANCH=main                    GitOps branch this cluster follows (asked if unset)
#   WAIT_MINUTES=20                how long to wait for each component to start
#
# Safe to re-run: every step either applies the same thing again or skips.
set -euo pipefail

REPO_SSH="git@github.com:DEVOPS-CANARY/GitOps-Repo.git"
TEAM_SECRETS="${TEAM_SECRETS:-../team-secrets}"
# A fresh node downloads every image itself; Argo CD's (220 MB) took 13 minutes
# per node through the office proxy.
WAIT_MINUTES="${WAIT_MINUTES:-20}"
GH_USER="${GH_USER:-$(git config user.name 2>/dev/null | tr -cs 'A-Za-z0-9' '-' | tr 'A-Z' 'a-z' | sed 's/-$//')}"
KEY="$HOME/.ssh/argocd-${GH_USER:-lab}-gitops"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ok: %s\n' "$*"; }
die()  { printf '\n   ERROR: %s\n' "$*" >&2; exit 1; }
fingerprint() { openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; }
# Wait for a rollout; on timeout, show WHY (pending, image pull, crash) instead
# of a bare "timed out". Usage: wait_ready <namespace> <kind/name> <pod-selector>
wait_ready() {
  echo "   waiting for $2 (first install downloads images: can take a while)"
  if ! kubectl -n "$1" rollout status "$2" --timeout="${WAIT_MINUTES}m" >/dev/null; then
    echo; echo "   $2 is not ready after $WAIT_MINUTES minutes. Pod status:"
    kubectl -n "$1" get pods -l "$3" -o wide | sed 's/^/     /'
    echo "   Recent events:"
    kubectl -n "$1" get events --sort-by=.lastTimestamp       --field-selector involvedObject.kind=Pod 2>/dev/null | grep -i "${2#*/}" | tail -8 | sed 's/^/     /'
    die "fix the cause above, then re-run this script (it is safe to re-run).
   Common causes: very slow image download (re-run, or WAIT_MINUTES=40), ImagePullBackOff
   (network/DNS/proxy to docker.io or quay.io), Pending (cluster too small:
   minikube start --cpus 2 --memory 4096)"
  fi
}

[ -f bootstrap/argo-config/applicationset.yaml ] || die "run this from the root of GitOps-Repo"

step "0/6 Checking tools and cluster"
for t in kubectl docker sops git ssh-keygen openssl; do
  command -v "$t" >/dev/null || die "'$t' is not installed (see team-secrets/README.md for sops)"
done
[ -f "$TEAM_SECRETS/secrets/sealed-secrets-key.yaml" ] \
  || die "team-secrets not found at $TEAM_SECRETS (clone it, or set TEAM_SECRETS=/path/to/it)"
CTX="$(kubectl config current-context)"
kubectl cluster-info >/dev/null 2>&1 || die "cannot reach cluster '$CTX' (is it running?)"
echo "   kubectl context: $CTX"
read -r -p "   Bootstrap THIS cluster? [y/N] " yn
[[ "$yn" =~ ^[Yy]$ ]] || die "stopped; switch context with: kubectl config use-context <name>"

step "1/6 Team sealing key (from team-secrets) -> kube-system"
# Loaded BEFORE the controller, so the controller adopts the team key instead
# of generating its own. Decrypted straight into kubectl: never written to disk.
sops -d "$TEAM_SECRETS/secrets/sealed-secrets-key.yaml" | kubectl apply -f - >/dev/null
ok "team key loaded"

step "2/6 Sealed Secrets controller"
kubectl apply -k bootstrap/sealed-secrets --server-side >/dev/null
wait_ready kube-system deploy/sealed-secrets-controller name=sealed-secrets-controller
# Ask the controller itself which key it uses (what `kubeseal --fetch-cert` does).
want="$(fingerprint < bootstrap/sealed-secrets/pub-cert.pem)"
served() { kubectl get --raw \
  /api/v1/namespaces/kube-system/services/http:sealed-secrets-controller:8080/proxy/v1/cert.pem \
  2>/dev/null | fingerprint; }
if [ "$(served)" != "$want" ]; then
  # It started before the team key was loaded and made its own; it only reads
  # keys at startup. One restart, only in that case.
  kubectl -n kube-system rollout restart deploy/sealed-secrets-controller >/dev/null
  wait_ready kube-system deploy/sealed-secrets-controller name=sealed-secrets-controller
  [ "$(served)" = "$want" ] || die "the controller does not use the team key (fingerprint mismatch)"
fi
ok "controller can unlock this repo's sealed secrets"

step "3/6 Lab services (databases), outside the cluster"
TEAM_SECRETS="$TEAM_SECRETS" ./scripts/lab-services.sh

step "4/6 Argo CD"
kubectl apply -k bootstrap/argocd --server-side >/dev/null
for d in $(kubectl -n argocd get deploy -o name); do
  wait_ready argocd "$d" "app.kubernetes.io/name=${d#*/}"
done
wait_ready argocd statefulset/argocd-application-controller app.kubernetes.io/name=argocd-application-controller
ok "Argo CD is running"

step "5/6 Read-only access to GitOps-Repo for YOUR Argo CD"
# One deploy key per cluster: if a laptop is lost, only its key is revoked.
if [ ! -f "$KEY" ]; then
  ssh-keygen -t ed25519 -N "" -C "argocd-readonly@${GH_USER:-lab}" -f "$KEY" -q
  ok "new key pair created: $KEY"
fi
can_read() { GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
  git ls-remote "$REPO_SSH" HEAD >/dev/null 2>&1; }
until can_read; do
  echo
  echo "   This key cannot read GitOps-Repo yet. Send the line below (PUBLIC key, safe"
  echo "   to share) to an org admin, and ask them to add it as a READ-ONLY deploy key"
  echo "   on DEVOPS-CANARY/GitOps-Repo, titled argocd-readonly-${GH_USER:-lab}:"
  echo
  echo "   $(cat "$KEY.pub")"
  echo
  read -r -p "   Press Enter once it is added (Ctrl+C to stop and resume later)... " _
done
kubectl -n argocd create secret generic repo-devops-canary-gitops \
  --from-literal=type=git --from-literal=url="$REPO_SSH" \
  --from-file=sshPrivateKey="$KEY" --dry-run=client -o yaml \
  | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
  | kubectl apply -f - >/dev/null
ok "Argo CD can read GitOps-Repo"

step "6/6 Which GitOps branch should this cluster follow?"
echo "   main            = the shared state (what everyone runs)"
echo "   sandbox/<name>  = your own experiments; nobody else's cluster reads it"
BRANCH="${BRANCH:-}"
[ -n "$BRANCH" ] || read -r -p "   Branch [main]: " BRANCH
BRANCH="${BRANCH:-main}"
[[ "$BRANCH" =~ ^[A-Za-z0-9._/-]+$ ]] \
  || die "branch '$BRANCH': use only letters, digits, '.', '_', '-' and '/'"
git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1 \
  || die "branch '$BRANCH' does not exist on GitOps-Repo (push it first: git push -u origin $BRANCH)"
# The ApplicationSet names the branch in several places (which folders exist,
# which commit to deploy); switch them all. '#' as the sed separator, because
# branch names contain '/' (sandbox/<name>).
config="$(kubectl kustomize bootstrap/argo-config \
  | sed -E "s#^([[:space:]]*)(revision|targetRevision): main\$#\1\2: $BRANCH#")"
grep -qE "(revision|targetRevision): $BRANCH\$" <<<"$config" \
  || die "could not point the ApplicationSet at '$BRANCH' (no 'revision: main' found)"
kubectl apply -f - <<<"$config" >/dev/null
ok "following '$BRANCH'"

step "Done"
pw="$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
cat <<EOF
   Argo CD now deploys everything in $BRANCH (first sync takes a few minutes):
     kubectl get applications -n argocd

   Argo CD UI:
     kubectl port-forward -n argocd svc/argocd-server 8080:443
     open https://localhost:8080   user: admin   password: $pw

   The apps, through Traefik (the Gateway), once Argo CD has synced them:
     kubectl -n gateway port-forward svc/traefik 18080:80
     curl -H 'Host: uat.logistics.local' http://127.0.0.1:18080/login
EOF
