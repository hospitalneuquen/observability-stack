#!/usr/bin/env bash
# Smoke checks before handing the demo to developers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Load .env if present
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

PUBLIC_PORT="${PUBLIC_PORT:-8080}"
BASE="http://localhost:${PUBLIC_PORT}"
AUTH_USER="${GF_SECURITY_ADMIN_USER:-admin}"
AUTH_PASS="${GF_SECURITY_ADMIN_PASSWORD:-changeme}"
NGX_USER="${NGINX_BASIC_AUTH_USER:-observer}"
NGX_PASS="${NGINX_BASIC_AUTH_PASSWORD:-changeme}"
FAIL=0

ok()   { printf '  OK  %s\n' "$*"; }
fail() { printf ' FAIL %s\n' "$*"; FAIL=1; }

echo "== containers =="
mapfile -t running < <(docker compose ps --status running --services 2>/dev/null || true)
need=(nginx grafana loki tempo prometheus alloy)
for s in "${need[@]}"; do
  printf '%s\n' "${running[@]}" | grep -qx "$s" && ok "$s up" || fail "$s not running"
done

echo "== edge =="
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/" || true)"
[[ "$code" == "200" ]] && ok "Grafana $BASE/ ($code)" || fail "Grafana $BASE/ ($code)"

code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/nginx-health" || true)"
[[ "$code" == "200" ]] && ok "nginx-health" || fail "nginx-health ($code)"

echo "== backends via nginx =="
code="$(curl -s -o /dev/null -w '%{http_code}' -u "$NGX_USER:$NGX_PASS" "$BASE/loki/ready" || true)"
[[ "$code" == "200" ]] && ok "Loki /ready" || fail "Loki /ready ($code)"

code="$(curl -s -o /dev/null -w '%{http_code}' -u "$NGX_USER:$NGX_PASS" "$BASE/tempo/ready" || true)"
[[ "$code" == "200" ]] && ok "Tempo /ready" || fail "Tempo /ready ($code)"

code="$(curl -s -o /dev/null -w '%{http_code}' -u "$NGX_USER:$NGX_PASS" "$BASE/prometheus/-/ready" || true)"
[[ "$code" == "200" ]] && ok "Prometheus /-/ready" || fail "Prometheus /-/ready ($code)"

echo "== OTLP =="
otlp="$(curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' -d '{}' || echo 000)"
[[ "$otlp" != "000" ]] && ok "OTLP HTTP :4318 (http $otlp)" || fail "OTLP HTTP :4318 unreachable"

echo "== Grafana datasources =="
ds="$(curl -s -u "$AUTH_USER:$AUTH_PASS" "$BASE/api/datasources" || true)"
echo "$ds" | grep -q '"uid":"loki"' && ok "datasource Loki" || fail "datasource Loki"
echo "$ds" | grep -q '"uid":"tempo"' && ok "datasource Tempo" || fail "datasource Tempo"
echo "$ds" | grep -q '"uid":"prometheus"' && ok "datasource Prometheus" || fail "datasource Prometheus"

echo "== mate pipeline =="
if printf '%s\n' "${running[@]}" | grep -qx mate; then
  curl -sf "http://localhost:4000/health" >/dev/null && ok "mate /health" || fail "mate /health"
  curl -s "http://localhost:4000/cebada?gusto=amargo" >/dev/null || true
  sleep 10

  now_ns="$(date +%s)000000000"
  start_ns="$(( $(date +%s) - 600 ))000000000"
  q_enc="$(python3 -c 'import urllib.parse; print(urllib.parse.quote("{service_name=\"mate\"}"))')"
  logs="$(curl -s -u "$AUTH_USER:$AUTH_PASS" \
    "$BASE/api/datasources/proxy/uid/loki/loki/api/v1/query_range?query=${q_enc}&start=${start_ns}&end=${now_ns}&limit=20" || true)"
  if echo "$logs" | grep -Eq 'mate|cebada|cebando|vuelco'; then
    ok "Loki ← logs mate"
  else
    q2="$(python3 -c 'import urllib.parse; print(urllib.parse.quote("{job=\"docker\"}"))')"
    logs2="$(curl -s -u "$AUTH_USER:$AUTH_PASS" \
      "$BASE/api/datasources/proxy/uid/loki/loki/api/v1/query_range?query=${q2}&start=${start_ns}&end=${now_ns}&limit=50" || true)"
    echo "$logs2" | grep -q 'mate' && ok "Loki ← logs mate (via job=docker)" || fail "Loki sin logs mate"
  fi

  met="$(curl -s -u "$AUTH_USER:$AUTH_PASS" --get \
    --data-urlencode 'query=mate_cebadas_total' \
    "$BASE/api/datasources/proxy/uid/prometheus/api/v1/query" || true)"
  echo "$met" | grep -q '"value"' && ok "Prometheus ← mate_cebadas_total" || fail "Prometheus sin mate_cebadas_total"

  tr="$(curl -s -u "$AUTH_USER:$AUTH_PASS" --get \
    --data-urlencode 'q={ resource.service.name="mate" }' \
    --data-urlencode "start=$(( $(date +%s) - 600 ))" \
    --data-urlencode "end=$(date +%s)" \
    "$BASE/api/datasources/proxy/uid/tempo/api/search" || true)"
  echo "$tr" | grep -q 'traceID\|traceId' && ok "Tempo ← traces mate" || fail "Tempo sin traces mate (aún)"
else
  ok "mate down — skip pipeline (docker compose --profile mate up -d --build)"
fi

echo
if [[ "$FAIL" -ne 0 ]]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: OK — listo para entregar / jugar"
