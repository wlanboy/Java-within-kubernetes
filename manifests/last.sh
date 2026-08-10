#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-demo}"
SERVICE="${SERVICE:-hello-world}"
LOCAL_PORT="${LOCAL_PORT:-8080}"
REQUESTS="${REQUESTS:-2000}"
CONCURRENCY="${CONCURRENCY:-50}"
IDEMPOTENCY_KEY="${IDEMPOTENCY_KEY:-load-test}"

HOST="http://localhost:${LOCAL_PORT}"

# Port-Forward nur aufbauen, wenn unter LOCAL_PORT noch nichts erreichbar ist
# (z.B. weil bereits manuell ein eigener Forward laeuft)
FORWARD_PID=""
if ! curl -s -o /dev/null "${HOST}/actuator/health"; then
  echo "=== Starte Port-Forward zu svc/${SERVICE} (Namespace ${NAMESPACE}) auf Port ${LOCAL_PORT} ==="
  kubectl port-forward -n "${NAMESPACE}" "svc/${SERVICE}" "${LOCAL_PORT}:80" >/dev/null 2>&1 &
  FORWARD_PID=$!
  trap '[[ -n "${FORWARD_PID}" ]] && kill "${FORWARD_PID}" 2>/dev/null' EXIT

  for _ in $(seq 1 20); do
    curl -s -o /dev/null "${HOST}/actuator/health" && break
    sleep 0.5
  done
fi

run_hey() {
  local label="$1" path="$2"
  echo
  echo "=== ${label}: ${HOST}${path} ==="
  hey -n "${REQUESTS}" -c "${CONCURRENCY}" "${HOST}${path}"
}

run_hey "Dienst"             "/hello"
run_hey "Dienst (Idempotenz)" "/cpu?key=${IDEMPOTENCY_KEY}"
run_hey "Actuator Health"    "/actuator/health"
run_hey "Prometheus Metrics" "/actuator/prometheus"
