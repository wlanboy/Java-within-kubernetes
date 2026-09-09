#!/usr/bin/env bash
#
# Erzeugt Last gegen hello-world-hpa, um den HorizontalPodAutoscaler zu testen.
# Startet dafuer mehrere kurzlebige Pods im Cluster, die parallele Requests
# schicken, und raeumt sie danach wieder auf.
#
# Geht ueber das istio-ingressgateway (nicht direkt gegen den ClusterIP-Service!),
# weil der HPA seine Custom-Metrik "http_requests_per_second" aus
# istio_requests_total am Gateway bezieht (siehe chart-hpa/templates/hpa.yaml).
# Nur Traffic durchs Gateway zaehlt also fuer das Scaling. Voraussetzung:
# istio/manifests/hello-world-gateway.yaml ist angewendet.
#
# Beispiele:
#   ./lasttest.sh
#   ./lasttest.sh -n default -s hello-world-hpa -e /hello -c 10 -d 300
#
set -euo pipefail

NAMESPACE="default"
SERVICE="hello-world-hpa"
GATEWAY_NAMESPACE="istio-ingress"
GATEWAY_SERVICE="istio-ingressgateway"
GATEWAY_PORT="80"
HOST_HEADER="hello-world.local"
ENDPOINT="/hello"
CONCURRENCY=8
DURATION=180
IMAGE="busybox:1.36"

usage() {
  cat <<EOF
Usage: $0 [-n namespace] [-s service] [-H host-header] [-e endpoint] [-c concurrency] [-d duration-seconds]

  -n  Kubernetes Namespace des App-Service, nur fuer die Existenzpruefung (default: ${NAMESPACE})
  -s  Service-Name des Charts, nur fuer die Existenzpruefung (default: ${SERVICE})
  -H  Host-Header fuers VirtualService-Routing am Gateway (default: ${HOST_HEADER})
  -e  HTTP-Pfad, der belastet wird (default: ${ENDPOINT})
  -c  Anzahl paralleler Load-Generator-Pods (default: ${CONCURRENCY})
  -d  Testdauer in Sekunden (default: ${DURATION})
  -h  Diese Hilfe anzeigen
EOF
  exit 1
}

while getopts "n:s:H:e:c:d:h" opt; do
  case "$opt" in
    n) NAMESPACE="$OPTARG" ;;
    s) SERVICE="$OPTARG" ;;
    H) HOST_HEADER="$OPTARG" ;;
    e) ENDPOINT="$OPTARG" ;;
    c) CONCURRENCY="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl wurde nicht gefunden." >&2
  exit 1
fi

if ! kubectl get svc -n "$NAMESPACE" "$SERVICE" >/dev/null 2>&1; then
  echo "Service '${SERVICE}' in Namespace '${NAMESPACE}' nicht gefunden." >&2
  exit 1
fi

if ! kubectl get svc -n "$GATEWAY_NAMESPACE" "$GATEWAY_SERVICE" >/dev/null 2>&1; then
  echo "Gateway-Service '${GATEWAY_SERVICE}' in Namespace '${GATEWAY_NAMESPACE}' nicht gefunden." >&2
  exit 1
fi

URL="http://${GATEWAY_SERVICE}.${GATEWAY_NAMESPACE}.svc.cluster.local:${GATEWAY_PORT}${ENDPOINT}"
RUN_ID="$(date +%s)"
PODS=()

cleanup() {
  if [ "${#PODS[@]}" -gt 0 ]; then
    echo
    echo "Raeume Load-Generator-Pods auf..."
    kubectl delete pod -n "$NAMESPACE" "${PODS[@]}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

echo "Ziel:          ${URL} (Host: ${HOST_HEADER})"
echo "Namespace:     ${NAMESPACE}"
echo "Parallelitaet: ${CONCURRENCY} Pods"
echo "Dauer:         ${DURATION}s"
echo

# Zaehlt in jedem Load-Generator-Pod die HTTP-Statuscodes mit (2xx/4xx/5xx/sonstige)
# und schreibt alle 20 Requests eine kumulierte Zwischensumme als "STATUS ..."-Zeile
# nach stdout. Nach Testende liest der Hauptscript die jeweils letzte Zeile per
# "kubectl logs" aus und summiert ueber alle Pods (siehe unten).
LOAD_SCRIPT="$(cat <<INNER
c2=0; c4=0; c5=0; co=0; n=0
while true; do
  code=\$(wget -S -q -O /dev/null --header="Host: ${HOST_HEADER}" "${URL}" 2>&1 | awk '/^ *HTTP\// {print \$2; exit}')
  case "\$code" in
    2*) c2=\$((c2+1)) ;;
    4*) c4=\$((c4+1)) ;;
    5*) c5=\$((c5+1)) ;;
    *) co=\$((co+1)) ;;
  esac
  n=\$((n+1))
  if [ \$((n % 5)) -eq 0 ] || [ "\$n" -eq 1 ]; then
    echo "STATUS total=\$n 2xx=\$c2 4xx=\$c4 5xx=\$c5 other=\$co"
  fi
done
INNER
)"

for i in $(seq 1 "$CONCURRENCY"); do
  POD_NAME="load-generator-${RUN_ID}-${i}"
  PODS+=("$POD_NAME")
  kubectl run "$POD_NAME" \
    --namespace "$NAMESPACE" \
    --image="$IMAGE" \
    --restart=Never \
    --command -- /bin/sh -c "$LOAD_SCRIPT" \
    >/dev/null
done

echo "${CONCURRENCY} Load-Generator-Pods gestartet."
echo
echo "Waehrend des Tests in separaten Terminals beobachten:"
echo "  kubectl get hpa -n ${NAMESPACE} ${SERVICE} -w"
echo "  kubectl top pods -n ${NAMESPACE} -l app=${SERVICE}"
echo "  kubectl get pods -n ${NAMESPACE} -l app=${SERVICE} -w"
echo

echo "Last laeuft fuer ${DURATION}s..."
sleep "$DURATION"

echo "Testdauer erreicht, stoppe Last."
echo

echo "Werte Statuscodes aus den Load-Generator-Pods aus..."
total_requests=0
total_2xx=0
total_4xx=0
total_5xx=0
total_other=0
for pod in "${PODS[@]}"; do
  line="$(kubectl logs -n "$NAMESPACE" "$pod" 2>/dev/null | grep '^STATUS ' | tail -1 || true)"
  if [ -z "$line" ]; then
    echo "  ${pod}: keine Statuszeile (Pod hat evtl. noch keine 1 Anfrage abgeschlossen)"
    continue
  fi
  n="$(echo "$line" | sed -n 's/.*total=\([0-9]*\).*/\1/p')"
  c2="$(echo "$line" | sed -n 's/.*2xx=\([0-9]*\).*/\1/p')"
  c4="$(echo "$line" | sed -n 's/.*4xx=\([0-9]*\).*/\1/p')"
  c5="$(echo "$line" | sed -n 's/.*5xx=\([0-9]*\).*/\1/p')"
  co="$(echo "$line" | sed -n 's/.*other=\([0-9]*\).*/\1/p')"
  echo "  ${pod}: ${line#STATUS }"
  total_requests=$((total_requests + ${n:-0}))
  total_2xx=$((total_2xx + ${c2:-0}))
  total_4xx=$((total_4xx + ${c4:-0}))
  total_5xx=$((total_5xx + ${c5:-0}))
  total_other=$((total_other + ${co:-0}))
done

echo
echo "Statuscode-Summe (letzter gemeldeter Zwischenstand je Pod, jeweils alle 5 Requests aktualisiert):"
echo "  Requests gesamt: ${total_requests}"
echo "  2xx:              ${total_2xx}"
echo "  4xx:              ${total_4xx}"
echo "  5xx:              ${total_5xx}"
echo "  sonstige/Fehler:  ${total_other}"
