#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_credentials
require_tools aws
mapfile -t deployment_ids < <(discover_deployment_ids)
printf '%-17s %-12s %-8s %s\n' 'DEPLOYMENT' 'INSTANCE' 'SSM' 'SUMMARY'
for deployment_id in "${deployment_ids[@]}"; do
  instance_id=""
  instance_id="$(instance_id_for_any_state "${deployment_id}" 2>/dev/null || true)"
  if [[ -z "${instance_id}" ]]; then
    printf '%-17s %-12s %-8s %s\n' "${deployment_id}" 'absent' 'unknown' 'state foundation only'
    continue
  fi
  state="$(instance_state "${instance_id}")"
  ping="$(ssm_ping_status "${instance_id}")"
  printf '%-17s %-12s %-8s %s\n' "${deployment_id}" "${state}" "${ping}" "instance ${instance_id}"
done
