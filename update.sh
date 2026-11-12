#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

REGISTRY="registry.gmk.lan"

for arg in "$@"; do
  case "$arg" in
    --local) REGISTRY="localhost:5001" ;;  # kind-registry (docker ps: 127.0.0.1:5001->5000)
    *) echo "Unbekannte Option: $arg" >&2; echo "Usage: $0 [--local]" >&2; exit 1 ;;
  esac
done

IMAGE="$REGISTRY/helloworld:latest"
NAMESPACE="default"

echo "==> Baue Image (service/Dockerfile) ..."
docker build --build-context git=.git -t helloworld service/

echo "==> Tagge Image als $IMAGE ..."
docker tag helloworld "$IMAGE"

echo "==> Push Image nach $IMAGE ..."
docker push "$IMAGE"

echo "==> Helm-Upgrade hello-world ..."
helm upgrade --install hello-world ./chart-hpa -n "$NAMESPACE" \
  --set image.repository="${IMAGE%:*}" \
  --set-string image.tag=latest \
  --set image.pullPolicy=Always

echo "==> Rollout-Restart hello-world-hpa ..."
kubectl rollout restart deployment/hello-world-hpa -n "$NAMESPACE"

echo
echo "Fertig."
