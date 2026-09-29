#!/usr/bin/env bash
# End-to-end checks against a live cluster (kind in CI, or any kubectl context).
#
#   1. Chart installs into a namespace enforcing the "restricted" Pod Security
#      Standard, and `helm test` passes.
#   2. The rate limit is shared across replicas (one Redis bucket per client).
#   3. Both replicas actually receive traffic.
#   4. NetworkPolicy blocks non-API pods from reaching Redis.
#   5. A rolling restart under load drops zero requests.
set -euo pipefail

NS=${NS:-links-e2e}
REL=ratelimited-api
CLIENT_NS=e2e-client
SVC="http://$REL.$NS.svc.cluster.local"
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}

step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
pass() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; echo "- ✅ $*" >> "$SUMMARY"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; echo "- ❌ $*" >> "$SUMMARY"; exit 1; }
client() { kubectl -n "$CLIENT_NS" exec client -- sh -c "$1"; }

echo "### End-to-end results" >> "$SUMMARY"

step "Install chart into a restricted namespace"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=restricted --overwrite
# Near-zero refill rate makes the rate-limit counts deterministic.
helm upgrade --install "$REL" charts/ratelimited-api -n "$NS" \
  -f environments/dev/values.yaml \
  --set ingress.enabled=false \
  --set monitoring.serviceMonitor.enabled=false \
  --set config.trustProxy=false \
  --set config.rateLimitRPS=0.01 \
  --wait --timeout 5m
kubectl -n "$NS" wait "deploy/$REL" --for=jsonpath='{.status.readyReplicas}'=2 --timeout=180s
pass "chart installed under Pod Security 'restricted'; 2 API replicas ready"

step "helm test"
helm test "$REL" -n "$NS" --logs
pass "helm test smoke test"

step "Start client pod"
kubectl create namespace "$CLIENT_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$CLIENT_NS" run client --image=curlimages/curl:8.11.1 --restart=Never \
  --command -- sleep 3600 2>/dev/null || true
kubectl -n "$CLIENT_NS" wait pod/client --for=condition=Ready --timeout=120s

step "Rate limit is shared across replicas"
client "curl -fsS -X POST $SVC/api/v1/links -d '{\"url\":\"https://github.com/Salar24\",\"code\":\"e2e\"}'"
echo
# Burst is 10 and the POST spent one token, so a shared bucket allows 9 of
# the next 30 requests. Independent per-replica buckets would allow ~19.
read -r allowed limited < <(client "
  a=0; l=0
  for i in \$(seq 1 30); do
    c=\$(curl -s -o /dev/null -w '%{http_code}' $SVC/api/v1/links/e2e)
    case \$c in 200) a=\$((a+1));; 429) l=\$((l+1));; *) echo \"unexpected \$c\" >&2; exit 1;; esac
  done
  echo \$a \$l")
echo "allowed=$allowed limited=$limited"
if [ "$allowed" -ge 8 ] && [ "$allowed" -le 10 ]; then
  pass "shared rate limit: $allowed allowed / $limited limited of 30"
else
  fail "expected ~9 allowed with a shared bucket, got $allowed"
fi

step "Traffic reached both replicas"
for pod in $(kubectl -n "$NS" get pods -l app.kubernetes.io/component=api -o name); do
  n=$(kubectl -n "$NS" logs "$pod" | grep -c '"route":"GET /api/v1/links/{code}"' || true)
  echo "$pod served $n requests"
  [ "$n" -gt 0 ] || fail "$pod received no traffic"
done
pass "requests load-balanced across both replicas"

step "NetworkPolicy isolates Redis"
redis="$REL-redis.$NS.svc.cluster.local:6379"
if client "printf 'PING\r\n' | curl -s -m 3 telnet://$redis" 2>/dev/null | grep -q PONG; then
  fail "client pod reached Redis; NetworkPolicy not enforced"
fi
pass "Redis unreachable from outside the API pods"

step "Zero-downtime rolling restart"
client "
  end=\$((\$(date +%s) + 40)); ok=0; bad=0
  while [ \$(date +%s) -lt \$end ]; do
    c=\$(curl -s -m 2 -o /dev/null -w '%{http_code}' $SVC/healthz)
    if [ \"\$c\" = 200 ]; then ok=\$((ok+1)); else bad=\$((bad+1)); fi
  done
  echo \$ok \$bad" > /tmp/rollout-traffic &
traffic=$!
sleep 3
kubectl -n "$NS" rollout restart "deploy/$REL"
kubectl -n "$NS" rollout status "deploy/$REL" --timeout=180s
wait "$traffic"
read -r ok bad < /tmp/rollout-traffic
echo "ok=$ok failed=$bad"
[ "$ok" -gt 0 ] || fail "no successful requests during rollout"
[ "$bad" -eq 0 ] || fail "$bad of $((ok + bad)) requests failed during rolling restart"
pass "rolling restart under load: $ok requests, 0 failed"

echo -e "\n\033[1;32mAll end-to-end checks passed.\033[0m"
