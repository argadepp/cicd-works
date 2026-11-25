import os, json, time
from pathlib import Path
from fastapi import FastAPI, HTTPException, Header
import hvac, jwt, psycopg
from jwt import InvalidTokenError

app = FastAPI(title="Vault Authentication POC")
MODE = os.getenv("VAULT_AUTH_MODE", "agent").lower()
VAULT_ADDR = os.getenv("VAULT_ADDR", "http://vault.vault.svc:8200")
VAULT_ROLE = os.getenv("VAULT_ROLE", "vault-auth-demo")
JWT_SECRET_PATH = Path(os.getenv("JWT_SECRET_FILE", "/vault/secrets/jwt-key"))
DB_SECRET_PATH = Path(os.getenv("DB_SECRET_FILE", "/vault/secrets/db-creds"))
PGHOST = os.getenv("PGHOST", "postgres.demo.svc")
PGDATABASE = os.getenv("PGDATABASE", "appdb")
PGSSLMODE = os.getenv("PGSSLMODE", "disable")

def vault_client():
    c = hvac.Client(url=VAULT_ADDR)
    if not c.is_authenticated():
        token_path = "/var/run/secrets/kubernetes.io/serviceaccount/token"
        with open(token_path) as f:
            jwt_token = f.read()
        result = c.auth.kubernetes.login(role=VAULT_ROLE, jwt=jwt_token)
        c.token = result["auth"]["client_token"]
    return c

def read_agent_json(path):
    try:
        return json.loads(path.read_text())
    except Exception as exc:
        raise HTTPException(503, f"Vault Agent secret file unavailable: {exc}")

def db_credentials():
    if MODE == "agent":
        return read_agent_json(DB_SECRET_PATH)
    c = vault_client()
    r = c.secrets.database.generate_credentials(name="app-role")
    return {"username": r["data"]["username"], "password": r["data"]["password"], "lease_id": r["lease_id"], "lease_duration": r["lease_duration"]}

def jwt_key():
    if MODE == "agent":
        data = read_agent_json(JWT_SECRET_PATH)
        return data["data"]["data"]["signing_key"]
    c = vault_client()
    return c.secrets.kv.v2.read_secret_version(path="jwt", mount_point="secret")["data"]["data"]["signing_key"]

@app.get("/")
def root():
    return {"service":"vault-auth-demo", "auth_mode":MODE, "features":["dynamic-postgres","jwt","pki-mtls"]}

@app.get("/health")
def health():
    return {"status":"ok", "auth_mode":MODE}

@app.get("/db/check")
def db_check():
    creds = db_credentials()
    try:
        with psycopg.connect(host=PGHOST, dbname=PGDATABASE, user=creds["username"], password=creds["password"], sslmode=PGSSLMODE, connect_timeout=4) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT current_user, current_database(), now()")
                row = cur.fetchone()
        return {"authenticated":True, "database_user":row[0], "database":row[1], "server_time":str(row[2]), "credential_source":MODE, "lease_duration":creds.get("lease_duration")}
    except Exception as exc:
        raise HTTPException(401, f"PostgreSQL authentication failed: {type(exc).__name__}")

@app.post("/jwt/verify")
def jwt_verify(authorization: str = Header(default="")):
    if not authorization.startswith("Bearer "):
        raise HTTPException(401, "Bearer token required")
    try:
        claims = jwt.decode(authorization[7:], jwt_key(), algorithms=["HS256"], audience="vault-auth-demo", issuer="vault-auth-poc")
        return {"authenticated":True, "subject":claims["sub"], "audience":claims["aud"], "expires_at":claims["exp"]}
    except InvalidTokenError as exc:
        raise HTTPException(401, f"JWT rejected: {type(exc).__name__}")

@app.get("/mtls")
def mtls_probe():
    # This endpoint is served by the TLS listener configured with a client CA.
    return {"mtls":"client certificate accepted"}
