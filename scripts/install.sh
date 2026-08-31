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

echo "Step 1/3: Installing Docker and pulling Hermes image..."
command_id="$(send_ssm_command "${instance_id}" "Install Docker and pull pinned Hermes image" \
  'set -euo pipefail' \
  'dnf install -y docker' \
  'systemctl enable --now docker' \
  'install -d -m 0700 /var/lib/hermes' \
  "docker pull '${HERMES_IMAGE}'")"
wait_and_print_ssm_command "${command_id}" "${instance_id}"

cat <<EOF

Step 2/3: Run the setup wizard.

  ./hermes.sh ssm ${deployment_id}

Then inside the session (as root):

  docker run --rm -it --volume /var/lib/hermes:/opt/data \\
    '${HERMES_IMAGE}' setup

Configure model, tools, and Telegram gateway. Exit the SSM session when done.

When ready, run step 3:

  ./hermes.sh start-gateway ${deployment_id}

EOF
