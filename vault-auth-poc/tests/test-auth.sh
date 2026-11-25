#!/usr/bin/env bash
set -euo pipefail
BASE=${BASE:-http://localhost:18080}
echo "0) Negative Kubernetes authentication test: an unbound ServiceAccount must be denied"
kubectl create serviceaccount no-vault-access -n demo --dry-run=client -o yaml | kubectl apply -f -
UNBOUND_JWT=$(kubectl create token no-vault-access -n demo --audience=vault --duration=10m)
if kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault write auth/kubernetes/login role=vault-auth-demo jwt="$UNBOUND_JWT" >/dev/null 2>&1; then
  echo "ERROR: unbound ServiceAccount unexpectedly authenticated"; exit 1
else
  echo "PASS: unbound ServiceAccount rejected by Vault Kubernetes auth"
fi
echo "1) Valid database authentication through the app (Agent mode)"
curl -fsS "$BASE/db/check"; echo
echo "2) Obtain a 2-minute dynamic DB lease and prove it works"
LEASE_JSON=$(kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault read -format=json database/creds/app-role)
LEASE_ID=$(printf '%s' "$LEASE_JSON" | jq -r '.lease_id')
DB_USER=$(printf '%s' "$LEASE_JSON" | jq -r '.data.username')
DB_PASS=$(printf '%s' "$LEASE_JSON" | jq -r '.data.password')
LEASE_TTL=$(printf '%s' "$LEASE_JSON" | jq -r '.lease_duration')
echo "Lease $LEASE_ID for $DB_USER; TTL=$LEASE_TTL seconds"
kubectl exec -n demo postgres-0 -- env PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d appdb -c 'select current_user;'
echo "3) Wait for lease expiry, then verify a NEW PostgreSQL login is rejected"
sleep $((LEASE_TTL + 10))
if kubectl exec -n demo postgres-0 -- env PGPASSWORD="$DB_PASS" psql -h 127.0.0.1 -U "$DB_USER" -d appdb -c 'select 1' >/dev/null 2>&1; then
  echo "ERROR: expired credentials still authenticate"; exit 1
else
  echo "PASS: expired credentials rejected by PostgreSQL"
fi
echo "4) Obtain a second lease and explicitly revoke it"
LEASE2=$(kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault read -format=json database/creds/app-role)
LEASE_ID2=$(printf '%s' "$LEASE2" | jq -r '.lease_id')
DB_USER2=$(printf '%s' "$LEASE2" | jq -r '.data.username')
DB_PASS2=$(printf '%s' "$LEASE2" | jq -r '.data.password')
kubectl exec -n demo postgres-0 -- env PGPASSWORD="$DB_PASS2" psql -h 127.0.0.1 -U "$DB_USER2" -d appdb -c 'select current_user;'
kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault lease revoke "$LEASE_ID2"
if kubectl exec -n demo postgres-0 -- env PGPASSWORD="$DB_PASS2" psql -h 127.0.0.1 -U "$DB_USER2" -d appdb -c 'select 1' >/dev/null 2>&1; then
  echo "ERROR: revoked credentials still authenticate"; exit 1
else
  echo "PASS: revoked credentials rejected by PostgreSQL"
fi
echo "5) JWT valid, tampered-signature and expired-token tests"
python3 - <<'PY'
import json, subprocess, time, urllib.request, urllib.error, base64, hmac, hashlib
raw=subprocess.check_output(["kubectl","exec","-n","vault","vault-0","--","env","VAULT_ADDR=http://127.0.0.1:8200","VAULT_TOKEN=root","vault","kv","get","-format=json","secret/jwt"])
key=json.loads(raw)["data"]["data"]["signing_key"]
def b64(x): return base64.urlsafe_b64encode(x).rstrip(b"=").decode()
def token(exp):
  h=b64(b'{"alg":"HS256","typ":"JWT"}'); p=b64(json.dumps({"sub":"poc-user","aud":"vault-auth-demo","iss":"vault-auth-poc","exp":exp}).encode())
  sig=b64(hmac.new(key.encode(),f"{h}.{p}".encode(),hashlib.sha256).digest())
  return f"{h}.{p}.{sig}"
def call(t, expected):
  req=urllib.request.Request("http://localhost:18080/jwt/verify",data=b"",headers={"Authorization":"Bearer "+t},method="POST")
  try: code=urllib.request.urlopen(req).status
  except urllib.error.HTTPError as e: code=e.code
  assert code==expected, (code,expected)
  print("PASS JWT HTTP",expected)
call(token(int(time.time())+60),200)
call(token(int(time.time())+60)+"x",401)
call(token(int(time.time())-10),401)
PY
echo "6) mTLS: trusted client certificate succeeds; missing client certificate fails"
kubectl port-forward -n demo svc/vault-auth-demo 18443:8443 >/tmp/vault-auth-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 3
kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault write -format=json pki/issue/vault-auth-demo common_name=poc-client.vault-auth-poc.local > /tmp/poc-client.json
jq -r '.data.certificate' /tmp/poc-client.json >/tmp/poc-client.crt
jq -r '.data.private_key' /tmp/poc-client.json >/tmp/poc-client.key
kubectl exec -n vault vault-0 -- cat /tmp/vault-auth-ca.crt >/tmp/poc-ca.crt
curl -fsS --cacert /tmp/poc-ca.crt --cert /tmp/poc-client.crt --key /tmp/poc-client.key https://localhost:18443/mtls
echo
if curl -sk https://localhost:18443/mtls >/dev/null 2>&1; then echo "ERROR: no-client-cert unexpectedly accepted"; exit 1; else echo "PASS: no client certificate rejected"; fi
