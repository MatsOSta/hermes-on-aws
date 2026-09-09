#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib.sh"

readonly REMOTE_HELPER='/usr/local/sbin/configure-hermes-line'
readonly LOCAL_HELPER="${REPO_ROOT}/scripts/support/configure-hermes-line.py"

deployment_id="${1:-}"
validate_deployment_id "${deployment_id}"
[[ -f "${LOCAL_HELPER}" && ! -L "${LOCAL_HELPER}" ]] || die "reviewed LINE configuration helper is missing or unsafe"
require_tools aws jq base64
aws_preflight
instance_id="$(instance_id_for "${deployment_id}")"
expected_volume_id="$(data_volume_id_for "${deployment_id}" "${instance_id}")"
[[ "$(instance_state "${instance_id}")" == running ]] || die "instance ${instance_id} is not running"
[[ "$(ssm_ping_status "${instance_id}")" == Online ]] || die "instance ${instance_id} is not SSM Online"

helper_b64="$(base64 -w 0 -- "${LOCAL_HELPER}")"
command_id="$(send_ssm_command "${instance_id}" "Install reviewed LINE configuration helper" \
  "set -eu" \
  "umask 077" \
  "printf '%s' '${helper_b64}' | base64 -d > '${REMOTE_HELPER}.new'" \
  "chown root:root '${REMOTE_HELPER}.new'" \
  "chmod 0700 '${REMOTE_HELPER}.new'" \
  "python3 -m py_compile '${REMOTE_HELPER}.new'" \
  "mv -f '${REMOTE_HELPER}.new' '${REMOTE_HELPER}'")"
wait_and_print_ssm_command "${command_id}" "${instance_id}" \
  "${HERMES_SSM_DEADLINE_SECONDS:-600}" "${HERMES_SSM_POLL_INTERVAL_SECONDS:-5}"

cat <<'EOF'
Enter LINE credentials only in the remote hidden prompts that follow.
No credential is accepted by hermes.sh or placed in SSM command parameters.
EOF
parameters="$(jq -cn --arg command "sudo -n ${REMOTE_HELPER} ${expected_volume_id}" '{command:[$command]}')"
aws --region "${AWS_REGION}" ssm start-session --target "${instance_id}" \
  --document-name AWS-StartInteractiveCommand --parameters "${parameters}"
