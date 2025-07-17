import dagger
import anyio
import os

async def main():
    async with dagger.Connection() as client:
        username = "argadepp"
        password = client.set_secret("ghcr_password", os.getenv("GHCR_TOKEN"))
        
        src = client.host().directory(".", exclude=[".git", ".github"])

        ctr = (
            client.container()
            .from_("python:3.11-slim")
            .with_directory("/app", src)
            .with_workdir("/app")
            .with_exec(["pip", "install", "-r", "requirements.txt"])
        )

        image_ref = f"ghcr.io/{os.getenv('GHCR_USERNAME')}/myapp:latest"

        await ctr.with_registry_auth("ghcr.io", username, password).publish(image_ref)

anyio.run(main)
