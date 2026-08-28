# Greenfield state foundation

This independent OpenTofu root defines one S3 bucket and one customer-managed
KMS key for a single opaque `hms-[a-f0-9]{12}` deployment. Names are derived
only from the current AWS account ID, `eu-north-1`, and that deployment ID. It
has no remote backend and does not reuse either preserved root or state.

Routine repository validation is credential-free:

```sh
tofu init -backend=false -input=false
tofu validate
tofu test
```

The only outputs are the bucket name, KMS key ARN, and region needed to prepare
the greenfield host root's backend configuration. They are not secrets, but
operator backend files remain outside Git.

## Bootstrap boundary

This root has a deliberate chicken-and-egg boundary: its own bootstrap state
starts local because the remote bucket and key do not exist yet. That local
state must never enter Git and must remain in approved encrypted operator
storage until a separately reviewed state migration or import procedure exists.
This repository supplies no migration, import, apply, or recovery procedure.

Any future creation requires Mats to approve the exact saved plan before an
operator applies it. The bucket and KMS key both prevent OpenTofu destruction;
any future break-glass change requires separate review.
