#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

deployment_id="${1:-}"
validate_deployment_id "${deployment_id}"
aws_preflight
require_tools tofu jq cp
work_dir="$(operator_dir "${deployment_id}")"
state_file="${work_dir}/state-foundation.tfstate"
mkdir -p -- "${work_dir}/tofu-data-host" "${work_dir}/tofu-data-state-purge"

prepare_host_backend "${deployment_id}"
TF_DATA_DIR="${work_dir}/tofu-data-host" tofu -chdir="${HOST_ROOT}" plan -destroy -input=false \
  -out="${work_dir}/host-purge.tfplan" -var="deployment_id=${deployment_id}"
TF_DATA_DIR="${work_dir}/tofu-data-host" tofu -chdir="${HOST_ROOT}" show "${work_dir}/host-purge.tfplan"
confirm_exact "BREAK-GLASS: apply the shown host-destroy plan for ${deployment_id}." "destroy-host-${deployment_id}"
TF_DATA_DIR="${work_dir}/tofu-data-host" tofu -chdir="${HOST_ROOT}" apply -input=false "${work_dir}/host-purge.tfplan"

[[ -f "${state_file}" ]] || die "state foundation bootstrap state is missing at ${state_file}; host was destroyed, but the bucket and KMS key were not touched"
purge_root="${work_dir}/greenfield-state-purge"
mkdir -p -- "${purge_root}"
cp -- "${STATE_ROOT}"/*.tf "${STATE_ROOT}/.terraform.lock.hcl" "${purge_root}/"
cat >"${purge_root}/operator_override.tf" <<'EOF'
resource "aws_kms_key" "state" {
  lifecycle { prevent_destroy = false }
}
resource "aws_s3_bucket" "state" {
  lifecycle { prevent_destroy = false }
}
EOF
TF_DATA_DIR="${work_dir}/tofu-data-state-purge" tofu -chdir="${purge_root}" init -backend=false -input=false
TF_DATA_DIR="${work_dir}/tofu-data-state-purge" tofu -chdir="${purge_root}" plan -destroy -input=false \
  -state="${state_file}" -out="${work_dir}/state-foundation-destroy.tfplan" -var="deployment_id=${deployment_id}"
TF_DATA_DIR="${work_dir}/tofu-data-state-purge" tofu -chdir="${purge_root}" show "${work_dir}/state-foundation-destroy.tfplan"
confirm_exact "BREAK-GLASS: apply the shown state-foundation destroy plan for ${deployment_id}." "purge-state-${deployment_id}"
empty_versioned_bucket "$(state_bucket_name "${deployment_id}")"
TF_DATA_DIR="${work_dir}/tofu-data-state-purge" tofu -chdir="${purge_root}" apply -input=false "${work_dir}/state-foundation-destroy.tfplan"
echo "Host and state foundation for ${deployment_id} were purged. KMS deletion uses its configured waiting period."
