#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
deployment_id="${1:-}"
validate_deployment_id "${deployment_id}"
require_credentials
require_tools aws
instance_id="$(instance_id_for "${deployment_id}")"
state="$(instance_state "${instance_id}")"
if [[ "${state}" == "running" ]]; then echo "${instance_id} is already running."; exit 0; fi
[[ "${state}" == "stopped" ]] || die "instance ${instance_id} cannot be started from state ${state}"
aws --region "${AWS_REGION}" ec2 start-instances --instance-ids "${instance_id}" >/dev/null
aws --region "${AWS_REGION}" ec2 wait instance-running --instance-ids "${instance_id}"
echo "Instance ${instance_id} is running."
