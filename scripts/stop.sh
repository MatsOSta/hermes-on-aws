#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
deployment_id="${1:-}"
validate_deployment_id "${deployment_id}"
aws_preflight
instance_id="$(instance_id_for "${deployment_id}")"
state="$(instance_state "${instance_id}")"
if [[ "${state}" == "stopped" ]]; then echo "${instance_id} is already stopped."; exit 0; fi
[[ "${state}" == "running" ]] || die "instance ${instance_id} cannot be stopped from state ${state}"
aws --region "${AWS_REGION}" ec2 stop-instances --instance-ids "${instance_id}" >/dev/null
aws --region "${AWS_REGION}" ec2 wait instance-stopped --instance-ids "${instance_id}"
echo "Instance ${instance_id} is stopped."
