# CI/CD Works

A collection of CI/CD experiments. The existing Python + Dagger image-publishing experiment remains at the repository root. A local Jenkins + Git + Nginx deployment demo is available in `nginx-demo/`.

## Local Jenkins + Nginx demo

### Architecture

```text
GitHub repository
      |
      | Jenkins Pipeline SCM checkout (polling or manual build)
      v
Jenkins container :8080
      |
      | Validate HTML and copy site files
      v
Shared Docker bind mount
      |
      v
Nginx container :8081
      |
      v
http://localhost:8081
```

### Prerequisites

- Docker Engine with the Docker Compose plugin (Docker Desktop is not required).
- Git.
- A GitHub repository clone on your WSL filesystem.

### Start the services

From the repository root:

```bash
cd nginx-demo
mkdir -p deploy
sudo chown -R 1000:1000 deploy
docker compose up -d
docker compose ps
```

Open:
- Jenkins: http://localhost:8080
- Nginx: http://localhost:8081

Retrieve the initial Jenkins administrator password:

```bash
docker exec cicd-demo-jenkins \
  cat /var/jenkins_home/secrets/initialAdminPassword
```

Complete the Jenkins setup wizard and install the suggested plugins. Ensure the **Git** and **Pipeline** plugins are installed.

### Create the Jenkins Pipeline job

1. In Jenkins, select **New Item**.
2. Name it `nginx-local-cicd` and choose **Pipeline**.
3. Under **Pipeline**, select **Pipeline script from SCM**.
4. Set SCM to **Git** and enter this repository's clone URL: `https://github.com/argadepp/cicd-works.git`.
5. Set the branch to `*/master` (or the branch you are using).
6. Set Script Path to `nginx-demo/Jenkinsfile`.
7. Save and select **Build Now**.

The Jenkinsfile checks out the repository, verifies the demo HTML file, and copies only `nginx-demo/site/` into the shared Nginx document root.

### Test a deployment

1. Edit `nginx-demo/site/index.html` and change the release value, for example `1.0.0` to `1.0.1`.
2. Commit and push the change.
3. Run the Jenkins job (or enable **Poll SCM** with schedule `H/1 * * * *` to detect changes approximately once a minute).
4. Refresh http://localhost:8081 and confirm the new release is visible.

### Stop the demo

From `nginx-demo/`:

```bash
docker compose down
```

To also remove Jenkins configuration and build history:

```bash
docker compose down -v
```

**Warning:** `down -v` permanently deletes the Jenkins home volume, including its jobs, plugins, credentials and build history.

### Notes

- Port `8080` is Jenkins; port `8081` is the Nginx website. Change the host-side port mappings if they are already in use.
- Jenkins is intentionally not given access to the Docker socket. The pipeline only copies static files into a bind-mounted directory.
- Poll SCM avoids exposing a local Jenkins instance to the public internet. A GitHub webhook requires a reachable Jenkins endpoint and should be configured through a secured tunnel or reverse proxy with appropriate access controls.
- This is a learning lab, not a production-hardened Jenkins deployment. Keep Jenkins access restricted to your local machine or trusted network.
