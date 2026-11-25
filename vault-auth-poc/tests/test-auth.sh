#!/usr/bin/env bash
set -euo pipefail
BASE=${BASE:-http://localhost:18080}
POD=$(kubectl get pod -n demo -l app=vault-auth-demo -o jsonpath='{.items[0].metadata.name}')
echo "1) Valid database authentication via app (agent mode)"
curl -fsS "$BASE/db/check"; echo
echo "2) Obtain a dynamic Vault DB lease directly (for expiry/revocation test)"
LEASE_JSON=$(kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault read -format=json database/creds/app-role)
LEASE_ID=$(printf '%s' "$LEASE_JSON" | jq -r '.lease_id')
DB_USER=$(printf '%s' "$LEASE_JSON" | jq -r '.data.username')
DB_PASS=$(printf '%s' "$LEASE_JSON" | jq -r '.data.password')
echo "Lease: $LEASE_ID (user $DB_USER)"
echo "3) Verify the generated credential is accepted by PostgreSQL"
kubectl exec -n demo postgres-0 -- env PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d appdb -c 'select current_user;'
echo "4) Revoke the lease, then verify that new DB authentication fails"
kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault lease revoke "$LEASE_ID"
if kubectl exec -n demo postgres-0 -- env PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d appdb -c 'select 1' >/dev/null 2>&1; then
  echo "ERROR: revoked credentials still authenticate"; exit 1
else
  echo "PASS: revoked credentials rejected by PostgreSQL"
fi
echo "5) JWT valid/invalid/expired tests"
python3 - <<'PY'
import json, subprocess, time, urllib.request, urllib.error, base64, hmac, hashlib
# The signing key is deliberately read from the local Vault lab for this test.
raw=subprocess.check_output(["kubectl","exec","-n","vault","vault-0","--","env","VAULT_ADDR=http://127.0.0.1:8200","VAULT_TOKEN=root","vault","kv","get","-format=json","secret/jwt"])
key=json.loads(raw)["data"]["data"]["signing_key"]
def b64(x): return base64.urlsafe_b64encode(x).rstrip(b"=").decode()
def token(exp):
  h=b64(b'{"alg":"HS256","typ":"JWT"}'); p=b64(json.dumps({"sub":"poc-user","aud":"vault-auth-demo","iss":"vault-auth-poc","exp":exp}).encode())
  sig=b64(hmac.new(key.encode(),f"{h}.{p}".encode(),hashlib.sha256).digest())
  return f"{h}.{p}.{sig}"
def call(t, expect):
  req=urllib.request.Request("http://localhost:18080/jwt/verify",data=b"",headers={"Authorization":"Bearer "+t},method="POST")
  try: r=urllib.request.urlopen(req); code=r.status
  except urllib.error.HTTPError as e: code=e.code
  assert code==expect, (code,expect)
  print("PASS JWT expected",expect)
call(token(int(time.time())+60),200)
call(token(int(time.time())+60)+"x",401)
call(token(int(time.time())-10),401)
PY
echo "6) mTLS: valid client cert succeeds; no client cert must fail"
kubectl port-forward -n demo svc/vault-auth-demo 18443:8443 >/tmp/vault-auth-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 3
kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault write -format=json pki/issue/vault-auth-demo common_name=poc-client > /tmp/poc-client.json
jq -r '.data.certificate' /tmp/poc-client.json >/tmp/poc-client.crt
jq -r '.data.private_key' /tmp/poc-client.json >/tmp/poc-client.key
kubectl exec -n vault vault-0 -- cat /tmp/vault-auth-ca.crt >/tmp/poc-ca.crt
curl -fsS --cacert /tmp/poc-ca.crt --cert /tmp/poc-client.crt --key /tmp/poc-client.key https://localhost:18443/mtls
echo
if curl -sk https://localhost:18443/mtls >/dev/null 2>&1; then echo "ERROR: no-client-cert unexpectedly accepted"; exit 1; else echo "PASS: no client certificate rejected"; fi
