# Hermes on AWS

This repository is the Stage 1 extraction of the currently running Hermes AWS
stack from `platform-engineering-lab`. It preserves the deployed stack as-is so
future migration work can be reviewed without changing resource addresses,
physical names, remote-state location, or runtime behavior. It is **not yet a
proven reusable installer** and must not be applied as though it were a new,
parameterized deployment.

## What is here

- `infrastructure/aws`: the active OpenTofu root for the VPC, subnets, route
  tables, internet gateway, Hermes EC2 host, security group, instance role, and
  legacy GitHub OIDC/CI-read role. Its S3 backend remains
  `platform-engineering-lab-tofu-state-450895596262-eu-north-1` at
  `aws/terraform.tfstate` in `eu-north-1`.
- `infrastructure/bootstrap/state`: the independent bootstrap root that owns
  the versioned, encrypted, public-access-blocked S3 state bucket. It uses local
  AWS profile `platform-lab` and intentionally has no remote backend.
- `infrastructure/greenfield`: an independent, static-tested template for one
  disposable deployment identified only by an opaque `hms-[a-f0-9]{12}` ID.
  It does not reuse the preserved roots, their names, or their state. The
  repository-root `hermes.sh` is its primary routine operator interface.
- `infrastructure/greenfield-state`: an independent, static-tested local-state
  bootstrap root for that deployment's dedicated versioned S3 bucket and
  customer-managed KMS key. Its local bootstrap state must remain outside Git
  in approved encrypted operator storage.
- `policy/terraform`: Rego policy and unit tests enforcing the preserved
  private-subnet baseline.
- `policy/greenfield`: independent Rego guardrails for the disposable host
  network, metadata, SSH, and storage contracts.
- `policy/greenfield-state`: independent Rego guardrails for state isolation,
  encryption, access controls, and destruction protection.
- `infrastructure/aws/*.sh`: reviewed host bootstrap and Hermes setup/runtime
  helpers using the existing immutable Hermes image digest.
- `infrastructure/aws/hermes/SOUL.md` and `.hermes.md`: global Hermes identity
  source and repository-specific operating instructions.

The active shape is a `10.42.0.0/16` VPC across two availability zones. Two
edge subnets share an internet-gateway route; two workload subnets have only
the VPC-local route. The Hermes `t4g.medium` Amazon Linux 2023 host is in edge A
with a public address, no inbound security-group rules, HTTPS egress, IMDSv2,
an encrypted 30 GiB gp3 root volume, and Systems Manager access through its
instance role. Hermes runs in Docker with only `/var/lib/hermes:/opt/data`
mounted and no published ports.

## Prerequisites

Repository-only validation needs Bash and Python 3 and, for the full local CI equivalent,
OpenTofu 1.11.5, Docker, Conftest, ShellCheck, Gitleaks, and Trivy. Any later operator-led
inspection of live state additionally requires explicit access to AWS account
`450895596262`, region `eu-north-1`, and the existing backend. Host operations
require an authorized Systems Manager session and root privileges.

Do not infer deployment readiness from these prerequisites. Before any live
OpenTofu command, first confirm backend ownership, state lineage, provider
versions, credentials, account/region, and the reviewed migration procedure.

## Greenfield operator workflow

For the disposable greenfield deployment, use `hermes.sh` rather than direct
OpenTofu for routine work:

```sh
export AWS_PROFILE=platform-lab-tofu
aws login --profile platform-lab
# Choose plain ID generation, or generation with an operator-local alias:
./hermes.sh id
DEPLOYMENT_ID="$(./hermes.sh id --alias smoketest)"
./hermes.sh help
```

Aliases are optional, operator-local labels. Create or manage them with
`id --alias <alias>`, `alias set <alias> <hms-id>`, `alias list`, `alias rename
<old> <new>`, and `alias remove <alias>`. Every deployment-targeting command
accepts either the registered alias or its opaque ID, but resolves locally
before dispatch; AWS, OpenTofu, SSM, saved plans, and destructive confirmations
continue to receive only the canonical `hms-[a-f0-9]{12}` ID. `list` and
deployment-wide `status` show both values when aliases exist.

The registry is potentially sensitive metadata stored only at
`~/hermes-operator/aliases`, with owner-only directory/file permissions and
atomic locked updates. It must never be copied into Git or cloud state. An
invalid, ambiguous, symlinked, or insecure registry fails closed before an
alias-dependent `list` or `status` call reaches AWS. Commands given a canonical
opaque ID intentionally bypass alias lookup, so retain that ID for recovery and
use on another workstation even when the registry is missing or needs repair.
If an existing `~/hermes-operator` is rejected because it predates the
owner-only requirement, inspect its ownership and contents, then run
`chmod 700 -- ~/hermes-operator`; the wrapper never changes existing permissions
silently.

The wrapper covers `deploy`, `install`, interactive `ssm` setup,
`start-gateway` (with explicit `--recreate` for replacement), `status`, `logs`,
EC2 `start`/`stop`, `list`, `teardown`, and break-glass `purge`. Every AWS-backed
command verifies through STS that credentials resolve to account
`450895596262`; all operations are pinned to `eu-north-1`. When `AWS_PROFILE`
is present, stale exported static credential variables are unset so they cannot
override the profile. Refresh the SSO login when the profile session expires.
`platform-lab` is the interactive SSO profile; `platform-lab-tofu` delegates to
it through `credential_process` and remains the profile exported for operations.

`deploy`, `teardown`, and `purge` show exact saved plans and preserve typed human
approval boundaries. Teardown deletes the host and its disposable Hermes data
volume while retaining the deployment's state foundation. Purge completes both
plan preflights and requires two distinct confirmations before deleting the
host/data and state foundation. See the
[greenfield operator runbook](docs/greenfield-operations.md) for the exact
workflow, SSM time bounds, mount contract, and recovery boundary.

## Migration brakes

Stage 1 is preservation, not cutover. In particular:

- do not rename, move, import, remove, refactor, or parameterize resources;
- do not change the backend bucket/key or either checked-in lockfile;
- do not run `tofu plan` or `tofu apply` as routine repository validation;
- never use `tofu apply -auto-approve`;
- do not recreate the bootstrap bucket or initialize it as a live backend;
- do not enable the copied AWS identity workflow: the IAM trust subject still
  names the source repository and must be migrated in a separately reviewed
  stage;
- do not restart Hermes or run host scripts merely to validate this repository;
- treat unexpected state, drift, replacement, IAM, networking, or security
  boundary changes as a hard review stop.

CI is deliberately static-only: read-only repository permission, no OIDC token,
AWS role, credentials, backend access, live-state access, plan, or apply.

## Security and persistence boundary

The main Hermes gateway is deliberately low capability. Telegram has model and
vision access, but not terminal, file, skills, browser, code execution, Docker
socket, AWS/GitHub credentials, or a repository mount. The runtime publishes no
inbound port. Do not weaken that boundary for convenience.

All live Hermes configuration, credentials, conversations, and mutable state
belong only in `/var/lib/hermes` on the host, mounted from the deployment's
reviewed dedicated EBS data volume. The operator resolves that volume by exact
deployment/name/instance filters and the host resolves its Nitro device by EBS
serial rather than a fixed NVMe name. Never print the data, copy it into this
repository, or commit it. No AWS keys, Telegram tokens, model-provider secrets,
OpenTofu state, plan files, `.env` files, or credentials belong in Git.

See [SECURITY.md](SECURITY.md) for limitations and reporting guidance.

## Validation

Safe local checks do not need AWS credentials:

```sh
export CONFTEST_IMAGE='docker.io/openpolicyagent/conftest@sha256:b451f93ec386c25a4ed5aa4b835605dd4aee693374b619f5dc92374afcb6c296'
bash -n hermes.sh scripts/*.sh scripts/support/*.sh tests/*.sh tests/support/*.sh infrastructure/aws/*.sh
shellcheck hermes.sh scripts/*.sh scripts/support/*.sh tests/*.sh tests/support/*.sh infrastructure/aws/*.sh
python3 -m py_compile scripts/support/deployment-aliases.py
tests/operator_contract_test.sh
tests/deployment_alias_test.sh
tests/operator_safety_test.sh
tests/saved_plan_state_test.sh
tests/volume_discovery_test.sh
tests/install_operator_test.sh
tests/destructive_preflight_test.sh
tests/ssm_lifecycle_test.sh
tests/mount_data_volume_test.sh
tests/gateway_lifecycle_test.sh
tests/gateway_operator_test.sh
tofu fmt -check -recursive .
tofu -chdir=infrastructure/aws init -backend=false -input=false
tofu -chdir=infrastructure/aws validate
tofu -chdir=infrastructure/bootstrap/state init -backend=false -input=false
tofu -chdir=infrastructure/bootstrap/state validate
tofu -chdir=infrastructure/greenfield init -backend=false -input=false
tofu -chdir=infrastructure/greenfield validate
tofu -chdir=infrastructure/greenfield test
tofu -chdir=infrastructure/greenfield-state init -backend=false -input=false
tofu -chdir=infrastructure/greenfield-state validate
tofu -chdir=infrastructure/greenfield-state test
docker run --rm --volume "$PWD:/project" --workdir /project "$CONFTEST_IMAGE" verify --policy policy/terraform
docker run --rm --volume "$PWD:/project" --workdir /project "$CONFTEST_IMAGE" test --policy policy/terraform --parser hcl2 infrastructure/aws/*.tf
docker run --rm --volume "$PWD:/project" --workdir /project "$CONFTEST_IMAGE" verify --policy policy/greenfield
docker run --rm --volume "$PWD:/project" --workdir /project "$CONFTEST_IMAGE" test --combine --policy policy/greenfield --parser hcl2 infrastructure/greenfield/*.tf
docker run --rm --volume "$PWD:/project" --workdir /project "$CONFTEST_IMAGE" verify --policy policy/greenfield-state
docker run --rm --volume "$PWD:/project" --workdir /project "$CONFTEST_IMAGE" test --combine --policy policy/greenfield-state --parser hcl2 infrastructure/greenfield-state/*.tf
gitleaks git --no-banner --redact --exit-code 1
trivy config --severity HIGH,CRITICAL --exit-code 1 infrastructure/
```

`init -backend=false` may download locked providers but must never contact the
configured state backend. These commands mirror CI's checks; CI installs/pins
the corresponding tool versions and actions.

## Backup, recovery, and cost

The state bucket has versioning, SSE-S3 encryption, public-access blocking, and
`prevent_destroy`. This repository does not yet document or test a complete
backup and recovery procedure for remote OpenTofu state or `/var/lib/hermes`.
There is no claim of restore readiness; establish and exercise recovery before
depending on this extraction for disaster recovery.

The current greenfield teardown destroys the dedicated Hermes data volume along
with the host. Persistence across teardown is deliberately out of scope at this
stage; treat teardown as destructive to all data on that volume.

Expected cost-bearing resources include the continuously running `t4g.medium`
instance, its 30 GiB gp3 root volume, public IPv4 usage, S3 storage/versions and
requests, and outbound data transfer. Systems Manager, image pulls, package
repositories, and future AWS service changes may add usage or cost. Review
current AWS pricing and live inventory before making budget assumptions.
