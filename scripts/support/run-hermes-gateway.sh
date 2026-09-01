#!/usr/bin/env bash

set -euo pipefail

readonly HERMES_IMAGE='nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e'
readonly HERMES_CONTAINER_NAME='hermes-gateway'
readonly HERMES_DATA_BIND='/var/lib/hermes:/opt/data'
readonly STABILITY_SECONDS="${HERMES_GATEWAY_STABILITY_SECONDS:-3}"
recreate=false

if [[ "$(id -u)" != 0 ]]; then
  echo 'Hermes gateway runtime must be run as root.' >&2
  exit 1
fi
case "${1:-}" in
  '') ;;
  --recreate) recreate=true ;;
  *) echo "Invalid gateway runtime option: $1" >&2; exit 2 ;;
esac
(( $# <= 1 )) || { echo 'Gateway runtime accepts only --recreate.' >&2; exit 2; }
[[ "${STABILITY_SECONDS}" =~ ^[0-9]+$ ]] || { echo 'Invalid stability interval.' >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo 'Docker is required.' >&2; exit 1; }
docker info >/dev/null
if [[ "$(stat -c '%F' -- /var/lib/hermes 2>/dev/null || true)" != directory ]]; then
  echo 'Hermes data directory /var/lib/hermes does not exist; run Hermes setup first.' >&2
  exit 1
fi

inspect_container() {
  docker container inspect "${HERMES_CONTAINER_NAME}" >/dev/null
}

contract_mismatches() {
  local existing_image existing_privileged existing_network_mode existing_restart_policy
  local existing_binds existing_mounts existing_volumes_from existing_cap_add
  local existing_port_bindings existing_publish_all_ports existing_command
  existing_image="$(docker container inspect --format '{{.Config.Image}}' "${HERMES_CONTAINER_NAME}")"
  existing_privileged="$(docker container inspect --format '{{.HostConfig.Privileged}}' "${HERMES_CONTAINER_NAME}")"
  existing_network_mode="$(docker container inspect --format '{{.HostConfig.NetworkMode}}' "${HERMES_CONTAINER_NAME}")"
  existing_restart_policy="$(docker container inspect --format '{{.HostConfig.RestartPolicy.Name}}' "${HERMES_CONTAINER_NAME}")"
  existing_binds="$(docker container inspect --format '{{json .HostConfig.Binds}}' "${HERMES_CONTAINER_NAME}")"
  existing_mounts="$(docker container inspect --format '{{json .HostConfig.Mounts}}' "${HERMES_CONTAINER_NAME}")"
  existing_volumes_from="$(docker container inspect --format '{{json .HostConfig.VolumesFrom}}' "${HERMES_CONTAINER_NAME}")"
  existing_cap_add="$(docker container inspect --format '{{json .HostConfig.CapAdd}}' "${HERMES_CONTAINER_NAME}")"
  existing_port_bindings="$(docker container inspect --format '{{json .HostConfig.PortBindings}}' "${HERMES_CONTAINER_NAME}")"
  existing_publish_all_ports="$(docker container inspect --format '{{.HostConfig.PublishAllPorts}}' "${HERMES_CONTAINER_NAME}")"
  existing_command="$(docker container inspect --format '{{json .Config.Cmd}}' "${HERMES_CONTAINER_NAME}")"

  [[ "${existing_image}" == "${HERMES_IMAGE}" ]] || echo 'image is not the pinned Hermes image'
  [[ "${existing_command}" == '["hermes","gateway","run"]' ]] || echo 'configured command is not hermes gateway run'
  [[ "${existing_binds}" == '["/var/lib/hermes:/opt/data"]' ]] || echo 'bind mounts do not exactly match /var/lib/hermes:/opt/data'
  [[ "${existing_restart_policy}" == unless-stopped ]] || echo 'restart policy is not unless-stopped'
  [[ "${existing_privileged}" == false ]] || echo 'privileged mode is not false'
  [[ "${existing_cap_add}" == null || "${existing_cap_add}" == '[]' ]] || echo 'added Linux capabilities are present'
  [[ "${existing_port_bindings}" == null || "${existing_port_bindings}" == '{}' ]] || echo 'published port bindings are present'
  [[ "${existing_publish_all_ports}" == false ]] || echo 'PublishAllPorts is not false'
  [[ "${existing_network_mode}" != host ]] || echo 'network mode is host'
  [[ "${existing_mounts}" == null || "${existing_mounts}" == '[]' ]] || echo 'HostConfig.Mounts is not empty'
  [[ "${existing_volumes_from}" == null || "${existing_volumes_from}" == '[]' ]] || echo 'VolumesFrom is not empty'
}

verify_stable() {
  local phase="$1"
  if [[ "$(docker container inspect --format '{{.State.Running}}' "${HERMES_CONTAINER_NAME}")" != true ]]; then
    echo "Container ${HERMES_CONTAINER_NAME} did not remain running after ${phase}." >&2
    docker logs --tail 50 "${HERMES_CONTAINER_NAME}" >&2 || true
    return 1
  fi
  sleep "${STABILITY_SECONDS}"
  if [[ "$(docker container inspect --format '{{.State.Running}}' "${HERMES_CONTAINER_NAME}")" != true ]]; then
    echo "Container ${HERMES_CONTAINER_NAME} did not remain running after ${phase}." >&2
    docker logs --tail 50 "${HERMES_CONTAINER_NAME}" >&2 || true
    return 1
  fi
}

if inspect_container 2>/dev/null; then
  if [[ "${recreate}" == true ]]; then
    docker container rm -f "${HERMES_CONTAINER_NAME}" >/dev/null
  else
    if ! mismatch_output="$(contract_mismatches)"; then
      echo "Unable to validate container ${HERMES_CONTAINER_NAME}; no changes were made." >&2
      exit 1
    fi
    mapfile -t mismatches <<<"${mismatch_output}"
    [[ -n "${mismatch_output}" ]] || mismatches=()
    if (( ${#mismatches[@]} > 0 )); then
      echo "Container ${HERMES_CONTAINER_NAME} does not match the expected runtime contract:" >&2
      printf -- '- %s\n' "${mismatches[@]}" >&2
      echo 'Explicit --recreate is required; no changes were made.' >&2
      exit 1
    fi
    if [[ "$(docker container inspect --format '{{.State.Running}}' "${HERMES_CONTAINER_NAME}")" == true ]]; then
      verify_stable retain
      echo "Container ${HERMES_CONTAINER_NAME} retained and stable."
      exit 0
    fi
    docker container start "${HERMES_CONTAINER_NAME}" >/dev/null
    verify_stable start
    echo "Container ${HERMES_CONTAINER_NAME} started and stable."
    exit 0
  fi
fi

docker run -d \
  --name "${HERMES_CONTAINER_NAME}" \
  --restart unless-stopped \
  --volume "${HERMES_DATA_BIND}" \
  "${HERMES_IMAGE}" \
  hermes gateway run >/dev/null
verify_stable create
echo "Container ${HERMES_CONTAINER_NAME} created and stable."
