# Greenfield deployment root

This independent OpenTofu root describes exactly one disposable deployment.
It shares no resources, names, or state with the preserved AWS roots. The
required `deployment_id` is deliberately opaque and must match
`hms-[a-f0-9]{12}`.

The backend declaration is partial. The independent `../greenfield-state` root
defines the deployment-dedicated bucket and KMS key. Copy
`backend.hcl.example` to encrypted operator storage outside the repository and
supply those two outputs. Keep the opaque per-deployment key shape, encryption,
and native S3 lockfile enabled; never use `aws/terraform.tfstate` or another
deployment's namespace for this root.

See [the operator runbook](../../docs/greenfield-operations.md) before running
anything beyond static validation.
