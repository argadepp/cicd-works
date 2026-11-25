# Vault Authentication POC: PostgreSQL + JWT + PKI mTLS

This lab extends the repository's original `vault-demo/` secret-injection exercise. It demonstrates three real authentication flows using HashiCorp Vault on the existing local K3d/K3s cluster:

1. **Dynamic PostgreSQL credentials**: Vault creates a short-lived PostgreSQL role and password, the application authenticates to PostgreSQL, and Vault revokes or expires the database identity.
2. **JWT verification**: the application retrieves its HMAC signing key from Vault and verifies signature, issuer, audience and expiry.
3. **PKI mutual TLS**: Vault's PKI engine issues the server and client certificates; the HTTPS listener requires a trusted client certificate.

Both Vault authentication integrations are included:
- **Vault Agent Injector**: sidecar authenticates with the Pod ServiceAccount and renders dynamic DB credentials and the JWT key into files.
- **Direct application SDK**: the FastAPI app uses `hvac` to exchange its Kubernetes ServiceAccount JWT for a Vault token and reads/generates secrets through Vault APIs.

> **Local-lab warning:** the chart uses Vault dev mode, predictable root token, HTTP inside the cluster, and demo PostgreSQL credentials. Do not expose this lab to an untrusted network or reuse its credentials in production.

## Architecture

```text
K3d / K3s
├── vault namespace
│   ├── Vault dev server + UI
│   └── Vault Agent Injector webhook
└── demo namespace
    ├── PostgreSQL StatefulSet
    └── FastAPI app (ServiceAccount: vault-auth-demo)
        ├── Agent mode: injected DB lease + JWT signing key
        ├── SDK mode: Kubernetes JWT -> Vault Kubernetes auth -> Vault APIs
        └── HTTPS :8443 requires Vault-PKI client certificate

Vault engines:
- database/creds/app-role -> ephemeral PostgreSQL user/password, 2m default lease
- secret/data/jwt -> JWT HS256 signing key
- pki/issue/vault-auth-demo -> server/client certificates
```

## Files

- `app/`: FastAPI app, Dockerfile and dependencies.
- `k8s/namespace.yaml`: demo namespace.
- `k8s/postgres.yaml`: PostgreSQL StatefulSet, service and lab admin Secret.
- `k8s/app.yaml`: ServiceAccount, Injector annotations, app Deployment and Service.
- `vault/values-dev.yaml`: Vault Helm values for local dev.
- `vault/configure-vault.sh`: enables/configures Kubernetes auth, database, KV and PKI engines; creates TLS Secret.
- `tests/test-auth.sh`: database authentication, lease expiry, revocation, JWT and mTLS negative/positive tests.
- `tests/test-sdk-mode.sh`: switches the app to direct SDK auth and tests DB authentication.
- `.github/workflows/vault-auth-poc.yml`: builds and publishes the app image to GHCR.

## Prerequisites

- Existing K3d cluster with K3s Traefik; Docker Engine, `kubectl`, `helm`, `jq`, `curl`, Python 3 and Git.
- The K3d load balancer maps host port 8080 to Traefik port 80 (same convention as `vault-demo`).
- A running cluster context you intend to use. This guide does **not** create or delete your cluster.
- Host port 18080 and 18443 free for test port-forwards.

Check cluster:
```bash
kubectl config current-context
kubectl get nodes
kubectl get pods -n kube-system
```

## 1. Install Vault and deploy PostgreSQL

From repository root:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f vault-auth-poc/k8s/namespace.yaml
helm upgrade --install vault hashicorp/vault -n vault \
  -f vault-auth-poc/vault/values-dev.yaml --wait --timeout 5m
kubectl apply -f vault-auth-poc/k8s/postgres.yaml
kubectl rollout status statefulset/postgres -n demo --timeout=180s
kubectl get pods -n vault
kubectl get pods -n demo
```

Vault UI (optional):
```bash
kubectl port-forward -n vault svc/vault-ui 8200:8200
```
Open `http://localhost:8200`, choose Token auth and enter `root`.

## 2. Configure Vault

The configuration script needs `jq` locally. It uses the Vault Pod's Kubernetes ServiceAccount token to configure Kubernetes auth, creates a least-privilege policy/role, configures PostgreSQL dynamic credentials with a 2-minute default lease, stores a JWT signing key in KV v2, configures PKI, issues a server certificate, and creates the Kubernetes TLS Secret.

```bash
chmod +x vault-auth-poc/vault/configure-vault.sh
./vault-auth-poc/vault/configure-vault.sh
```

If your Vault Pod is not named `vault-0`, set `VAULT_POD`. If you changed the dev root token, set `VAULT_TOKEN`.

The PostgreSQL admin password and JWT signing key in this lab are intentionally static demo values. Vault dynamically creates the **application** database identities; the app does not use the PostgreSQL admin account.

## 3. Build and publish the app image

The GitHub Actions workflow publishes:
`ghcr.io/argadepp/vault-auth-demo:<git-sha>` and `ghcr.io/argadepp/vault-auth-demo:latest`.

Merge the PR, then push a change under `vault-auth-poc/**` to `master`, or manually run **Build and publish Vault authentication POC** from Actions. The workflow uses `GITHUB_TOKEN` with `packages: write`. Make the package public for this local lab or configure an imagePullSecret.

For local build without GHCR:
```bash
docker build -t vault-auth-demo:local vault-auth-poc/app
k3d image import vault-auth-demo:local -c <your-k3d-cluster-name>
```
If using a local image, edit `vault-auth-poc/k8s/app.yaml` to set `image: vault-auth-demo:local` and `imagePullPolicy: IfNotPresent`.

## 4. Deploy the application

```bash
kubectl apply -f vault-auth-poc/k8s/app.yaml
kubectl rollout status deployment/vault-auth-demo -n demo --timeout=180s
kubectl get pods -n demo
```

The default mode is `agent`. The injector authenticates using the Pod ServiceAccount and renders:
- `/vault/secrets/db-creds`: generated PostgreSQL username/password plus lease metadata.
- `/vault/secrets/jwt-key`: KV v2 response containing the signing key.

Test HTTP:
```bash
kubectl port-forward -n demo svc/vault-auth-demo 18080:8080
# In another terminal:
curl -sS http://localhost:18080/
curl -sS http://localhost:18080/db/check
```

## 5. Run the full authentication tests

Keep the HTTP port-forward above running. From another terminal:

```bash
chmod +x vault-auth-poc/tests/*.sh
./vault-auth-poc/tests/test-auth.sh
```

The script performs:
- Valid DB login using a Vault-generated username/password.
- **Lease expiry**: obtains a 2-minute lease, waits past its TTL, and confirms PostgreSQL rejects the expired username/password.
- **Explicit revocation**: obtains a second lease, revokes its Vault lease ID, and confirms PostgreSQL rejects new authentication using that credential.
- JWT positive test (valid signature/claims), tampered-signature negative test, and expired-token negative test.
- mTLS positive test with a Vault-issued client certificate and negative test without a client certificate.

Expected results include HTTP 200 for valid JWT and HTTP 401 for invalid/expired JWT; the revoked/expired DB credentials must fail to authenticate; HTTPS must work with the issued client certificate and fail without one.

> The expiry test intentionally waits a little over two minutes. Existing database sessions are not forcibly terminated by a role expiry/revoke; the test opens a **new** connection to verify that new authentication is denied.

## 6. Test direct SDK authentication

The app can instead log in directly to Vault using its mounted Kubernetes ServiceAccount JWT and the `hvac` SDK:

```bash
./vault-auth-poc/tests/test-sdk-mode.sh
```

This switches the Deployment to `VAULT_AUTH_MODE=sdk`, waits for rollout, port-forwards the HTTP Service, and calls `/db/check`. The SDK path requests a fresh dynamic DB credential for each check. To return to Agent mode:

```bash
kubectl set env deployment/vault-auth-demo -n demo VAULT_AUTH_MODE=agent
kubectl rollout status deployment/vault-auth-demo -n demo
```

## 7. Useful inspection commands

```bash
kubectl get pods -n vault
kubectl get pods -n demo
kubectl describe pod -n demo -l app=vault-auth-demo
kubectl logs -n demo deploy/vault-auth-demo -c app
kubectl logs -n demo deploy/vault-auth-demo -c vault-agent
kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault list database/roles
kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault list sys/leases/lookup/database/creds/app-role
```

## Troubleshooting

- **Injector mutation absent**: check injector Pod/webhook readiness and the Vault Agent container logs.
- **Vault login 403**: verify the ServiceAccount name/namespace, auth role, policy and token-review configuration.
- **DB credential generation fails**: confirm PostgreSQL is Ready and Vault's database connection config uses the correct service DNS/password.
- **ImagePullBackOff**: confirm GHCR package visibility and image tag.
- **TLS startup fails**: verify `vault-auth-demo-tls` exists and contains `tls.crt`, `tls.key`, and `ca.crt`.
- **mTLS client rejected**: issue the client certificate from the same PKI mount and use the matching CA file.

## Cleanup

```bash
kubectl delete -f vault-auth-poc/k8s/app.yaml --ignore-not-found
kubectl delete -f vault-auth-poc/k8s/postgres.yaml --ignore-not-found
kubectl delete namespace demo
helm uninstall vault -n vault
kubectl delete namespace vault
```
Only remove Vault if this POC owns the Vault release/namespace. Do not delete your K3d cluster if it hosts other experiments.

## Production hardening (not included)

Use non-dev Vault with persistent integrated Raft storage, TLS, initialization/unseal/backup procedures, audit logging, short-lived projected ServiceAccount tokens with explicit audiences, separate policies per workload, network policies, secret rotation and image digests. Protect the Vault UI and never put root tokens or static admin credentials in Git.
