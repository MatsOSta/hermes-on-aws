# Wife-instance production intent

This branch is the dedicated personal LINE instance for the family
recipient, not the LINE family smoketest and not the low-capability
Telegram main-agent profile in the README.

The stopped smoketest host `hms-ae1485be4182` stays as a wall-check.
Do not teardown or purge it while this work is open. Start it only to
compare behaviour:

```sh
./hermes.sh start hms-ae1485be4182
```

Deploy the wife instance as a new greenfield ID. Reuse the existing LINE
Official Account only if the operator confirms ownership; mint a new
Cloudflare hostname and rewrite the webhook. Follow
[line-onboarding.md](line-onboarding.md) for channel, tunnel, allowlist,
and first-user steps, using `configure-tunnel` then `configure-line` so
`LINE_PUBLIC_URL` exists before secrets are stored.

## Product clues

These are operator intent. Several are newer than this repository's
pinned Hermes image and the Telegram lockdown. They are not live on any
host until a reviewed image and setup path land.

| Clue | Intent | Repo / image today |
| --- | --- | --- |
| Model is sol | Default chat model `gpt-5.6-sol` via `openai-codex`. Not Nous `solar-pro4:free`. | Unspecified. Setup says only "configure the intended model". Codex device-login from SSM is not documented. |
| Image generation | Recipient asked for image gen. | Provider unknown. Hermes has an `image_gen` toolset; Nous Tool Gateway is a different auth path than Codex. Do not assume sol can draw. |
| Default in feature | Personal LINE instance should use Hermes default features for that platform, including memory and skills, not the Telegram model-only cut. | Telegram setup disables `terminal`, `file`, and `skills`. LINE has no equivalent documented enablement. Terminal/file/browser/code_execution on a LINE-connected EC2 host stay a review brake; this document does not enable them. |
| Learn and update memory automatically | Memory tool enabled; background self-improvement review allowed to write. `memory.write_approval` must not stage gateway writes unread. | Not in the LINE runbook. Gateway sessions are long-lived; `/new` at natural boundaries is still required for frozen memory snapshots to load. |
| Normally 7-day review | Keep the usual ~7-day memory/skill review cadence (nudge/review interval), not a never-review lock-down. | Not in this repository. Confirm `memory.nudge_interval` / `skills.creation_nudge_interval` against the image we pin. If the current digest lacks it, that is an image bump, not a script tweak. |

## Boundaries that do not move

- No inbound security-group rule and no published Docker host port.
- No `LINE_ALLOW_ALL_USERS`.
- Do not inspect or copy `/var/lib/hermes` into Git.
- Do not apply this capability profile to the preserved Telegram main agent.
- Pairing (`hermes pairing approve line`) is still not in the pinned image;
  first-user enrollment remains the allowlist procedure.

## First implementation slice

1. Record the production profile in operator notes only (this file).
2. Choose and pin a Hermes image that actually supports Codex sol, memory
   review, and `image_gen` — or document which of those the current digest
   already has.
3. Decide image-gen provider before deploy (Codex, Tool Gateway, or a
   separate key). Unknown is not "enable the toolset and hope".
4. New greenfield deploy; smoketest host remains stopped until needed.
