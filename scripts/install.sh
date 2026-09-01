#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail
# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

readonly HERMES_IMAGE='nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e'
deployment_id="${1:-}"
validate_deployment_id "${deployment_id}"
aws_preflight
require_tools jq base64 tr
instance_id="$(instance_id_for "${deployment_id}")"
expected_volume_id="$(data_volume_id_for "${deployment_id}" "${instance_id}")"
[[ "$(ssm_ping_status "${instance_id}")" == "Online" ]] || die "instance ${instance_id} is not SSM Online"

echo "Step 1/3: Mounting reviewed data volume, installing Docker, and pulling Hermes image..."
mount_helper="${REPO_ROOT}/scripts/support/mount-hermes-data-volume.sh"
mount_payload="$(base64 <"${mount_helper}" | tr -d '\n')"
command_id="$(send_ssm_command "${instance_id}" "Mount Hermes data volume and install Docker" \
  'set -euo pipefail' \
  'dnf install -y docker xfsprogs' \
  'install -d -m 0700 /var/lib/hermes' \
  "command -v base64 >/dev/null 2>&1 || { echo 'Hermes data-volume installer requires base64.' >&2; exit 1; }" \
  'umask 077' \
  'mount_helper=$(mktemp /tmp/hermes-mount-helper.XXXXXX)' \
  'trap '\''rm -f -- "${mount_helper}"'\'' EXIT' \
  "printf '%s' '${mount_payload}' | base64 -d >\"\${mount_helper}\"" \
  'chmod 0700 "${mount_helper}"' \
  "\"\${mount_helper}\" '${expected_volume_id}'" \
  'rm -f -- "${mount_helper}"' \
  'systemctl enable --now docker' \
  "docker pull '${HERMES_IMAGE}'")"
wait_and_print_ssm_command "${command_id}" "${instance_id}" \
  "${HERMES_SSM_DEADLINE_SECONDS:-600}" "${HERMES_SSM_POLL_INTERVAL_SECONDS:-5}"

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
