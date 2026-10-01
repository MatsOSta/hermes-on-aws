# LINE webhook through a Cloudflare named tunnel

This Stage 1 procedure exposes only the Hermes LINE webhook through a remotely
managed Cloudflare named tunnel. It adds no inbound security-group rule and
publishes no Docker host port. `cloudflared` reaches the gateway by Docker DNS
on the private `hermes-tunnel-net` bridge.

This document owns the tunnel's network, credential, container, and recovery
contracts. For fresh LINE channel setup, user-ID discovery, authorization,
first-message onboarding, and the proposed platform-aware installer/pairing
flow, follow the [LINE onboarding runbook](line-onboarding.md).

## Required outbound network path

Cloudflare Tunnel requires outbound port 7844 to its global edge endpoints:

- UDP/7844 for QUIC;
- TCP/7844 for HTTP/2 fallback.

The reviewed greenfield security group allows both protocols to
`198.41.192.0/24` and `198.41.200.0/24`, the IPv4 ranges containing
Cloudflare's documented `region1.v2.argotunnel.com` and
`region2.v2.argotunnel.com` endpoints. TCP/443 remains available for the
host's existing HTTPS traffic. Security groups are stateful, so replies to
these outbound connections require no inbound security-group rule.

This root does not manage a network ACL. If an operator has attached a custom
restrictive NACL outside this repository, it must allow outbound TCP/UDP 7844
and the corresponding ephemeral return traffic. Do not add an inbound
security-group rule to compensate for a restrictive NACL.

After applying the reviewed OpenTofu plan, verify TCP reachability from the
host before debugging dashboard routing. For example, in an interactive SSM
session:

```sh
timeout 5 bash -c 'exec 3<>/dev/tcp/198.41.192.167/7844'
```

Exit status 0 proves that TCP/7844 is reachable; status 124 is a timeout.
Cloudflare's connector logs provide the corresponding QUIC/UDP evidence.

## Issue the bounded API token

Create a temporary Cloudflare API token before running the provisioning phase.
Scope it to only the intended Cloudflare account and DNS zone, with exactly:

- **Account / Cloudflare Tunnel / Edit** for the intended account;
- **Zone / DNS / Edit** for the intended zone;
- **Zone / Zone / Read** for the intended zone.

Do not grant account-wide DNS access, other account permissions, or access to
all zones. Copy the account ID and zone ID; they are prompted for remotely and
are not credentials. Enter the API token only at the hidden prompt described
below. Revoke this temporary API token after a successful run and read-back.

## Create or verify the remote tunnel and route

Start the Hermes gateway first, then run from the operator workstation:

```sh
./hermes.sh configure-tunnel <deployment-id>
```

The command opens an interactive SSM session and prompts on the instance for the
account ID, zone ID, zone name, and scoped API token. It creates one remotely
managed tunnel named from the opaque deployment ID and an opaque hostname of
the form `edge-<random>.<zone>`. Its only published application service is:

```text
http://hermes-gateway:8642
```

The command reads back the tunnel, ingress configuration, and proxied CNAME
exactly before reporting success. Matching state is retained on rerun. A
different account, zone, tunnel, hostname, DNS target, or service fails closed;
the command never deletes, rotates, adopts an unmanaged same-name tunnel, or
replaces a conflicting route. State is root-owned mode `0600` under
`/var/lib/hermes/cloudflare-tunnel/state.json`.

Do not add an EC2 inbound security-group rule and do not publish port 8642 (or
any other container port) on the host. The LINE webhook URL will be
`https://<host>/line/webhook`; the public health endpoint is
`https://<host>/line/webhook/health`.

## Connector credential transport

`configure-tunnel` retrieves the deployment-specific connector credential
inside the remote process and writes it directly to the encrypted data volume
as `/var/lib/hermes/cloudflare-tunnel/token`, root-owned mode `0600`, with no
trailing newline. Neither the Cloudflare API token nor connector credential is
accepted in local argv, SSM SendCommand parameters, shell history, Git, logs, or
operator output. A different existing connector credential fails closed;
rotation is not implicit.

The runtime helper rejects an absent, empty, oversized, multiline,
symlinked/non-regular, non-root-owned, or incorrectly permissioned token and
directory. The container deliberately runs as `0:0` so
it can read the root-owned mode-0600 bind; all capabilities remain dropped,
`no-new-privileges` is set, and the root filesystem is read-only.

## Configure Hermes and LINE

In the interactive Hermes setup, configure these variables with the real values
only in Hermes runtime storage on the encrypted data volume:

```text
LINE_CHANNEL_ACCESS_TOKEN=<channel access token>
LINE_CHANNEL_SECRET=<channel secret>
LINE_PUBLIC_URL=https://<host>
LINE_ALLOWED_USERS=<explicit approved LINE user IDs>
```

Never use or recommend an allow-all value for `LINE_ALLOWED_USERS`. In LINE
Official Account Manager, disable greeting messages and auto-reply messages.
Keep **Use webhook** off until the public health URL succeeds and LINE's
**Verify** action succeeds. Then enable **Use webhook**.

## Start, inspect, and stop

Start the Hermes gateway first, then the tunnel:

```sh
./hermes.sh start-gateway <deployment-id>
./hermes.sh start-tunnel <deployment-id>
./hermes.sh status-tunnel <deployment-id>
./hermes.sh stop-tunnel <deployment-id>
```

A matching stopped container is restarted and a matching running container is
retained. A mismatch fails closed. Review every reported mismatch before using
`./hermes.sh start-tunnel <deployment-id> --recreate`; recreation replaces only
the tunnel container, not the token. `stop-tunnel` is idempotent when absent or
already stopped, but refuses to stop an unverified same-name container.

The container exposes Cloudflare's metrics/readiness endpoint only on
`127.0.0.1:2000` inside the container. No Docker host port is published.
`start-tunnel` waits for the native `cloudflared tunnel ready` probe and
succeeds only when at least one active Cloudflare edge connection exists.
`status-tunnel` exits nonzero for an absent, stopped, contract-mismatched, or
running-but-unconnected container; only a contract-matching connected tunnel
returns success.

For diagnostics, use `status-tunnel`, Docker container state/health metadata,
and requests to the public health path. Do not print the token, inspect file
contents, include it in `docker inspect` arguments, or paste logs containing
credentials. A failing start/readiness check should be investigated in this
order: outbound TCP/UDP 7844, custom NACL or host-firewall restrictions,
connector logs, dashboard hostname/service route, membership of both
containers on `hermes-tunnel-net`, gateway state, and Hermes LINE configuration.

## Complete the live pilot

Static CI cannot prove live AWS, Cloudflare, or LINE connectivity. After a
human reviews and applies the OpenTofu plan, record all of the following before
declaring the pilot complete:

1. TCP/7844 succeeds from the deployment host and connector logs confirm QUIC
   or HTTP/2 edge connections.
2. `status-tunnel` reports connected and Cloudflare shows at least one active
   connector replica.
3. `https://<host>/line/webhook/health` succeeds.
4. LINE's webhook **Verify** action succeeds.
5. An explicitly approved LINE user completes a message round trip.
6. The gateway and tunnel recover after the reviewed restart or reboot test.
7. The applied security group still has zero ingress rules and Docker still
   publishes no host ports.

## Revoke, rotate, recover, or roll back

After initial provisioning succeeds, revoke the temporary scoped API token in
Cloudflare. Revoking that API token does not revoke the connector credential.
If the API token is exposed before completion, revoke it, issue another token
with the same three bounded permissions, and rerun; exact matching resources are
retained.

Connector credential rotation and Cloudflare resource deletion are deliberately
outside `configure-tunnel`. For a suspected connector-token compromise, use a
separately reviewed Cloudflare rotation procedure, stop the connector, replace
the local token through a hidden remote session, recreate the connector, verify
public health and LINE Verify, and only then revoke/disconnect the old
credential. Never echo either credential. If local state is lost while remote
resources remain, stop rather than adopting or recreating them: recover the
encrypted data volume or perform a separately reviewed ownership-recovery
procedure using exact Cloudflare resource IDs.

For rollback, first disable **Use webhook** in LINE and remove/disable the
Cloudflare public hostname and tunnel in the dashboard. Then, in an interactive
SSM session, verify the exact resource names and remove only the reviewed
resources:

```sh
./hermes.sh stop-tunnel <deployment-id>
./hermes.sh ssm <deployment-id>
sudo docker container rm hermes-cloudflared
sudo docker network disconnect hermes-tunnel-net hermes-gateway 2>/dev/null || true
sudo docker network rm hermes-tunnel-net
sudo rm -- /var/lib/hermes/cloudflare-tunnel/token
sudo rmdir -- /var/lib/hermes/cloudflare-tunnel
```

The container removal is intentionally not forced: inspect and resolve an
unexpected running or mismatched same-name container instead of deleting it.
These container/token rollback steps do not alter gateway data, the security
group, VPC, IAM, backend, or OpenTofu state. Reverting the reviewed 7844 egress
rules, if desired after disabling the pilot, requires a separate reviewed
OpenTofu change and human-operated apply.
