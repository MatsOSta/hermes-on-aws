#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
deployment_id="${1:-}"
validate_deployment_id "${deployment_id}"
require_credentials
require_tools aws
instance_id="$(instance_id_for "${deployment_id}")"
[[ "$(ssm_ping_status "${instance_id}")" == "Online" ]] || die "instance ${instance_id} is not SSM Online"
exec aws --region "${AWS_REGION}" ssm start-session --target "${instance_id}"
