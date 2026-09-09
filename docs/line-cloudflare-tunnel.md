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

## Create the remote tunnel and route

In the Cloudflare dashboard, create a remotely managed named tunnel for this
recipient deployment. Use one opaque tunnel credential per deployment; never
reuse a token between recipients. Add a public hostname of the form
`edge-<random>.stangyode.com`, where `<random>` is opaque and non-identifying,
and route its published application service to:

```text
http://hermes-gateway:8646
```

Do not add an EC2 inbound security-group rule and do not publish port 8646 (or
any other container port) on the host. The LINE webhook URL will be
`https://<host>/line/webhook`; the public health endpoint is
`https://<host>/line/webhook/health`.

## Provision the tunnel token without exposing it

Open an interactive SSM session with `./hermes.sh ssm <deployment-id>`, become
root with `sudo -i`, and enter the tunnel token only at the hidden prompt below.
The command stores no token in shell history and writes no trailing newline:

```sh
umask 077
install -d -o root -g root -m 0700 /var/lib/hermes/cloudflare-tunnel
read -rs -p 'Cloudflare tunnel token: ' CLOUDFLARE_TUNNEL_TOKEN
printf '\n'
printf '%s' "$CLOUDFLARE_TUNNEL_TOKEN" > /var/lib/hermes/cloudflare-tunnel/token
unset CLOUDFLARE_TUNNEL_TOKEN
chown root:root /var/lib/hermes/cloudflare-tunnel/token
chmod 0600 /var/lib/hermes/cloudflare-tunnel/token
```

Never put the token in Git, chat, Terraform/OpenTofu, command-line arguments,
logs, or an SSM SendCommand parameter. The helper rejects an absent, empty,
oversized, multiline, symlinked/non-regular, non-root-owned, or incorrectly
permissioned token and directory. The container deliberately runs as `0:0` so
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

## Rotate or roll back

To rotate, create a new credential for the same deployment in the Cloudflare
dashboard, stop the tunnel, overwrite the token through the same hidden
interactive procedure, and run `start-tunnel --recreate`. Confirm public health
and LINE Verify before revoking the old credential. Never echo either token.

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
