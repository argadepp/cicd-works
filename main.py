import dagger
import anyio

async def main():
    async with dagger.Connection() as client:
        src = client.host().directory(".")

        container = (
            client.container()
            .from_("python:3.11")
            .with_mounted_directory("/app", src)
            .with_workdir("/app")
            .with_exec(["pip", "install", "-r", "requirements.txt"])
            .with_exec(["pytest"])
        )

        await container.exit_code()

if __name__ == "__main__":
    anyio.run(main)
