#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_alias_registry
aws_preflight
if ! deployment_output="$(discover_deployment_ids)"; then
  die "deployment discovery failed; resolve the AWS error above and retry"
fi
mapfile -t deployment_ids <<<"${deployment_output}"
[[ -n "${deployment_output}" ]] || deployment_ids=()
show_aliases=false
(( ${#DEPLOYMENT_ALIASES[@]} == 0 )) || show_aliases=true
if [[ "${show_aliases}" == true ]]; then
  printf '%-20s %-17s %-12s %-8s %s\n' 'ALIAS' 'DEPLOYMENT' 'INSTANCE' 'SSM' 'SUMMARY'
else
  printf '%-17s %-12s %-8s %s\n' 'DEPLOYMENT' 'INSTANCE' 'SSM' 'SUMMARY'
fi
for deployment_id in "${deployment_ids[@]}"; do
  deployment_alias='-'
  deployment_alias="$(alias_for_deployment_id "${deployment_id}" 2>/dev/null || true)"
  deployment_alias="${deployment_alias:--}"
  instance_id=""
  instance_id="$(instance_id_for_any_state "${deployment_id}" 2>/dev/null || true)"
  if [[ -z "${instance_id}" ]]; then
    if [[ "${show_aliases}" == true ]]; then
      printf '%-20s %-17s %-12s %-8s %s\n' "${deployment_alias}" "${deployment_id}" 'absent' 'unknown' 'state foundation only'
    else
      printf '%-17s %-12s %-8s %s\n' "${deployment_id}" 'absent' 'unknown' 'state foundation only'
    fi
    continue
  fi
  state="$(instance_state "${instance_id}")"
  ping="$(ssm_ping_status "${instance_id}")"
  if [[ "${show_aliases}" == true ]]; then
    printf '%-20s %-17s %-12s %-8s %s\n' "${deployment_alias}" "${deployment_id}" "${state}" "${ping}" "instance ${instance_id}"
  else
    printf '%-17s %-12s %-8s %s\n' "${deployment_id}" "${state}" "${ping}" "instance ${instance_id}"
  fi
done
