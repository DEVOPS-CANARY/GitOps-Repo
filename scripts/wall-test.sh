#!/usr/bin/env bash
# Proves the network walls (platform/policies) from inside an app namespace:
# starts a throwaway pod in logistics-uat (the UAT backend image by digest,
# restricted security context, the registry pull secret: everything the
# cluster's rules require) and tries to connect to places it must not reach
# and places it must. Prints PASS/FAIL per line; exits non-zero on any FAIL.
#
# Needs a CNI that enforces NetworkPolicies (Calico in the lab; minikube's
# default kindnet silently allows everything).
set -u
NS=logistics-uat
img=$(kubectl -n $NS get deploy backend -o jsonpath='{.spec.template.spec.containers[0].image}')
staging_ip=$(kubectl -n logistics-prod get pod -l app=backend -o jsonpath='{.items[0].status.podIP}')
traefik_ip=$(kubectl -n gateway get pod -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.podIP}')
keda_ip=$(kubectl -n keda get pod -l app=keda-operator -o jsonpath='{.items[0].status.podIP}')
uat_svc=$(kubectl -n $NS get svc backend -o jsonpath='{.spec.clusterIP}')
# Run on a node that already holds the UAT backend image (no new pull).
node=$(kubectl -n $NS get pod -l app=backend -o jsonpath='{.items[0].spec.nodeName}')
echo "targets: prod backend $staging_ip, traefik $traefik_ip, keda $keda_ip, uat backend svc $uat_svc"

script=$(cat <<EOF
const net = require("net"), dns = require("dns");
const tests = [
  ["prod backend pod :3001 (another environment)", "$staging_ip", 3001, "BLOCKED"],
  ["keda operator pod :8080 (platform)",        "$keda_ip",    8080, "BLOCKED"],
  ["traefik pod :8080 (admin port)",            "$traefik_ip", 8080, "BLOCKED"],
  ["traefik pod :8000 (public port; app pods never call the gateway)", "$traefik_ip", 8000, "BLOCKED"],
  ["uat backend service :80 (same namespace)",  "$uat_svc",    80,   "open"],
  ["postgres outside the cluster :15432",       "host.minikube.internal", 15432, "open"],
];
function probe(host, port) { return new Promise(r => { const s = net.connect({host, port}); s.setTimeout(3000);
  s.on("connect", () => { s.destroy(); r("open"); }); s.on("timeout", () => { s.destroy(); r("BLOCKED"); }); s.on("error", e => r(e.code === "ETIMEDOUT" || e.code === "EHOSTUNREACH" ? "BLOCKED" : "open(" + e.code + ")")); }); }
(async () => {
  let bad = 0;
  await new Promise(r => dns.lookup("kubernetes.default.svc", (e, a) => { const ok = !e; console.log((ok ? "PASS" : "FAIL") + "  DNS kubernetes.default.svc -> " + (ok ? a : e.code) + " (expected: resolves)"); if (!ok) bad++; r(); }));
  for (const [name, host, port, want] of tests) { const got = await probe(host, port); const ok = got.startsWith(want); console.log((ok ? "PASS" : "FAIL") + "  " + name + " -> " + got + " (expected: " + want + ")"); if (!ok) bad++; }
  process.exit(bad);
})();
EOF
)
overrides=$(python -c "
import json,sys
print(json.dumps({'spec':{'restartPolicy':'Never','automountServiceAccountToken':False,'nodeName':sys.argv[3],'imagePullSecrets':[{'name':'ghcr-pull'}],
 'securityContext':{'runAsNonRoot':True,'runAsUser':1000,'runAsGroup':1000,'seccompProfile':{'type':'RuntimeDefault'}},
 'containers':[{'name':'walltest','image':sys.argv[1],'command':['node','-e',sys.argv[2]],
   'securityContext':{'allowPrivilegeEscalation':False,'capabilities':{'drop':['ALL']}},
   'resources':{'requests':{'cpu':'50m','memory':'64Mi'},'limits':{'cpu':'500m','memory':'256Mi'}}}]}}))
" "$img" "$script" "$node")
kubectl -n $NS delete pod walltest --ignore-not-found >/dev/null 2>&1
kubectl -n $NS run walltest --image="$img" --restart=Never --overrides="$overrides" >/dev/null
kubectl -n $NS wait pod/walltest --for=jsonpath='{.status.phase}'=Succeeded --timeout=120s >/dev/null 2>&1 \
  || kubectl -n $NS wait pod/walltest --for=jsonpath='{.status.phase}'=Failed --timeout=10s >/dev/null 2>&1
kubectl -n $NS logs walltest
kubectl -n $NS delete pod walltest --ignore-not-found >/dev/null 2>&1
