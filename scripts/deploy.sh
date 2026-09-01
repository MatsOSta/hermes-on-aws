#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

deployment_id="${1:-}"
validate_deployment_id "${deployment_id}"
aws_preflight
require_tools tofu jq
work_dir="$(operator_dir "${deployment_id}")"
mkdir -p -- "${work_dir}/tofu-data-state" "${work_dir}/tofu-data-host"

if state_bucket_exists "${deployment_id}"; then
  echo "State bucket $(state_bucket_name "${deployment_id}") already exists; skipping state foundation."
else
  state_file="${work_dir}/state-foundation.tfstate"
  state_plan="${work_dir}/state-foundation.tfplan"
  TF_DATA_DIR="${work_dir}/tofu-data-state" tofu -chdir="${STATE_ROOT}" init -backend=false -input=false
  plan_show_confirm_apply "${deployment_id}" "${STATE_ROOT}" "${work_dir}/tofu-data-state" \
    "${state_plan}" "state foundation creation" -state="${state_file}" -var="deployment_id=${deployment_id}"
fi

prepare_host_backend "${deployment_id}"
host_plan="${work_dir}/host.tfplan"
plan_show_confirm_apply "${deployment_id}" "${HOST_ROOT}" "${work_dir}/tofu-data-host" \
  "${host_plan}" "host creation" -var="deployment_id=${deployment_id}"
instance_id="$(instance_id_for "${deployment_id}")"
echo "Waiting for ${instance_id} to become SSM Online..."
wait_for_ssm "${instance_id}" 300
echo "Instance ${instance_id} is SSM Online. Next: ./hermes.sh install ${deployment_id}"
