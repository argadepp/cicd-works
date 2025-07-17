import dagger
import anyio
import os

# Replace with your GitHub username and repo/image name
GITHUB_USERNAME = "argadepp"
IMAGE_NAME = "cicd-works"
TAG = "latest"
GHCR_PAT = os.getenv("GHCR_PAT")  # Must be set in env or GitHub Actions secrets

async def main():
    async with dagger.Connection() as client:
        # Load current directory into Dagger filesystem (excluding Git files)
        src = client.host().directory(".", exclude=[".git", "__pycache__"])

        # Create container from Python base image
        container = (
            client.container()
            .from_("python:3.11-slim")
            .with_directory("/app", src)
            .with_workdir("/app")
        )

        # Optionally install Python dependencies
        if os.path.exists("requirements.txt"):
            container = container.with_exec(["pip", "install", "-r", "requirements.txt"])

        # Publish image to GHCR
        image_ref = f"ghcr.io/{GITHUB_USERNAME}/{IMAGE_NAME}:{TAG}"
        await container.publish(
            address=image_ref,
            registry_auth=dagger.RegistryAuth(
                address="ghcr.io",
                username=GITHUB_USERNAME,
                password=GHCR_PAT,
            ),
        )

        print(f"✅ Image pushed: {image_ref}")

if __name__ == "__main__":
    anyio.run(main)
