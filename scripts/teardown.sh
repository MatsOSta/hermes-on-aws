#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

deployment_id="${1:-}"
validate_deployment_id "${deployment_id}"
aws_preflight
require_tools tofu
work_dir="$(operator_dir "${deployment_id}")"
mkdir -p -- "${work_dir}/tofu-data-host"
prepare_host_backend "${deployment_id}"
plan_show_confirm_apply "${deployment_id}" "${HOST_ROOT}" "${work_dir}/tofu-data-host" \
  "${work_dir}/host-destroy.tfplan" "host destruction" -destroy -var="deployment_id=${deployment_id}"
echo "Host resources for ${deployment_id} were destroyed; the state foundation remains."
