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
trivy config --severity HIGH,CRITICAL --exit-code 1 infrastructure/greenfield
```

A follow-up PR will add an independent Rego policy layer and its Conftest
commands. Until that checkpoint lands, OpenTofu tests and Trivy are the
credential-free enforcement for this root.

These checks require no AWS credentials. Mocked OpenTofu tests do not query the
AMI parameter or any other AWS API.

## Later reviewed deployment

The following is a future operator procedure, not repository validation. Before
starting, confirm the target AWS account, `eu-north-1`, state-bucket ownership,
state lineage, credentials, and an unused opaque deployment namespace. Copy the
example backend configuration to an untracked path and supply the actual bucket
there. Never reuse `aws/terraform.tfstate`.

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
