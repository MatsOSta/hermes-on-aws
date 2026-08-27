# AWS identity OpenTofu root

This directory is a separate OpenTofu root module with its own state, independent
of the GitHub governance root in `infrastructure/`.

Authentication comes from the local AWS profile named `platform-lab`, and the
provider operates in `eu-north-1`. Do not store AWS access keys or other
credentials in this directory.

## Hermes agent-host bootstrap

`bootstrap-agent-host.sh` installs and starts the Amazon Linux 2023 Docker
package on the existing Hermes agent host. It is intended to be transferred to
the host and run as root through an AWS Systems Manager Session Manager session:

```sh
sudo bash bootstrap-agent-host.sh
```

The script is safe to run repeatedly: `dnf install` leaves an installed package
in place, and `systemctl enable --now` converges the Docker service to enabled
and active. It also verifies the Docker binary, service, and daemon before
reporting the installed version, service state, and machine architecture.

No interactive user, including `ssm-user`, is added to the `docker` group.
Docker group membership is effectively root-level access and should not be
granted as a bootstrap convenience. Hermes deployment, its service identity,
and sandbox isolation are separate later stages.

## Hermes setup

`setup-hermes.sh` runs the official Hermes setup wizard interactively in a
temporary container. Run it as root on the agent host through an AWS Systems
Manager Session Manager session:

```sh
sudo bash setup-hermes.sh
```

The script pins the immutable image
`nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e`
so reviewed setup executions cannot silently change when a mutable image tag is
updated. It invokes the wizard with:

```sh
docker run --rm -it \
  --volume /var/lib/hermes:/opt/data \
  nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e \
  setup
```

In the currently pinned image, the Hermes Blank Slate preset still enables the
`terminal`, `file`, `vision`, and `skills` CLI toolsets. After the setup wizard
exits successfully, the wrapper therefore explicitly enforces the tested
model-only baseline with a second temporary container:

```sh
docker run --rm \
  --volume /var/lib/hermes:/opt/data \
  nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e \
  hermes tools disable terminal file vision skills --platform cli
```

No tool is enabled by the wrapper. Tool and sandbox capabilities will be
enabled deliberately in a later security stage rather than inherited from the
preset.

Hermes configuration, credentials, and state written to `/opt/data` persist on
the host in `/var/lib/hermes`. Treat that host directory as sensitive: do not
print, copy into the repository, or expose its contents. The script creates it
with restrictive permissions and does not impose a host UID or GID ownership
scheme on Hermes.

Only the Hermes data directory is mounted. The Docker socket and host repository
are not mounted, no ports are published, and host networking or extra container
privileges are not enabled.

## Telegram main-agent gateway

Telegram is the first interface for the Hermes main agent. Configure it
interactively after the base Hermes setup:

```sh
sudo bash setup-hermes-gateway.sh
```

The gateway setup wrapper uses the same pinned image and persistent data mount
to run `hermes setup gateway`. Telegram bot credentials, the allowed Telegram
user ID, and the home-channel configuration remain only in `/var/lib/hermes`;
they are not stored in this repository or printed by the wrapper.
Reconfiguration requires the persistent `hermes-gateway` container to be
stopped explicitly first; the setup wrapper refuses to modify the shared data
while that container is running and never stops it automatically.

In the tested Telegram tool baseline, `vision` is the only enabled main-agent
capability. The wrapper does not enable it or any other tool. After interactive
setup succeeds, it explicitly disables `terminal`, `file`, and `skills` for the
Telegram platform. Those capabilities remain disabled until a deliberate
execution sandbox architecture exists.

Start the persistent gateway with:

```sh
sudo bash run-hermes-gateway.sh
```

For a new container, the runtime wrapper executes:

```sh
docker run -d \
  --name hermes-gateway \
  --restart unless-stopped \
  --volume /var/lib/hermes:/opt/data \
  nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e \
  hermes gateway run
```

The Docker restart policy restores the container after daemon or host restarts,
while Hermes' included s6 supervision manages the gateway process inside the
container. No inbound ports are published or required for the current Telegram
deployment.

On rerun, the runtime wrapper does not trust the existing container based only
on its image. Before reporting it as healthy or starting it, the wrapper also
validates its privilege mode, network mode, restart policy, complete host bind
mount list, other Docker mount mechanisms, added capabilities, port publishing,
and configured command. Any mismatch requires explicit operator review and
replacement; the wrapper does not modify the existing container.

The `/opt/data` mount also persists the local Whisper and Hugging Face cache at
`/opt/data/.cache`. `HF_TOKEN` is not required for the current transcription
use case. The runtime mounts no Docker socket, repository, cloud credentials,
or other host directory.

Discord may later provide a structured multi-agent or control-room interface.
Execution sandboxing and egress isolation remain future security work before
enabling tools with host or command-execution capabilities.

## Main-agent identity and project context

`hermes/SOUL.md` defines the durable global identity and interaction style for
Hermes. The repository-root `.hermes.md` separately defines this project's
operating instructions, including workflow, safety brakes, and the intended
orchestration model. Keeping these concerns separate prevents project-specific
architecture and temporary workflow state from becoming global personality.

Install the reviewed global identity from a repository checkout with:

```sh
sudo bash infrastructure/aws/install-hermes-main-agent-context.sh
```

The installer atomically replaces only `/var/lib/hermes/SOUL.md` with mode
`0644`. It does not touch `.env`, `auth.json`, `config.yaml`, Telegram
configuration, or any other Hermes state, and it does not restart the gateway.
Restart the gateway explicitly after installation so new sessions reliably
load the changed identity:

```sh
sudo docker restart hermes-gateway
```

The current gateway mounts only `/var/lib/hermes`, not this repository.
Therefore `.hermes.md` remains source-controlled project context primarily for
the future repository-mounted worker or execution layer unless it is explicitly
injected through a reviewed mechanism later. The installer intentionally does
not copy `.hermes.md` into `/var/lib/hermes`.
