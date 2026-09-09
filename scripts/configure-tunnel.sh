#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib.sh"

readonly REMOTE_HELPER='/usr/local/sbin/configure-cloudflare-tunnel'
readonly REMOTE_RUNTIME_HELPER='/usr/local/sbin/run-hermes-tunnel'
readonly LOCAL_HELPER="${REPO_ROOT}/scripts/support/configure-cloudflare-tunnel.py"
readonly LOCAL_RUNTIME_HELPER="${REPO_ROOT}/scripts/support/run-hermes-tunnel.sh"

deployment_id="${1:-}"
validate_deployment_id "${deployment_id}"
for helper in "${LOCAL_HELPER}" "${LOCAL_RUNTIME_HELPER}"; do
  [[ -f "${helper}" && ! -L "${helper}" ]] || die "reviewed Cloudflare helper is missing or unsafe"
done
require_tools aws jq base64
aws_preflight
instance_id="$(instance_id_for "${deployment_id}")"
expected_volume_id="$(data_volume_id_for "${deployment_id}" "${instance_id}")"
[[ "$(instance_state "${instance_id}")" == running ]] || die "instance ${instance_id} is not running"
[[ "$(ssm_ping_status "${instance_id}")" == Online ]] || die "instance ${instance_id} is not SSM Online"

helper_b64="$(base64 -w 0 -- "${LOCAL_HELPER}")"
runtime_b64="$(base64 -w 0 -- "${LOCAL_RUNTIME_HELPER}")"
command_id="$(send_ssm_command "${instance_id}" "Install reviewed Cloudflare tunnel helpers" \
  "set -eu" \
  "umask 077" \
  "printf '%s' '${helper_b64}' | base64 -d > '${REMOTE_HELPER}.new'" \
  "printf '%s' '${runtime_b64}' | base64 -d > '${REMOTE_RUNTIME_HELPER}.new'" \
  "chown root:root '${REMOTE_HELPER}.new' '${REMOTE_RUNTIME_HELPER}.new'" \
  "chmod 0700 '${REMOTE_HELPER}.new' '${REMOTE_RUNTIME_HELPER}.new'" \
  "python3 -m py_compile '${REMOTE_HELPER}.new'" \
  "bash -n '${REMOTE_RUNTIME_HELPER}.new'" \
  "mv -f '${REMOTE_HELPER}.new' '${REMOTE_HELPER}'" \
  "mv -f '${REMOTE_RUNTIME_HELPER}.new' '${REMOTE_RUNTIME_HELPER}'")"
wait_and_print_ssm_command "${command_id}" "${instance_id}" \
  "${HERMES_SSM_DEADLINE_SECONDS:-600}" "${HERMES_SSM_POLL_INTERVAL_SECONDS:-5}"

cat <<'EOF'
Enter the scoped Cloudflare API token only in the remote hidden prompt.
No Cloudflare or connector credential is accepted by hermes.sh, placed in SSM command parameters, or printed.
EOF
parameters="$(jq -cn --arg command "sudo -n ${REMOTE_HELPER} ${deployment_id} ${expected_volume_id}" '{command:[$command]}')"
aws --region "${AWS_REGION}" ssm start-session --target "${instance_id}" \
  --document-name AWS-StartInteractiveCommand --parameters "${parameters}"
