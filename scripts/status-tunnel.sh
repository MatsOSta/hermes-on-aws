#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

deployment_id="${1:-}"
validate_deployment_id "${deployment_id}"
(( $# == 1 )) || die 'status-tunnel accepts only a deployment ID'
aws_preflight
require_tools jq base64 tr
instance_id="$(instance_id_for "${deployment_id}")"
[[ "$(ssm_ping_status "${instance_id}")" == "Online" ]] || die "instance ${instance_id} is not SSM Online"

runtime_helper="${REPO_ROOT}/scripts/support/run-hermes-tunnel.sh"
runtime_payload="$(base64 <"${runtime_helper}" | tr -d '\n')"
command_id="$(send_ssm_command "${instance_id}" "Hermes cloudflared tunnel status" \
  'set -euo pipefail' \
  "command -v base64 >/dev/null 2>&1 || { echo 'Hermes tunnel runtime requires base64, but the binary was not found.' >&2; exit 1; }" \
  "runtime_helper=\$(mktemp /tmp/hermes-tunnel-runtime.XXXXXX)" \
  "trap 'rm -f -- \"\${runtime_helper}\"' EXIT" \
  "printf '%s' '${runtime_payload}' | base64 -d >\"\${runtime_helper}\"" \
  'chmod 0700 "${runtime_helper}"' \
  '"${runtime_helper}" status')"
wait_and_print_ssm_command "${command_id}" "${instance_id}" \
  "${HERMES_SSM_DEADLINE_SECONDS:-600}" "${HERMES_SSM_POLL_INTERVAL_SECONDS:-5}"
