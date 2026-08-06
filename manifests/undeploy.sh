#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl delete -n "${NAMESPACE}" -f "${SCRIPT_DIR}/service.yaml" --ignore-not-found
kubectl delete -n "${NAMESPACE}" -f "${SCRIPT_DIR}/deployment.yaml" --ignore-not-found
kubectl delete -n "${NAMESPACE}" -f "${SCRIPT_DIR}/configmap.yaml" --ignore-not-found
