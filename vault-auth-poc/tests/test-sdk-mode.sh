#!/usr/bin/env bash
set -euo pipefail
kubectl set env deployment/vault-auth-demo -n demo VAULT_AUTH_MODE=sdk
kubectl rollout status deployment/vault-auth-demo -n demo
kubectl port-forward -n demo svc/vault-auth-demo 18080:8080 >/tmp/vault-auth-sdk-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 3
curl -fsS http://localhost:18080/db/check
echo
curl -fsS http://localhost:18080/health
echo
