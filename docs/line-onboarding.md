# LINE onboarding runbook

This runbook is the end-to-end operator procedure for connecting a fresh
`hermes-on-aws` greenfield deployment to LINE and authorizing its first user. It
separates the one-time deployment/channel work from the much shorter repeat-user
flow so later operators do not have to reconstruct the pilot from conversation
context.

This repository is an operator-assisted Stage 1 system. Use only commands marked
as available in the operator interface below; later pairing and live-acceptance
work remains proposed until its linked implementation is merged and the pinned
Hermes image is updated.

## Expected steady-state architecture

```text
LINE Platform
    | HTTPS POST /line/webhook
    v
Cloudflare edge
    | outbound named tunnel
    v
hermes-cloudflared
    | private Docker bridge; no host port
    v
hermes-gateway:8646
```

The reviewed boundary is:

- no EC2 inbound security-group rule;
- no Docker host port for the webhook;
- outbound TCP/UDP 7844 only to the reviewed Cloudflare edge ranges;
- LINE webhook signatures verified with `LINE_CHANNEL_SECRET`;
- a distinct Cloudflare tunnel credential for each deployment;
- unknown users denied until explicitly paired or allowlisted;
- secrets and mutable Hermes data stored only under `/var/lib/hermes` on the
  encrypted data volume.

For the network, token, container, rotation, and rollback contracts, also read
[LINE webhook through a Cloudflare named tunnel](line-cloudflare-tunnel.md).

## Quick path: one family-member acceptance message

**Acceptance goal:** one pre-approved, non-technical family member sends a LINE
message and receives **exactly one Hermes reply**, with no undocumented operator
steps. This is a short acceptance path for an already configured deployment; it
is not a replacement for the detailed procedures below.

### Operator-only preparation

1. Complete the [fresh deployment and LINE tie-in](#current-procedure-fresh-deployment-and-line-tie-in), including the provider-console settings, webhook verification, and public health check.
2. Pre-approve exactly one person out of band for enrollment; this means the
   person's identity is approved for the enrollment process, not that they are
   already authorized in Hermes. Provide the participant with the intended LINE
   Official Account name and its link or QR code. Explain that the first
   enrollment message is only for discovery and may receive no Hermes reply
   under the current pinned behavior.
3. Use the [current first-user discovery and authorization procedure](#7-discover-and-authorize-the-first-user). Confirm the sender's identity before
   appending the provider-scoped ID; do not use `LINE_ALLOW_ALL_USERS`, replace
   existing allowlist entries, or use the unavailable pairing flow.
4. Complete the required gateway restart and health check in that section.

Do not repeat secret-entry instructions here: follow [Run the interactive Hermes
setup](#3-run-the-interactive-hermes-setup) and its hidden-prompt and permission
requirements.

### Family-member steps

Give the approved person only these instructions, using the Official Account
name and link or QR code provided by the operator:

1. Add the existing LINE Official Account.
2. When the operator requests enrollment, send one ordinary text message for
   discovery. No Hermes reply is expected.
3. Wait while the operator verifies authorization, restarts the gateway, and
   confirms enrollment is complete.
4. Send exactly one ordinary text message for acceptance after the operator
   confirms enrollment is complete.
5. Do not send another message until the operator records the result.

The family member does not need AWS, Cloudflare, SSM, Docker, OpenTofu, Hermes
configuration, a pairing code, or a user ID.

### Live acceptance gates

The operator must observe and record, without exposing secrets or user IDs:

- the approved sender is the only newly authorized user;
- LINE greeting and automatic responses are disabled;
- the message produces exactly one context-appropriate Hermes reply and no
  duplicate or LINE canned reply; and
- the [full acceptance and restart/recovery checklist](#9-acceptance-and-restartrecovery)
  is completed before declaring the integration ready.

Static checks cannot prove this round trip. It is a human-operated live gate.
The current adapter does **not** provide the proposed first-DM pairing-code flow;
do not tell the family member to use `hermes pairing approve line`.

### Stop conditions

Stop without declaring success if the sender cannot be matched confidently, more
than one unknown ID appears, the authorization or restart check fails, any
credential would need to be pasted into chat or a command line, the message
gets zero replies or more than one reply, a LINE canned response appears, or
any listed live acceptance gate fails. Resume only through the detailed sections
linked above; do not improvise an operator step.

## What happens once and what repeats

### Once per deployment and LINE channel

1. Deploy the host and install the pinned Hermes image.
2. Create a LINE Messaging API channel and issue its credentials.
3. Configure the LINE platform in Hermes.
4. Create a Cloudflare named tunnel and public hostname.
5. Route that hostname to `http://hermes-gateway:8646`.
6. Configure, verify, and enable LINE's webhook.
7. Disable LINE greeting and automatic responses.
8. Complete live connectivity and restart/recovery acceptance.

### Once per new LINE user

Under the current pinned behavior:

1. The intended user adds the existing LINE Official Account and sends a message
   in a coordinated enrollment window.
2. The operator identifies the sender's provider-scoped `U...` ID from the
   signed webhook event recorded in Hermes's file log.
3. The operator verifies the person's identity out of band.
4. The operator adds the ID to `LINE_ALLOWED_USERS` without replacing existing
   IDs and restarts the gateway.
5. The user sends another message and completes Hermes's home/profile prompts.

The channel, DNS, tunnel, and webhook are **not** recreated for each user.

The target flow is shorter: the first DM returns a short-lived pairing code,
the operator approves it, and no ID copying or gateway restart is necessary.
See [Desired installation and pairing flow](#desired-installation-and-pairing-flow).

# Current procedure: fresh deployment and LINE tie-in

## 1. Deploy and install the host

From the operator workstation, using the repository wrapper:

```sh
DEPLOYMENT_ID="$(./hermes.sh id --alias <local-alias>)"
./hermes.sh deploy "$DEPLOYMENT_ID"
./hermes.sh install "$DEPLOYMENT_ID" --platform line
```

`deploy` includes reviewed saved-plan display and typed human approval. The
platform-aware `install` records only non-secret LINE intent in restricted local
operator state, mounts the dedicated encrypted data volume, installs Docker,
pulls the pinned Hermes image, and reports completed, pending, and unverified
phases. It does not collect credentials or claim LINE readiness. Follow the
exact safety and credential prerequisites in the
[greenfield operator runbook](greenfield-operations.md).

Do not create an inbound rule or publish port 8646.

## 2. Create the LINE channel

In the [LINE Developers Console](https://developers.line.biz/console/):

1. Create or select the intended provider.
2. Create a **Messaging API** channel under that provider.
3. Copy the **Channel secret** from **Basic settings**.
4. Issue and copy a long-lived **Channel access token** from **Messaging API**.
5. Record the Bot basic ID or QR code used to add the account.
6. Leave **Use webhook** off until the public health and Verify checks pass.
7. Enable **Webhook redelivery** and **Error statistics aggregation**.

In LINE Official Account Manager, open the account's response settings and turn
off:

- greeting messages;
- automatic response messages;
- chat, unless deliberately required for a separate human-support workflow.

This prevents LINE's built-in responses from being mistaken for Hermes replies.

Never paste the channel secret or access token into chat, Git, an issue, an
OpenTofu variable, or a command-line argument.

## 3. Run the interactive Hermes setup

Open SSM:

```sh
./hermes.sh ssm "$DEPLOYMENT_ID"
```

Inside the session, become root and run the setup command printed by `install`:

```sh
sudo -i
docker run --rm -it --volume /var/lib/hermes:/opt/data \
  'nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e' setup
```

Configure the intended model and tools. Select LINE in the gateway setup and
enter secrets only at its interactive prompts. The required LINE runtime values
are:

```text
LINE_CHANNEL_ACCESS_TOKEN=<long-lived token>
LINE_CHANNEL_SECRET=<channel secret>
LINE_PUBLIC_URL=https://<opaque-public-hostname>
```

`LINE_PUBLIC_URL` is the HTTPS base URL without `/line/webhook`. It is required
for Hermes-hosted LINE media delivery as well as useful startup diagnostics.

The pinned LINE adapter reads its LINE values from `/opt/data/.env` in the
container, which is `/var/lib/hermes/.env` on the host. Do not use `hermes config
set LINE_...` when it warns that the name is unrecognized and writes a custom
key to `config.yaml`; that does not configure the adapter in the pinned image.
Do not hand-edit `config.yaml`.

If the pinned setup wizard does not prompt for or persist all three values, use
the same pinned image with a TTY and Python's hidden-input function. This keeps
the secret values out of the command line and shell history:

```sh
docker run --rm -it --volume /var/lib/hermes:/opt/data \
  'nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e' \
  python -c '
from getpass import getpass
from hermes_cli.config import save_env_value

token = getpass("LINE channel access token: ").strip()
secret = getpass("LINE channel secret: ").strip()
public_url = input("LINE public HTTPS base URL: ").strip().rstrip("/")
if not token or not secret or not public_url.startswith("https://"):
    raise SystemExit("all values are required; public URL must start with https://")
save_env_value("LINE_CHANNEL_ACCESS_TOKEN", token)
save_env_value("LINE_CHANNEL_SECRET", secret)
save_env_value("LINE_PUBLIC_URL", public_url)
'
chmod 0600 /var/lib/hermes/.env
```

This command intentionally does not set `LINE_ALLOWED_USERS`: the first user's
ID is not yet known. Do not temporarily enable `LINE_ALLOW_ALL_USERS` to solve
that bootstrap dependency.

Verify required values without printing them:

```sh
for name in LINE_CHANNEL_ACCESS_TOKEN LINE_CHANNEL_SECRET LINE_PUBLIC_URL; do
  if grep -Eq "^${name}=.+" /var/lib/hermes/.env; then
    printf '%s=set\n' "$name"
  else
    printf '%s=missing\n' "$name"
  fi
done
stat -c 'mode=%a owner=%U:%G file=%n' /var/lib/hermes/.env
```

Require every value to report `set` and the file to be root-owned mode `600`.
If the wizard did not persist a required value, stop; do not improvise a
clear-text shell command. Re-run the interactive gateway setup or use a reviewed
hidden-prompt helper once that automation is implemented.

## 4. Start the gateway and create the tunnel

Start the gateway:

```sh
./hermes.sh start-gateway "$DEPLOYMENT_ID"
```

Run the bounded provisioning phase:

```sh
./hermes.sh configure-tunnel "$DEPLOYMENT_ID"
```

Before the run, issue a temporary API token scoped only to the intended account
and zone with **Account / Cloudflare Tunnel / Edit**, **Zone / DNS / Edit**, and
**Zone / Zone / Read**. Enter it only at the remote hidden prompt. The command
generates an opaque hostname, creates or verifies the dedicated remotely managed
tunnel, exact ingress and proxied CNAME, stores the connector credential directly
on the encrypted data volume, and starts the connector through the existing
metrics-gated runtime helper. It prints the resulting public HTTPS origin without
printing either credential. Revoke the temporary API token after success.

Then verify independently:

```sh
./hermes.sh status-tunnel "$DEPLOYMENT_ID"
```

`status-tunnel` must report a contract-matching container with an active edge
connection. A running container without an active connection is not ready. The
provisioning command never introduces an inbound security-group rule or Docker
host-port publication. See
[line-cloudflare-tunnel.md](line-cloudflare-tunnel.md#create-or-verify-the-remote-tunnel-and-route)
for conflict, rerun, credential rotation, revocation, and recovery boundaries.

## 5. Verify public health

From the operator workstation:

```sh
curl --fail --silent --show-error \
  --connect-timeout 10 \
  --max-time 20 \
  --write-out '\nHTTP %{http_code}\n' \
  'https://<opaque-public-hostname>/line/webhook/health'
```

Require HTTP 200 and the LINE health response. This proves the public route, but
not LINE signature validation or user authorization.

## 6. Configure and enable LINE's webhook

In **LINE Developers Console -> channel -> Messaging API -> Webhook settings**:

1. Set the Webhook URL to:

   ```text
   https://<opaque-public-hostname>/line/webhook
   ```

2. Click **Update** or **Save**.
3. Click **Verify** and require `Success`.
4. Enable **Use webhook**.
5. Confirm **Webhook redelivery** is enabled.
6. Confirm **Error statistics aggregation** is enabled.

The webhook endpoint is `/line/webhook`. `/line/webhook/health` is only the
operator health endpoint.

## 7. Discover and authorize the first user

### Preferred current method for the channel developer

If the intended user is legitimately a channel developer and their Business ID
is linked to their LINE account, the LINE Developers Console displays **Your
user ID** under the channel's **Basic settings** tab. Do not grant an ordinary
recipient developer access only to obtain their ID.

### General current method: signed webhook event

For ordinary recipients, use the existing verified webhook:

1. Arrange a narrow enrollment window with one intended person.
2. Have the person add the Official Account and send one message.
3. On the instance, inspect the Hermes file log:

   ```sh
   grep -F 'LINE: rejecting unauthorized source' \
     /var/lib/hermes/logs/gateway.log | tail -n 20
   ```

4. Extract the unique pending LINE IDs if needed:

   ```sh
   grep -F 'LINE: rejecting unauthorized source' \
     /var/lib/hermes/logs/gateway.log |
     grep -oE 'U[0-9a-fA-F]{32}' |
     sort -u
   ```

Hermes INFO events are written to `/var/lib/hermes/logs/gateway.log`. The
container console may show only WARNING and above, so an empty `docker logs`
search does not prove that no LINE webhook arrived.

A LINE user ID has the form `U[0-9a-f]{32}` and is scoped to the LINE provider.
The same person has the same ID across channel types under one provider, but may
have a different ID under another provider.

If more than one unknown ID appears, stop. Never approve the last or newest ID
by assumption. Match the event to the intended person using a coordinated time
and an independent identity check.

### Other official LINE methods

- `GET /v2/bot/followers/ids` can enumerate followers, but LINE restricts it to
  verified or premium Official Accounts and it does not establish which human
  owns which ID.
- A LINE Login channel under the same provider can identify a consenting user
  before messaging enrollment. This is appropriate for a larger self-service
  product, not necessary for the Stage 1 family pilot.
- LINE includes the user ID in follow and message webhook events. That is the
  general official discovery mechanism used above.

### Add the user without replacing existing users

The desired pairing flow is not available on the deployed LINE path yet. Until
it is, preserve the current comma-separated allowlist and append the verified
ID using Hermes's environment writer. Inside the SSM session:

```sh
read -r -p 'Verified LINE user ID: ' NEW_LINE_UID
case "$NEW_LINE_UID" in
  U????????????????????????????????) ;;
  *) printf '%s\n' 'Invalid LINE user ID format' >&2; unset NEW_LINE_UID; false ;;
esac
```

Then update the mounted Hermes environment through the running container:

```sh
docker exec --env NEW_LINE_UID="$NEW_LINE_UID" hermes-gateway python -c '
import os
from hermes_cli.config import get_env_value, save_env_value
new_uid = os.environ["NEW_LINE_UID"]
existing = get_env_value("LINE_ALLOWED_USERS") or ""
users = [item.strip() for item in existing.split(",") if item.strip()]
if new_uid not in users:
    users.append(new_uid)
save_env_value("LINE_ALLOWED_USERS", ",".join(users))
'
unset NEW_LINE_UID
chmod 0600 /var/lib/hermes/.env
```

Display only the count, not the identifiers:

```sh
docker exec hermes-gateway python -c '
from hermes_cli.config import get_env_value
value = get_env_value("LINE_ALLOWED_USERS") or ""
print("approved_line_users=" + str(len([x for x in value.split(",") if x.strip()])))
'
```

Restart from outside the gateway's own agent session so the adapter reloads the
environment:

```sh
docker restart hermes-gateway
```

Then require:

```sh
docker inspect --format 'running={{.State.Running}}' hermes-gateway
curl --fail --silent --show-error \
  'https://<opaque-public-hostname>/line/webhook/health'
```

## 8. Complete first-message onboarding

Have the approved user send a new message. Expected behavior is:

1. exactly one Hermes response, with no LINE canned response;
2. a warning that no home conversation is set;
3. an offer to set the current LINE conversation as home;
4. an offer to build the user's profile.

For a dedicated personal deployment, the recipient can accept both onboarding
prompts. A separate manual `LINE_HOME_CHANNEL` setting is not required when the
first-message flow sets the home conversation.

The profile describes the recipient who owns this dedicated instance, not the
infrastructure operator.

## 9. Acceptance and restart/recovery

Do not declare the integration ready until all checks pass:

1. EC2 is managed through SSM.
2. The applied security group has no inbound rules.
3. Docker publishes no host port for the gateway or tunnel.
4. Host TCP/7844 succeeds and connector evidence confirms QUIC or HTTP/2.
5. `status-tunnel` reports a connected, contract-matching tunnel.
6. Cloudflare reports at least one active connector replica.
7. Public `/line/webhook/health` returns HTTP 200.
8. LINE webhook **Verify** succeeds.
9. **Use webhook**, redelivery, and error statistics are enabled.
10. Greeting and automatic responses are disabled.
11. An explicitly authorized user gets exactly one context-appropriate reply.
12. The home/profile first-message flow completes or is deliberately declined.
13. Gateway and tunnel recover after the reviewed stop/start or reboot test.
14. A post-recovery LINE message receives a normal reply.

Static CI cannot prove AWS, Cloudflare, or LINE connectivity. These live checks
remain human-operated acceptance gates.

# Current procedure: add another user

Do not recreate the instance, channel, tunnel, DNS, or webhook. Repeat only:

1. Coordinate one enrollment window.
2. Have the new user add the Official Account and send one message.
3. Read their provider-scoped ID from the signed webhook event in
   `/var/lib/hermes/logs/gateway.log`.
4. Verify identity out of band.
5. Append the ID without replacing existing entries.
6. Restart and recheck gateway health.
7. Have the new user send another message.
8. Confirm authorization and apply the intended home/profile policy.

On a dedicated single-recipient deployment, adding another user changes the
trust and identity model. Review whether they should share the same Hermes
memory and conversation environment before approving them.

# Desired installation and pairing flow

The platform-aware operator interface is now:

```sh
./hermes.sh install <deployment-id> --platform line
```

The accepted convenience aliases are:

```sh
./hermes.sh install <deployment-id> --line
./hermes.sh install <deployment-id> -l
```

All three spellings resolve to the same canonical `line` mode. The command
records a versioned, non-secret intent file under
`~/hermes-operator/install-platforms/`, with directory mode `0700` and file mode
`0600`. Matching reruns retain that state. Malformed, unsafe, or contradictory
state fails before AWS is contacted. After revalidating host preparation, the
command reports the still-pending secure configuration, tunnel, pairing, and
live-acceptance phases.

The secure runtime phase is now available as a separate bounded command:

```sh
./hermes.sh configure-line <deployment-id>
```

The command accepts no credential options. It sends only the reviewed helper to
the instance, then opens an interactive SSM session. Enter the channel access
token and channel secret at the remote hidden prompts and the public HTTPS base
URL at the visible prompt. The helper validates without echoing secrets,
atomically updates `/var/lib/hermes/.env` at mode `0600`, enables LINE through
the pinned Hermes image's `config set` command, and calls LINE's supported API
to write, exactly read back, and test `<base-url>/line/webhook`.

A rerun with matching values is safe. Any mismatched existing LINE value,
symlinked or permissive environment file, malformed URL, API failure, or
read-back mismatch fails closed and prints a corrective next step without
printing credential values. The helper explicitly reports provider-console
settings as **unverified**; it does not claim tunnel health or a live message
round trip.

The bounded Cloudflare phase is also available:

```sh
./hermes.sh configure-tunnel <deployment-id>
```

It accepts no local credentials, uses a remote hidden prompt for the scoped API
token, verifies exact account/zone ownership before mutation, creates or retains
one opaque hostname and remotely managed tunnel, performs exact configuration
and DNS read-back, and starts the connector through the metrics-gated helper.
Neither command claims that LINE is ready; authorization and live acceptance
remain separate phases.

`--platform line` should be canonical because it scales to future transports and
makes intent explicit. `-line` should not be used: conventional long options
start with two hyphens, and the existing wrapper is `hermes.sh`, not `hermes`.

The option must never accept secrets as adjacent command-line values. It should
bake in every safe deterministic prerequisite and produce a short, resumable
checklist for the unavoidable provider-console steps.

## Automation should perform

1. Select the LINE/webhook deployment profile before infrastructure planning.
2. Validate that the reviewed Cloudflare TCP/UDP 7844 egress shape is present.
3. Install Docker, mount and verify the encrypted data volume, and pull the
   pinned Hermes image as today.
4. Enable LINE in Hermes configuration through supported Hermes commands.
5. Collect the LINE channel secret, channel token, public hostname, and tunnel
   token only through hidden interactive prompts or a reviewed secret source.
6. Validate value presence and format without printing secret values.
7. Persist runtime values atomically with owner-only permissions.
8. Create or verify the gateway and tunnel container contracts.
9. Wait for real tunnel readiness, not only container state.
10. Probe the public health endpoint.
11. Use LINE's Messaging API to set, read back, and test the webhook endpoint
    when the channel token's supported API permits it.
12. Print the remaining LINE console settings that cannot be changed by API,
    with explicit unverified/verified state.
13. Stop before claiming success until a human confirms those console settings
    and a live message round trip.
14. Be idempotent and resumable; never replace a mismatched container, token,
    hostname, or channel configuration without an explicit reviewed action.

Cloudflare provisioning is a separate bounded subcommand. It requires a
least-privilege Cloudflare API token scoped to the intended account and zone and
does not turn the broad install command into an unreviewed secret- or
DNS-mutation path.

## Native LINE pairing should perform

Hermes already defines a generic direct-message pairing model:

1. An unknown user sends a DM.
2. Hermes returns a cryptographically random, short-lived code.
3. The operator lists pending requests and verifies the intended person.
4. The operator runs:

   ```sh
   hermes pairing approve line <code>
   ```

5. Hermes persists the approved platform/user binding and confirms enrollment.
6. The user's next message enters the normal home/profile onboarding flow.

The deployed LINE adapter currently rejects an unknown source before this
pairing response is sent. The implementation must route unauthorized LINE DMs
through the shared pairing subsystem while keeping groups/rooms denied unless
separately approved. Pairing codes must never be logged, and approval must not
require a gateway restart.

Until that behavior is implemented and verified in the pinned image, continue
using the explicit allowlist procedure above. Do not document or demonstrate
`hermes pairing approve line` as currently operational in this deployment.

## Implementation tracking

The work is split so CLI orchestration, secret handling, Cloudflare mutation,
upstream pairing, and readiness reporting can be reviewed independently:

- [#45: platform-aware LINE install mode](https://github.com/MatsOSta/hermes-on-aws/issues/45)
- [#46: secure LINE configuration and webhook bootstrap](https://github.com/MatsOSta/hermes-on-aws/issues/46)
- [#47: bounded LINE tunnel and hostname provisioning](https://github.com/MatsOSta/hermes-on-aws/issues/47)
- [#48: route unauthorized LINE DMs through Hermes pairing](https://github.com/MatsOSta/hermes-on-aws/issues/48)
- [#49: truthful preflight and live acceptance reporting](https://github.com/MatsOSta/hermes-on-aws/issues/49)
- [#50: minimal-manual-steps LINE onboarding epic](https://github.com/MatsOSta/hermes-on-aws/issues/50)

## Remaining manual steps after automation

Even the finished installer cannot safely infer human intent. The operator must
still:

- create or select the correct LINE provider and Official Account unless a
  separately reviewed organizational API supports it;
- issue or authorize the required LINE and Cloudflare credentials;
- review public hostname and service-route ownership;
- verify LINE console settings that cannot be read or written through supported
  APIs;
- verify the identity of each person before approving a pairing code;
- perform the first real message and restart/recovery acceptance tests;
- remain the approval boundary for OpenTofu apply and repository PR merge.

## References

- [Hermes LINE documentation](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/line)
- [Hermes gateway security and pairing](https://hermes-agent.nousresearch.com/docs/user-guide/security#user-authorization-gateway)
- [LINE: Get user IDs](https://developers.line.biz/en/docs/messaging-api/getting-user-ids/)
- [LINE: Receive messages with webhooks](https://developers.line.biz/en/docs/messaging-api/receiving-messages/)
- [LINE Messaging API reference](https://developers.line.biz/en/reference/messaging-api/)
