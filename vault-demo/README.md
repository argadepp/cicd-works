# HashiCorp Vault + Kubernetes Application POC

A local, end-to-end HashiCorp Vault integration lab for the existing CI/CD Works repository. It runs K3d/K3s, Vault, Vault Agent Injector, a Python FastAPI application, and Traefik Ingress.

The application obtains a database username/password from Vault through Kubernetes authentication. The credentials are rendered to a file in the application Pod by the Vault Agent Injector. The application never contains the secret in its image or Deployment manifest.

> **Lab warning:** The default Vault Helm values below enable Vault development mode with a predictable root token. This is for an isolated local POC only. Do not expose it to an untrusted network or reuse these settings in production.

## Architecture

```text
Browser / curl
    |
    +--> http://vault.local:8080 --> Traefik --> Vault UI service --> Vault Pod
    |
    +--> http://app.local:8080   --> Traefik --> app-service --> FastAPI Pod
                                                   |
                                                   | reads /vault/secrets/db-creds
                                                   v
                                              Vault Agent
                                                   |
                         Kubernetes ServiceAccount JWT authentication
                                                   |
                                                   v
                                              Vault service
                                                   |
                                         KV v2 secret + policy
```

## Repository contents

- `app/`: FastAPI application and Dockerfile.
- `k8s/`: application namespace, ServiceAccount, Deployment, Service and both Ingress manifests.
- `vault/`: local Helm values, KV policy and Vault setup script.
- `.github/workflows/vault-demo-image.yml`: builds the application image and publishes it to GHCR.

Vault itself uses the official HashiCorp Helm chart and image. Only the sample FastAPI application is built and published by this workflow.

## Prerequisites

- Docker Engine (Docker Desktop is not required).
- K3d, kubectl and Helm.
- Git and access to this repository.
- Host port 8080 available.
- A GitHub account with GitHub Packages enabled to publish the application image.

Examples below are for Linux/WSL shell. Run them from the repository root unless specified.

## 1. Create a dedicated K3d cluster

If you already have a suitable K3d cluster, you can use it and skip cluster creation. Otherwise:

```bash
k3d cluster create vault-poc \
  --servers 1 \
  --agents 1 \
  -p "8080:80@loadbalancer"
kubectl config use-context k3d-vault-poc
kubectl get nodes
```

K3s includes Traefik by default. Confirm it is running:

```bash
kubectl get pods -n kube-system
kubectl get svc -n kube-system traefik
```

## 2. Install Vault and the Injector

Add the official HashiCorp chart repository:

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
kubectl create namespace vault
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --values vault-demo/vault/values-dev.yaml \
  --wait --timeout 5m
```

Check the server and injector:

```bash
kubectl get pods -n vault
kubectl get svc -n vault
```

The official chart enables the server auth-delegator binding by default, which grants the Vault server ServiceAccount the permission needed for Kubernetes token reviews. The chart-created Vault ServiceAccount is used by the Vault Pod. See the chart documentation linked below.

The demo values enable Vault dev mode, UI and Injector. Dev mode starts an unsealed in-memory Vault using root token `root`. Data is lost if the Vault Pod is recreated. This is only for this isolated lab.

## 3. Configure local hostnames and Ingress

Add these entries to your hosts file:

Linux/WSL: `/etc/hosts`  
Windows: `C:\\Windows\\System32\\drivers\\etc\\hosts`

```text
127.0.0.1 vault.local
127.0.0.1 app.local
```

Apply the Vault UI Ingress now:

```bash
kubectl apply -f vault-demo/k8s/vault-ingress.yaml
```

Open:

- Vault UI: http://vault.local:8080
- Application: http://app.local:8080 (after the application is deployed)

For direct Vault access without Ingress:

```bash
kubectl port-forward -n vault svc/vault-ui 8200:8200
```

Then browse to http://localhost:8200. Login with token `root`.

## 4. Configure Vault secrets, policy and Kubernetes auth

The setup script enables KV v2, creates a demo database credential, creates a read-only policy, enables Kubernetes auth, configures the Kubernetes API connection and binds the policy to the application's ServiceAccount.

Run from the repository root:

```bash
chmod +x vault-demo/vault/configure-vault.sh
./vault-demo/vault/configure-vault.sh
```

The script reads the Kubernetes ServiceAccount token and CA from the Vault Pod's mounted ServiceAccount files. It does not put the Vault root token in an application manifest.

The demo secret is deliberately fake:

- Username: `demo-user`
- Password: `demo-password-change-me`

The policy permits read access only to `secret/data/demo/database`.

## 5. Build and publish the application image to GHCR

The GitHub Actions workflow builds this folder's Dockerfile and publishes:

```text
ghcr.io/<github-owner>/vault-demo-app:<git-sha>
ghcr.io/<github-owner>/vault-demo-app:latest
```

The workflow uses the repository's built-in `GITHUB_TOKEN` and `packages: write` permission. No personal access token is required for the normal workflow.

To trigger it, push a change under `vault-demo/**` to `master`, or open Actions and run **Build and publish Vault demo app** manually. Pull requests run a build without publishing.

After the first successful push, check the package under your GitHub profile's **Packages** tab. Make the package public for this local lab, or configure an imagePullSecret in namespace `demo` if the package is private.

For a local build instead:

```bash
docker build -t vault-demo-app:local vault-demo/app
k3d image import vault-demo-app:local -c vault-poc
```

If using a different cluster name, change `vault-poc` accordingly.

## 6. Deploy the application

For GHCR, edit `vault-demo/k8s/deployment.yaml` and replace the example image with the published image tag. For local image use, set `image: vault-demo-app:local` and `imagePullPolicy: IfNotPresent`.

Apply:

```bash
kubectl apply -f vault-demo/k8s/namespace.yaml
kubectl apply -f vault-demo/k8s/serviceaccount.yaml
kubectl apply -f vault-demo/k8s/deployment.yaml
kubectl apply -f vault-demo/k8s/service.yaml
kubectl apply -f vault-demo/k8s/ingress.yaml
kubectl rollout status deployment/vault-demo-app -n demo
kubectl get pods,svc,ingress -n demo
```

The Deployment annotation `vault.hashicorp.com/agent-inject: "true"` enables the Injector. Other annotations specify the Vault role and template to write to `/vault/secrets/db-creds`.

## 7. Test secret consumption

Open http://app.local:8080 or run:

```bash
curl http://app.local:8080/
curl http://app.local:8080/health
curl http://app.local:8080/secret-status
```

The application reports the secret username and whether a password was loaded, but **never returns the password**.

Inspect the injected file from the application Pod:

```bash
POD=$(kubectl get pod -n demo -l app=vault-demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n demo "$POD" -c app -- cat /vault/secrets/db-creds
```

The Pod normally has an application container and a Vault Agent sidecar. Check:

```bash
kubectl describe pod -n demo "$POD"
kubectl logs -n demo "$POD" -c vault-agent
kubectl logs -n demo "$POD" -c app
```

## 8. Rotate the demo secret

Update the secret in Vault:

```bash
kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
  vault kv put secret/demo/database username=demo-user-v2 password=demo-password-v2
```

The Vault Agent template periodically re-renders the file. Wait for its refresh interval, then inspect the injected file again. The application reads the file on each `/secret-status` request, so it can observe the updated username without rebuilding the image or restarting the Pod.

## 9. Troubleshooting

```bash
kubectl get pods -A
kubectl get events -n vault --sort-by=.lastTimestamp
kubectl get events -n demo --sort-by=.lastTimestamp
kubectl logs -n vault vault-0
kubectl logs -n vault deploy/vault-agent-injector
kubectl describe pod -n demo -l app=vault-demo-app
```

Common causes:

- Injector webhook unavailable: ensure the injector Pod and Service are ready.
- Vault auth failure: validate Kubernetes auth configuration, ServiceAccount token, role namespace/name and policy.
- Secret file missing: inspect Vault Agent logs and Pod annotations.
- ImagePullBackOff: check image name/tag and package visibility or imagePullSecret.
- Ingress not reachable: check Traefik, K3d port mapping, hosts file and host port 8080.

## 10. Clean up

Remove application resources and Vault UI Ingress:

```bash
kubectl delete -f vault-demo/k8s/ingress.yaml --ignore-not-found
kubectl delete -f vault-demo/k8s/vault-ingress.yaml --ignore-not-found
kubectl delete -f vault-demo/k8s/service.yaml --ignore-not-found
kubectl delete -f vault-demo/k8s/deployment.yaml --ignore-not-found
kubectl delete -f vault-demo/k8s/serviceaccount.yaml --ignore-not-found
kubectl delete namespace demo
```

Remove Vault:

```bash
helm uninstall vault -n vault
kubectl delete namespace vault
```

Delete the cluster only if it was created exclusively for this lab:

```bash
k3d cluster delete vault-poc
```

## Security notes and next steps

This POC intentionally uses Vault dev mode, HTTP inside an isolated local cluster, and a demo credential. It is not production-ready.

For a production-style follow-up:

1. Replace dev mode with a persistent Vault deployment using integrated Raft storage, persistent volumes, TLS, proper initialization/unseal procedures and backups.
2. Configure TLS for Vault and the application Ingress.
3. Use a restricted Vault policy and separate role per application/namespace.
4. Use short-lived projected ServiceAccount tokens and verify Kubernetes auth issuer/audience settings for your cluster.
5. Avoid exposing Vault UI publicly; restrict it to trusted operators.
6. Use GHCR package access controls and immutable image digests.
7. Add secret rotation, audit devices and monitoring.

## References

- [Vault Helm chart](https://github.com/hashicorp/vault-helm)
- [Vault Kubernetes auth method](https://developer.hashicorp.com/vault/docs/auth/kubernetes)
- [Vault Agent Injector](https://developer.hashicorp.com/vault/docs/platform/k8s/injector)
- [K3d](https://k3d.io/)
