# Repository instructions

## Purpose and stage

This repository is a clean-history Stage 1 extraction of a running Hermes AWS
deployment. It preserves the active infrastructure; it is not yet a reusable
installer. Keep changes narrow and migration-aware.

## Hard safety boundaries

- Work only in this repository. The source repository is read-only.
- Never commit secrets, credentials, OpenTofu state/plan files, or anything from
  `/var/lib/hermes`; never inspect or modify that host directory as repository
  work.
- Do not contact AWS, initialize the live backend, run `tofu plan`/`apply`,
  restart Hermes, or execute host setup/runtime scripts during validation.
- Do not enable GitHub OIDC or an AWS-connected workflow without a separately
  reviewed migration. CI must remain static-only with `contents: read` and no
  `id-token: write`, AWS role, live state, plan, or apply.
- Treat IAM, backend, state lineage, networking, security boundary, destructive
  changes, and unexpected resource replacement as review brakes.

## Preservation rules

Until a later reviewed stage, preserve the backend bucket/key, Terraform
resource addresses, provider lockfiles, pinned Hermes image digest, legacy
physical names/tags, and operational scripts. Do not refactor, rename,
parameterize, or modernize them opportunistically. Documentation may explain
legacy references but must not imply they have already migrated.

Keep the Python workload, Dockerfile, Python lock/project files, tracked cache,
platform branch-protection root, service-health CI, and live AWS identity
workflow out of this repository.

## Validation

Run non-destructive checks proportional to the change: `bash -n` and ShellCheck
for scripts, `tofu fmt -check`, `tofu init -backend=false` plus `tofu validate`
for each root, Rego unit/policy tests, and static IaC scanning. Report tools that
are unavailable. Never substitute a live plan for static validation.

Do not commit or push unless the user explicitly asks.

