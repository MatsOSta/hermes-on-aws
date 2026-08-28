# Greenfield operator runbook

This root is a CLI-only template for one disposable experiment. It does not
install or run Hermes. Repository CI is static and never contacts AWS.

## Credential-free validation

Run only these commands for routine repository validation:

```sh
tofu fmt -check -recursive .
tofu -chdir=infrastructure/greenfield init -backend=false -input=false
tofu -chdir=infrastructure/greenfield validate
tofu -chdir=infrastructure/greenfield test
tofu -chdir=infrastructure/greenfield-state init -backend=false -input=false
tofu -chdir=infrastructure/greenfield-state validate
tofu -chdir=infrastructure/greenfield-state test
conftest verify --policy policy/greenfield
conftest test --policy policy/greenfield --parser hcl2 infrastructure/greenfield/*.tf
conftest verify --policy policy/greenfield-state
conftest test --combine --policy policy/greenfield-state --parser hcl2 infrastructure/greenfield-state/*.tf
trivy config --severity HIGH,CRITICAL --exit-code 1 infrastructure/
```

OpenTofu tests, the independent Rego layer, and Trivy enforce the
credential-free contract before any later operator-led deployment.

These checks require no AWS credentials. Mocked OpenTofu tests do not query the
AMI parameter or any other AWS API.

## Later reviewed deployment

The following is a future operator procedure, not repository validation. Before
starting, confirm the target AWS account, `eu-north-1`, state-bucket ownership,
state lineage, credentials, and an unused opaque deployment namespace. The
independent `infrastructure/greenfield-state` root must first be handled as a
separately reviewed operator exercise. Its bootstrap state starts local and
must stay outside Git in approved encrypted operator storage until a separately
reviewed migration or import procedure exists.

Copy the host root's backend example to an untracked path and supply the
deployment-dedicated bucket and KMS key ARN. Retain `eu-north-1`, `encrypt =
true`, `use_lockfile = true`, and the opaque
`deployments/hms-0123456789ab/terraform.tfstate` key. Never reuse
`aws/terraform.tfstate` or another deployment's namespace.

```sh
tofu -chdir=infrastructure/greenfield init -reconfigure -backend-config=/secure/path/backend.hcl
tofu -chdir=infrastructure/greenfield plan -out=/secure/path/create.tfplan -var='deployment_id=hms-0123456789ab'
tofu -chdir=infrastructure/greenfield show /secure/path/create.tfplan
```

Stop for any unexpected replacement, shared resource, IAM expansion, network
change, or state mismatch. Mats must review and explicitly approve that exact
saved plan before an operator may run:

```sh
tofu -chdir=infrastructure/greenfield apply /secure/path/create.tfplan
```

The root device has `delete_on_termination = true`. The separate encrypted data
volume is tagged `Disposable = "true"`; its attachment uses normal detach
behavior and it remains an ordinary managed volume, so destroying this root
deletes it. This intentional data loss is part of the exact-plan review.

For teardown, first create and display a saved destroy plan:

```sh
tofu -chdir=infrastructure/greenfield plan -destroy -out=/secure/path/destroy.tfplan -var='deployment_id=hms-0123456789ab'
tofu -chdir=infrastructure/greenfield show /secure/path/destroy.tfplan
```

Mats must review and explicitly approve that exact destroy plan. Only then may
an operator run:

```sh
tofu -chdir=infrastructure/greenfield apply /secure/path/destroy.tfplan
```

Never use automatic approval. Keep backend files, saved plans, state, and
credentials outside this repository.

Every future plan, apply, or destroy—including any state-foundation operation—
requires Mats to approve the exact saved plan. The state bucket and KMS key have
destruction protection; changing that is a separately reviewed break-glass
procedure.
