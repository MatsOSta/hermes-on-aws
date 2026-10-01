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

## Launch split

### MUST be done before EC2 launch

- Use a new greenfield ID. Do not reuse `hms-ae1485be4182` or the Telegram
  main-agent host.
- Operator workstation: reviewed AWS account `450895596262` in `eu-north-1`,
  `AWS_PROFILE=platform-lab-tofu`, OpenTofu, jq.
- Local alias may exist; deploy still takes the canonical `hms-` ID for both
  typed approvals.
- Stop at unexpected replacement, shared resources, IAM expansion, or a
  network/security-boundary change in either saved plan.
- Model, image generation, LINE channel, and Cloudflare token are not deploy
  blockers. They happen after SSM Online.

### MUST be done AFTER the instance is SSM Online

- Record the LINE platform intent and prepare the host/image:

  ```sh
  ./hermes.sh install "$DEPLOYMENT_ID" --platform line
  ```

- Provision and verify the bounded Cloudflare tunnel and its new hostname:

  ```sh
  ./hermes.sh configure-tunnel "$DEPLOYMENT_ID"
  ```

- Securely configure LINE only after the public URL exists:

  ```sh
  ./hermes.sh configure-line "$DEPLOYMENT_ID"
  ```

  Enter secrets only through the command's hidden prompts. Never use
  `LINE_ALLOW_ALL_USERS`; keep the first-user enrollment as the explicit
  allowlist procedure until native LINE pairing is present in the pinned image.
- In the interactive Hermes setup, configure `gpt-5.6-sol` via
  `openai-codex`, the already-decided image-generation provider, default LINE
  features, automatic memory, and the normal review cadence. Do not claim
  image generation works until the selected provider is actually configured
  and tested.
- Verify tunnel readiness, public health, LINE console webhook settings, the
  first-user allowlist, and a real message round trip. Treat each as pending
  until independently confirmed.

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

## First-time pitfalls (2026 wife host)

These are live mismatches between helpers and the pinned image. Fix the helper
or run from the branch that already has the fix. Do not re-prompt Cloudflare or
LINE secrets to debug the next fail-closed check.

- Data-volume mount is `rw,nosuid,nodev` (no `noexec`). Helpers that require
  `noexec` fail with `mount options are unsafe`. That fix is `d0ec1cb` on this
  branch. Do not run `configure-line` / `configure-tunnel` from a master-based
  branch that still requires `noexec`.
- `configure-tunnel` then `configure-line`. `LINE_PUBLIC_URL` is the visible
  prompt, not a `hermes.sh` flag. Value is `https://<edge-hex>.<zone>` with no
  path.
- Pinned gateway listens on **8642**, not 8646. Ingress to 8646 yields Cloudflare
  `502` even when `status-tunnel` is connected. Public health on this image is
  `/health`, not `/line/webhook/health`.
- Gateway may create `.env` and own `/var/lib/hermes` as non-root. Do not cat
  `.env`. Adopt regular-file mode 0600; do not require the mount root to be
  uid 0.
- `enable_line` is a throwaway container and does not restart `hermes-gateway`.
  A pre-v12 `config.yaml` will not auto-migrate. LINE webhook 404 on 8642 is
  separate from tunnel 502.
- One new `edge-*` DNS CNAME per host is expected. Leave smoketest records.
  Matching `configure-line` rerun is safe once values are saved.
