#!/usr/bin/env bash
#
# Erzeugt Last gegen den hello-world-hpa Service, um den HorizontalPodAutoscaler
# zu testen. Startet dafuer mehrere kurzlebige Pods im Cluster, die den
# Service ueber seinen ClusterIP-DNS-Namen mit parallelen Requests bombardieren
# (Standard-Ansatz aus der Kubernetes-HPA-Dokumentation), und raeumt sie danach
# wieder auf.
#
# Beispiele:
#   ./lasttest.sh
#   ./lasttest.sh -n default -s hello-world-hpa -e /hello -c 10 -d 300
#
set -euo pipefail

NAMESPACE="default"
SERVICE="hello-world-hpa"
PORT="80"
ENDPOINT="/hello"
CONCURRENCY=8
DURATION=180
IMAGE="busybox:1.36"

usage() {
  cat <<EOF
Usage: $0 [-n namespace] [-s service] [-p port] [-e endpoint] [-c concurrency] [-d duration-seconds]

  -n  Kubernetes Namespace (default: ${NAMESPACE})
  -s  Service-Name des Charts (default: ${SERVICE})
  -p  Service-Port (default: ${PORT})
  -e  HTTP-Pfad, der belastet wird (default: ${ENDPOINT})
  -c  Anzahl paralleler Load-Generator-Pods (default: ${CONCURRENCY})
  -d  Testdauer in Sekunden (default: ${DURATION})
  -h  Diese Hilfe anzeigen
EOF
  exit 1
}

while getopts "n:s:p:e:c:d:h" opt; do
  case "$opt" in
    n) NAMESPACE="$OPTARG" ;;
    s) SERVICE="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
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

URL="http://${SERVICE}.${NAMESPACE}.svc.cluster.local:${PORT}${ENDPOINT}"
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

echo "Ziel:          ${URL}"
echo "Namespace:     ${NAMESPACE}"
echo "Parallelitaet: ${CONCURRENCY} Pods"
echo "Dauer:         ${DURATION}s"
echo

for i in $(seq 1 "$CONCURRENCY"); do
  POD_NAME="load-generator-${RUN_ID}-${i}"
  PODS+=("$POD_NAME")
  kubectl run "$POD_NAME" \
    --namespace "$NAMESPACE" \
    --image="$IMAGE" \
    --restart=Never \
    --command -- /bin/sh -c "while true; do wget -q -O- '${URL}' >/dev/null; done" \
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
