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
  It does not reuse the preserved roots, their names, or their state.
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

Repository-only validation needs Bash and, for the full local CI equivalent,
OpenTofu 1.11+, Docker, Conftest, ShellCheck, and Trivy. Any later operator-led
inspection of live state additionally requires explicit access to AWS account
`450895596262`, region `eu-north-1`, and the existing backend. Host operations
require an authorized Systems Manager session and root privileges.

Do not infer deployment readiness from these prerequisites. Before any live
OpenTofu command, first confirm backend ownership, state lineage, provider
versions, credentials, account/region, and the reviewed migration procedure.

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
belong only in `/var/lib/hermes` on the host. Never print it, copy it into this
repository, or commit it. No AWS keys, Telegram tokens, model-provider secrets,
OpenTofu state, plan files, `.env` files, or credentials belong in Git.

See [SECURITY.md](SECURITY.md) for limitations and reporting guidance.

## Validation

Safe local checks do not need AWS credentials:

```sh
bash -n hermes.sh scripts/*.sh scripts/support/*.sh tests/*.sh tests/support/*.sh infrastructure/aws/*.sh
shellcheck hermes.sh scripts/*.sh scripts/support/*.sh tests/*.sh tests/support/*.sh infrastructure/aws/*.sh
tests/operator_contract_test.sh
tests/operator_safety_test.sh
tests/destructive_preflight_test.sh
tests/ssm_lifecycle_test.sh
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
conftest verify --policy policy/terraform
conftest test --policy policy/terraform --parser hcl2 infrastructure/aws/*.tf
conftest verify --policy policy/greenfield
conftest test --combine --policy policy/greenfield --parser hcl2 infrastructure/greenfield/*.tf
conftest verify --policy policy/greenfield-state
conftest test --combine --policy policy/greenfield-state --parser hcl2 infrastructure/greenfield-state/*.tf
trivy config --severity HIGH,CRITICAL --exit-code 1 infrastructure/
```

`init -backend=false` may download locked providers but must never contact the
configured state backend. CI performs the same class of static checks.

## Backup, recovery, and cost

The state bucket has versioning, SSE-S3 encryption, public-access blocking, and
`prevent_destroy`. This repository does not yet document or test a complete
backup and recovery procedure for remote OpenTofu state or `/var/lib/hermes`.
There is no claim of restore readiness; establish and exercise recovery before
depending on this extraction for disaster recovery.

Expected cost-bearing resources include the continuously running `t4g.medium`
instance, its 30 GiB gp3 root volume, public IPv4 usage, S3 storage/versions and
requests, and outbound data transfer. Systems Manager, image pulls, package
repositories, and future AWS service changes may add usage or cost. Review
current AWS pricing and live inventory before making budget assumptions.
