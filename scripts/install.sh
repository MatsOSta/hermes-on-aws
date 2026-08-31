#!/usr/bin/env bash

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

readonly HERMES_IMAGE='nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e'
deployment_id="${1:-}"
validate_deployment_id "${deployment_id}"
require_credentials
require_tools aws jq
instance_id="$(instance_id_for "${deployment_id}")"
[[ "$(ssm_ping_status "${instance_id}")" == "Online" ]] || die "instance ${instance_id} is not SSM Online"
command_id="$(send_ssm_command "${instance_id}" "Install Docker and pinned Hermes gateway" \
  'set -euo pipefail' \
  'dnf install -y docker' \
  'systemctl enable --now docker' \
  'install -d -m 0700 /var/lib/hermes' \
  "docker pull '${HERMES_IMAGE}'" \
  'if docker container inspect hermes-gateway >/dev/null 2>&1; then docker rm -f hermes-gateway; fi' \
  "docker run -d --name hermes-gateway --restart unless-stopped --volume /var/lib/hermes:/opt/data '${HERMES_IMAGE}' hermes gateway run")"
wait_and_print_ssm_command "${command_id}" "${instance_id}"
echo "Docker and Hermes gateway container are running. Connect with: ./hermes.sh ssm ${deployment_id} and run docker exec -it hermes-gateway hermes setup gateway"
