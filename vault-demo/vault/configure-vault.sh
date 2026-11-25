#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${VAULT_NAMESPACE:-vault}"
APP_NAMESPACE="${APP_NAMESPACE:-demo}"
VAULT_POD="${VAULT_POD:-vault-0}"
POLICY_FILE="vault-demo/vault/policies/demo-app-policy.hcl"

command -v kubectl >/dev/null
test -f "$POLICY_FILE"

echo "Waiting for Vault pod..."
kubectl wait --for=condition=Ready pod/"$VAULT_POD" -n "$NAMESPACE" --timeout=180s

# Copy the least-privilege policy into the Vault pod.
kubectl cp "$POLICY_FILE" "$NAMESPACE/$VAULT_POD:/tmp/demo-app-policy.hcl"

kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- sh -ec '
  export VAULT_ADDR=http://127.0.0.1:8200
  export VAULT_TOKEN=root

  vault secrets enable -path=secret kv-v2 2>/dev/null || true

  vault kv put secret/demo/database \
    username="demo-user" \
    password="demo-password-change-me"

  vault policy write demo-app-policy /tmp/demo-app-policy.hcl

  vault auth enable kubernetes 2>/dev/null || true

  # In this local K3d lab, Vault runs inside the same Kubernetes cluster.
  # The service-account token and CA mounted in the Vault Pod are used
  # to configure Kubernetes authentication.
  TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
  CA_CERT="$(cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)"
  K8S_HOST="https://kubernetes.default.svc:443"

  vault write auth/kubernetes/config \
    token_reviewer_jwt="$TOKEN" \
    kubernetes_host="$K8S_HOST" \
    kubernetes_ca_cert="$CA_CERT"

  vault write auth/kubernetes/role/demo-app \
    bound_service_account_names=demo-app-sa \
    bound_service_account_namespaces='"$APP_NAMESPACE"' \
    policies=demo-app-policy \
    ttl=1h

  echo "Vault KV, policy and Kubernetes auth role configured."
'

echo "Vault configuration completed."
echo "Demo secret path: secret/data/demo/database"
