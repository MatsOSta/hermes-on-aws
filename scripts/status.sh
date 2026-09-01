#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

deployment_id="${1:-}"
aws_preflight
require_tools jq
if [[ -z "${deployment_id}" ]]; then
  exec "${REPO_ROOT}/scripts/list.sh"
fi
validate_deployment_id "${deployment_id}"
instance_id="$(instance_id_for_any_state "${deployment_id}")"
state="$(instance_state "${instance_id}")"
ping="$(ssm_ping_status "${instance_id}")"
docker_status="unknown"
container_status="unknown"
if [[ "${ping}" == "Online" ]]; then
  command_id="$(send_ssm_command "${instance_id}" "Hermes operator status" \
    'if systemctl is-active --quiet docker; then echo docker=running; else echo docker=stopped; fi' \
    "if docker inspect --format='{{.State.Running}}' hermes-gateway 2>/dev/null | grep -qx true; then echo container=running; else echo container=stopped; fi")"
  aws --region "${AWS_REGION}" ssm wait command-executed --command-id "${command_id}" --instance-id "${instance_id}" || true
  output="$(aws --region "${AWS_REGION}" ssm get-command-invocation --command-id "${command_id}" \
    --instance-id "${instance_id}" --query StandardOutputContent --output text 2>/dev/null || true)"
  docker_status="$(sed -n 's/^docker=//p' <<<"${output}")"
  container_status="$(sed -n 's/^container=//p' <<<"${output}")"
  docker_status="${docker_status:-unknown}"
  container_status="${container_status:-unknown}"
fi
printf 'Deployment:       %s\nInstance ID:      %s\nInstance state:   %s\nSSM ping:         %s\nDocker:           %s\nHermes gateway:   %s\n' \
  "${deployment_id}" "${instance_id}" "${state}" "${ping}" "${docker_status}" "${container_status}"
