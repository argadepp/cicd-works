import dagger
import anyio
import os

async def main():
    async with dagger.Connection() as client:
        # Set registry auth using environment
        username = "argadepp"
        password = os.getenv("GHCR_PAT")

        source = client.host().directory(".", exclude=[".git", "__pycache__"])

        ctr = (
            client.container()
            .from_("python:3.11-slim")
            .with_directory("/app", source)
            .with_workdir("/app")
            .with_exec(["pip", "install", "-r", "requirements.txt"])
        )

        # Define image name
        image_ref = f"ghcr.io/{username}/cicd-works:latest"

        # Push image
        await ctr.with_registry_auth("ghcr.io", username, password).publish(image_ref)

if __name__ == "__main__":
    anyio.run(main)
