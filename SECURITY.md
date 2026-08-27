# Security policy and current boundaries

## Reporting

Do not open a public issue containing credentials, state data, account access,
Telegram identifiers/tokens, model-provider secrets, host details that increase
exploitability, or contents of `/var/lib/hermes`. Report sensitive findings
privately to the repository owner and rotate exposed credentials through the
owning system; deleting a Git file does not remove it from history.

## Runtime boundary

The Hermes host has no inbound security-group rule and is administered through
AWS Systems Manager. Its security group permits outbound HTTPS. The gateway
container is unprivileged, publishes no ports, adds no capabilities, and mounts
only `/var/lib/hermes` at `/opt/data`; it must not receive the Docker socket,
repository, cloud credentials, or additional host paths.

The Telegram main agent intentionally lacks terminal, file, skills, browser,
code-execution, AWS, and GitHub capabilities. Vision is the sole tested tool
baseline. Any execution or broader egress capability requires a separately
designed isolated worker/sandbox boundary.

`/var/lib/hermes` is sensitive mutable runtime data and is outside Git. The
scripts may alter it only when an operator deliberately runs them on the host;
CI and repository validation must never do so. The immutable Hermes image
digest is part of the reviewed runtime contract.

## Infrastructure and CI limitations

CI performs static checks only, with `contents: read`, persisted checkout
credentials disabled, and no OIDC token, AWS role, credentials, remote backend,
plan, or apply. A green run does not prove live infrastructure health, absence
of drift, correct state lineage, recoverability, or that every security issue
has been detected. Scanner suppressions are time-bounded review decisions and
must not be extended without justification.

The copied IAM trust still identifies the source repository. It is preserved to
avoid an unreviewed live IAM change and must not be treated as functional target
repository federation. Moving trust and any live identity checks is deferred.

The state bucket uses versioning, SSE-S3, public-access blocking, and
`prevent_destroy`, but backup restoration has not been exercised here. There is
also no documented, tested backup/recovery process for `/var/lib/hermes`.
Recovery is therefore a known gap, not an implied guarantee.

