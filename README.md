# CI/CD Works

A collection of CI/CD experiments:

- Existing Python + Dagger image-publishing experiment at the repository root.
- Local Jenkins + Git + Nginx deployment demo in `nginx-demo/`.
- HashiCorp Vault + Kubernetes application secret-injection POC in `vault-demo/`.
- End-to-end Vault authentication POC in `vault-auth-poc/` (dynamic PostgreSQL credentials with expiry/revocation, JWT verification, PKI mutual TLS, Vault Agent Injector and direct SDK auth).

## Local Jenkins + Nginx demo

See [nginx-demo/](nginx-demo/) for the Docker Compose setup, Jenkins pipeline, deployment steps and cleanup instructions.

## HashiCorp Vault + Kubernetes application POC

See [vault-demo/README.md](vault-demo/README.md) for a complete local K3d guide. It installs Vault and the Vault Agent Injector through the official Helm chart, configures Kubernetes authentication and a least-privilege KV v2 policy, deploys a FastAPI application that reads an injected secret file, and exposes the Vault UI and application through Traefik Ingress.

The sample FastAPI image is built and published to GitHub Container Registry by [vault-demo-image.yml](.github/workflows/vault-demo-image.yml).

## Vault authentication POC

See [vault-auth-poc/README.md](vault-auth-poc/README.md) for the extended authentication lab. It adds short-lived PostgreSQL credentials, lease expiry and revocation tests, JWT signature/expiry verification, PKI-issued mutual TLS, and both Vault Agent Injector and direct `hvac` SDK integrations. Its image is built by [vault-auth-poc.yml](.github/workflows/vault-auth-poc.yml).

> The Vault demo uses development mode and demo credentials for an isolated local lab only. Follow the README security notes before adapting it for a shared or production environment.

## Existing Dagger experiment

The original repository-root Dagger workflow and Python pipeline remain unchanged.
