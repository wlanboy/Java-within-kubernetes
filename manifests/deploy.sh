#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="demo"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n "${NAMESPACE}" -f "${SCRIPT_DIR}/configmap.yaml"
kubectl apply -n "${NAMESPACE}" -f "${SCRIPT_DIR}/deployment.yaml"
kubectl apply -n "${NAMESPACE}" -f "${SCRIPT_DIR}/service.yaml"
kubectl apply -n "${NAMESPACE}" -f "${SCRIPT_DIR}/poddisruptionbudget.yaml"

kubectl rollout status -n "${NAMESPACE}" deployment/hello-world
