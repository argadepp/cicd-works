import os
from pathlib import Path

from fastapi import FastAPI, HTTPException

app = FastAPI(title="Vault Secrets Demo", version="1.0.0")

SECRET_FILE = Path(os.getenv("VAULT_SECRET_FILE", "/vault/secrets/db-creds"))


def load_secret() -> dict[str, str]:
    """Read the rendered Vault Agent template; never log secret values."""
    if not SECRET_FILE.is_file():
        raise FileNotFoundError(f"Vault secret file not found: {SECRET_FILE}")

    values: dict[str, str] = {}
    for line in SECRET_FILE.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


@app.get("/")
def root() -> dict[str, str]:
    return {
        "application": "vault-secrets-demo",
        "message": "Application is running. Secret values are never returned.",
        "secret_endpoint": "/secret-status",
    }


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "healthy"}


@app.get("/secret-status")
def secret_status() -> dict[str, object]:
    try:
        secret = load_secret()
    except FileNotFoundError as exc:
        raise HTTPException(status_code=503, detail="Vault secret is not available yet") from exc

    return {
        "secret_loaded": bool(secret.get("username") and secret.get("password")),
        "username": secret.get("username", ""),
        "password_loaded": bool(secret.get("password")),
        "password": "[REDACTED]",
        "source": str(SECRET_FILE),
    }
