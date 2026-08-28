# Greenfield deployment root

This independent OpenTofu root describes exactly one disposable deployment.
It shares no resources, names, or state with the preserved AWS roots. The
required `deployment_id` is deliberately opaque and must match
`hms-[a-f0-9]{12}`.

The backend declaration is partial. Copy `backend.hcl.example` to an untracked
file outside the repository and replace its bucket value. Keep the opaque
per-deployment key shape; never use `aws/terraform.tfstate` for this root.

See [the operator runbook](../../docs/greenfield-operations.md) before running
anything beyond static validation.
