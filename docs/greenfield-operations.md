# Greenfield operator runbook

The greenfield roots and `hermes.sh` support one disposable Hermes experiment
per opaque deployment ID. This is an operator-assisted Stage 1 workflow, not a
general installer or a production-ready service. It has no tested backup or
restore procedure, and teardown deliberately deletes Hermes data.

## Safety and credentials

Run routine operations from the repository root through `hermes.sh`. The
scripts force AWS CLI and OpenTofu operations to `eu-north-1` and call STS
before discovery or mutation. They fail closed unless the selected credentials
resolve to reviewed account `450895596262`.

The preferred credential source is the auto-refreshing operator profile. Local
alias management additionally requires Python 3:

```sh
aws login --profile platform-lab
export AWS_PROFILE=platform-lab-tofu
```

`platform-lab` is the interactive AWS CLI v2 `aws login` profile. The exported
`platform-lab-tofu` profile delegates to it through `credential_process` and is
the profile used for operator commands. Refresh with `aws login --profile
platform-lab` when STS reports an expired session. When `AWS_PROFILE`
is set, it is authoritative: the scripts unset exported access key, secret key,
session token, security token, and credential-expiration variables before
calling AWS. This prevents stale exported credentials from taking precedence
over the profile's `credential_process`. Without `AWS_PROFILE`, the scripts
accept only a complete exported static access-key pair and verify it with STS;
an incomplete pair or failed identity check stops the operation.

Do not put credentials, backend configuration, saved plans, OpenTofu state, or
Hermes runtime data in this repository. Operator artifacts are written with
restricted permissions under `~/hermes-operator/<deployment-id>/`; protect
that directory as sensitive operator storage.

## Routine workflow

Generate an opaque ID and optionally assign a local, non-identifying alias:

```sh
DEPLOYMENT_ID="$(./hermes.sh id --alias smoketest)"
./hermes.sh deploy smoketest
```

`id --alias` securely records the mapping before printing only the new opaque
ID on stdout. Existing deployments can be labeled and labels managed without
changing any deployment resource:

```sh
./hermes.sh alias set smoketest hms-0123456789ab
./hermes.sh alias list
./hermes.sh alias rename smoketest validation
./hermes.sh alias remove validation
```

Aliases are 1-63 lowercase letters/digits with interior hyphens; opaque-ID
shapes are reserved. Each alias and canonical ID may appear only once. The
potentially sensitive registry stays at `~/hermes-operator/aliases`, beneath an
owner-only directory, and is protected by owner-only permissions, validation,
locking, and atomic replacement. Symlinks, unsafe ownership or permissions,
and malformed or ambiguous records fail before an alias-dependent `list` or
`status` operation calls AWS. Commands given a canonical opaque ID intentionally
bypass alias lookup, preserving a recovery path when the local registry is
missing or needs repair.
For an existing operator directory that predates this requirement, first
inspect its ownership and contents, then run
`chmod 700 -- ~/hermes-operator`. The wrapper fails closed and prints this
migration command; it never changes existing permissions silently.

All deployment-targeting commands accept an alias or opaque ID. Resolution
happens in `hermes.sh` before command dispatch, so AWS tags/names, backend keys,
OpenTofu variables/plans/state, SSM commands, remote logs, and runtime data see
only the canonical ID. Saved-plan prompts and both destruction confirmations
also remain canonical. `list` and status-all add an explicit alias column when
local mappings exist; single status shows both values. Removing or renaming an
alias changes only this workstation. Preserve the printed opaque ID: a missing
registry on another workstation never blocks direct-ID recovery or operation.

Provision the dedicated state foundation and then the host:

```sh
./hermes.sh deploy "$DEPLOYMENT_ID"
```

If the deployment's state bucket is absent, `deploy` initializes the state root
without a backend, saves and displays its creation plan, and requires the exact
deployment ID as typed approval before applying that saved plan. It then writes
the host backend configuration outside Git, initializes that backend, saves and
displays the host creation plan, and requires the same typed approval again.
If the state bucket already exists, foundation creation is skipped. Stop at any
unexpected state, replacement, shared resource, IAM expansion, network or
security-boundary change. After apply, `deploy` waits at most 300 seconds for
the instance to become SSM Online.

Install the host prerequisites and pinned Hermes image:

```sh
./hermes.sh install "$DEPLOYMENT_ID"
```

`install` discovers exactly one attached data volume matching the deployment,
name, and instance. On the host, the helper resolves the EBS ID through the
Nitro device serial instead of assuming an NVMe device name. It accepts only an
empty unformatted device or the expected XFS filesystem, persists the exact
mount in `/etc/fstab` with `nodev,nosuid`, and mounts it at `/var/lib/hermes`
with mode `0700`. Docker binds that host directory to `/opt/data`; Hermes
configuration, credentials, conversations, and mutable state therefore live on
the dedicated encrypted EBS volume, not the root disk or this repository.

Complete the interactive Hermes wizard over SSM:

```sh
./hermes.sh ssm "$DEPLOYMENT_ID"
```

Then become root inside the session and run the setup command printed by
`install`:

```sh
sudo -i
docker run --rm -it --volume /var/lib/hermes:/opt/data \
  'nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e' setup
```

Configure the intended model, tools, and Telegram gateway, then exit the SSM
session. Do not print or copy the resulting data into Git.

Start the gateway:

```sh
./hermes.sh start-gateway "$DEPLOYMENT_ID"
```

The command verifies the exact mounted data volume and the existing container's
image, command, bind, restart policy, privileges, capabilities, ports, and
network contract. A matching running container is retained; a matching stopped
container is started. A mismatched container is left untouched and fails
closed. Only after reviewing the mismatch should an operator explicitly replace
it (which removes the existing container) with:

```sh
./hermes.sh start-gateway "$DEPLOYMENT_ID" --recreate
```

The replacement reuses `/var/lib/hermes`; it does not erase the data volume.

## Observe and control

```sh
./hermes.sh status "$DEPLOYMENT_ID"  # EC2, SSM, Docker, and gateway status
./hermes.sh status                    # same deployment summary as list
./hermes.sh list                      # discover state foundations and instances
./hermes.sh logs "$DEPLOYMENT_ID"    # follow the last 50 gateway log lines
./hermes.sh stop "$DEPLOYMENT_ID"    # stop a running EC2 instance
./hermes.sh start "$DEPLOYMENT_ID"   # start a stopped EC2 instance
./hermes.sh ssm "$DEPLOYMENT_ID"     # interactive SSM shell
```

`start` and `stop` wait for the corresponding EC2 state but do not wait for SSM
or inspect the gateway. Run `status` afterward. `logs` and `ssm` require the
instance to be SSM Online; `logs` opens an interactive command session and
continues until interrupted or the remote log stream ends. The detailed
`status` probe uses the AWS CLI SSM waiter and reports `unknown` when it cannot
obtain Docker or container output.

The non-interactive SSM work used by `install` and `start-gateway` polls for a
terminal result, prints captured stdout/stderr, and fails on failed, timed-out,
cancelled, undeliverable, terminated, malformed, or unknown results. Its local
deadline defaults to 600 seconds with five-second polling and may be overridden
with `HERMES_SSM_DEADLINE_SECONDS` and `HERMES_SSM_POLL_INTERVAL_SECONDS`.
Expiration returns status 124 but does **not** cancel the remote command: it may
still be pending or running. Use the exact `aws ssm get-command-invocation`
follow-up printed by the script before retrying or changing anything.

## Destruction

Routine teardown destroys the host root, including the EC2 host, root disk, and
the separately managed disposable Hermes EBS data volume. It preserves the S3
state bucket, its versions, and the KMS key:

```sh
./hermes.sh teardown "$DEPLOYMENT_ID"
```

The script saves and displays the destroy plan and applies only that saved plan
after the operator types the exact deployment ID. Review the displayed data
volume deletion and every other action before approving. There is no restore
procedure for `/var/lib/hermes`.

Full purge is break-glass destruction:

```sh
./hermes.sh purge "$DEPLOYMENT_ID"
```

Purge first requires the local state-foundation bootstrap state, verifies AWS
identity, prepares the host backend, creates an isolated copy of the state root
with destruction protection disabled, initializes both roots, and successfully
creates and displays **both** saved destroy plans. Only after that complete
preflight does it request two exact confirmations, in this order:

```text
destroy-host-hms-0123456789ab
purge-state-hms-0123456789ab
```

It then applies the saved host plan, permanently empties every object version
and delete marker from the state bucket, and applies the saved foundation plan.
This destroys the host and Hermes data volume and removes the state foundation;
KMS key deletion remains subject to its configured waiting period. A failure
after either confirmation can leave a partially destroyed deployment, so
inspect actual state before retrying. Never use automatic approval.

## Manual OpenTofu recovery and reference

Direct OpenTofu is not the routine operator interface. Use it only for a
separately reviewed recovery, import, or state-lineage procedure when the
wrapper cannot safely proceed. Confirm backend ownership, the deployment key,
local bootstrap-state custody, locked providers, account and region before any
live command. Always create a saved plan, display that exact file, obtain human
approval for it, and apply that same file without `-auto-approve`. Treat drift,
replacement, IAM, networking, state, and security changes as review brakes.

This repository does not provide a complete state recovery/import procedure or
a backup/restore procedure. Do not improvise one from these reference
principles or claim disaster-recovery or production readiness.

## Credential-free static validation

Repository validation never contacts AWS or a live backend. The commands in
the root README mirror `.github/workflows/ci.yml`; use that list for the full
local static-CI equivalent. Do not run host setup/runtime scripts, `tofu plan`,
or `tofu apply` as validation.
