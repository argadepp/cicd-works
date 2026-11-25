#!/usr/bin/env bash
set -euo pipefail
NS_VAULT=vault
NS_APP=demo
VAULT_POD=${VAULT_POD:-vault-0}
ROOT_TOKEN=${VAULT_TOKEN:-root}
kubectl exec -i -n "$NS_VAULT" "$VAULT_POD" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$ROOT_TOKEN" sh -s <<'VAULT'
set -e
vault secrets enable -path=secret kv-v2 2>/dev/null || true
vault auth enable kubernetes 2>/dev/null || true
vault policy write vault-auth-demo - <<'POLICY'
path "database/creds/app-role" { capabilities = ["read"] }
path "secret/data/jwt" { capabilities = ["read"] }
path "pki/issue/vault-auth-demo" { capabilities = ["update"] }
POLICY
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
vault write auth/kubernetes/role/vault-auth-demo \
  bound_service_account_names=vault-auth-demo \
  bound_service_account_namespaces=demo \
  audience=vault \
  policies=vault-auth-demo \
  ttl=15m
vault kv put secret/jwt signing_key="local-lab-only-signing-key-please-change"
vault secrets enable database 2>/dev/null || true
vault write database/config/postgres \
  plugin_name=postgresql-database-plugin \
  allowed_roles=app-role \
  connection_url="postgresql://{{username}}:{{password}}@postgres.demo.svc:5432/appdb?sslmode=disable" \
  username=postgres password=postgres-dev-password
vault write database/roles/app-role \
  db_name=postgres \
  creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD ''{{password}}'' VALID UNTIL ''{{expiration}}''; GRANT CONNECT ON DATABASE appdb TO "{{name}}"; GRANT USAGE ON SCHEMA public TO "{{name}}"; GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO "{{name}}";' \
  revocation_statements='DROP ROLE IF EXISTS "{{name}}";' \
  default_ttl=2m max_ttl=5m
vault secrets enable -path=pki pki 2>/dev/null || true
vault secrets tune -max-lease-ttl=8760h pki
vault write -field=certificate pki/root/generate/internal common_name="vault-auth-poc.local" ttl=8760h > /tmp/vault-auth-ca.crt
vault write pki/roles/vault-auth-demo \
  allowed_domains="vault-auth-poc.local" allow_subdomains=true \
  allow_localhost=true max_ttl=24h key_type=rsa key_bits=2048
VAULT
# Generate a server certificate from Vault PKI, then mount it into the demo Pod.
CERT_JSON=$(kubectl exec -n "$NS_VAULT" "$VAULT_POD" -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$ROOT_TOKEN" vault write -format=json pki/issue/vault-auth-demo common_name=localhost alt_names=vault-auth-demo.demo.svc)
CA=$(kubectl exec -n "$NS_VAULT" "$VAULT_POD" -- cat /tmp/vault-auth-ca.crt)
CERT=$(printf '%s' "$CERT_JSON" | jq -r '.data.certificate')
KEY=$(printf '%s' "$CERT_JSON" | jq -r '.data.private_key')
kubectl create secret generic vault-auth-demo-tls -n "$NS_APP" \
  --from-literal=tls.crt="$CERT" --from-literal=tls.key="$KEY" --from-literal=ca.crt="$CA" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "Vault configured: Kubernetes auth, dynamic PostgreSQL role, JWT key and PKI mTLS certificate."
echo "NOTE: JWT signing key and PostgreSQL admin password are intentionally lab-only values."
