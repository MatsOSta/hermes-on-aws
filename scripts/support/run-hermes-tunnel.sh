#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail

readonly TUNNEL_IMAGE='cloudflare/cloudflared@sha256:51c9cefcb4569df44e1ad403ab1d3d8065aa8e84339bcfc6aee75502e1140339'
readonly TUNNEL_CONTAINER_NAME='hermes-cloudflared'
readonly TUNNEL_NETWORK_NAME='hermes-tunnel-net'
readonly GATEWAY_CONTAINER_NAME='hermes-gateway'
readonly TOKEN_DIR='/var/lib/hermes/cloudflare-tunnel'
readonly TOKEN_FILE="${TOKEN_DIR}/token"
readonly TOKEN_MOUNT_PATH='/run/secrets/cloudflared-token'
# Real tunnel tokens are a few hundred bytes; this bound only rejects
# pathological input and is never used to echo the token itself.
readonly TOKEN_MAX_BYTES=4096
readonly STABILITY_SECONDS="${HERMES_TUNNEL_STABILITY_SECONDS:-3}"

if [[ "$(id -u)" != 0 ]]; then
  echo 'Hermes tunnel runtime must be run as root.' >&2
  exit 1
fi

subcommand="${1:-}"
[[ -n "${subcommand}" ]] && shift
recreate=false
case "${subcommand}" in
  start)
    case "${1:-}" in
      '') ;;
      --recreate) recreate=true ;;
      *) echo "Invalid start option: ${1}" >&2; exit 2 ;;
    esac
    (( $# <= 1 )) || { echo 'start accepts only --recreate.' >&2; exit 2; }
    ;;
  status|stop)
    (( $# == 0 )) || { echo "${subcommand} accepts no arguments." >&2; exit 2; }
    ;;
  *)
    echo "Invalid tunnel runtime subcommand: ${subcommand}; expected start, status, or stop." >&2
    exit 2
    ;;
esac
[[ "${STABILITY_SECONDS}" =~ ^[0-9]+$ ]] || { echo 'Invalid stability interval.' >&2; exit 2; }

require_docker() {
  command -v docker >/dev/null 2>&1 || { echo 'Docker is required.' >&2; exit 1; }
  docker info >/dev/null
}

inspect_tunnel_container() {
  docker container inspect "${TUNNEL_CONTAINER_NAME}" >/dev/null
}

# Compares the running container's configuration against the reviewed
# contract. Used both to gate mutation on `start` and to refuse to touch an
# unverified same-named container on `status`/`stop`.
contract_mismatches() {
  local existing_image existing_privileged existing_network_mode existing_restart_policy
  local existing_binds existing_mounts existing_volumes_from existing_cap_add existing_cap_drop
  local existing_port_bindings existing_publish_all_ports existing_command
  local existing_readonly existing_security_opt existing_user existing_networks
  existing_image="$(docker container inspect --format '{{.Config.Image}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_user="$(docker container inspect --format '{{.Config.User}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_privileged="$(docker container inspect --format '{{.HostConfig.Privileged}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_network_mode="$(docker container inspect --format '{{.HostConfig.NetworkMode}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_restart_policy="$(docker container inspect --format '{{.HostConfig.RestartPolicy.Name}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_binds="$(docker container inspect --format '{{json .HostConfig.Binds}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_mounts="$(docker container inspect --format '{{json .HostConfig.Mounts}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_volumes_from="$(docker container inspect --format '{{json .HostConfig.VolumesFrom}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_cap_add="$(docker container inspect --format '{{json .HostConfig.CapAdd}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_cap_drop="$(docker container inspect --format '{{json .HostConfig.CapDrop}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_port_bindings="$(docker container inspect --format '{{json .HostConfig.PortBindings}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_publish_all_ports="$(docker container inspect --format '{{.HostConfig.PublishAllPorts}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_readonly="$(docker container inspect --format '{{.HostConfig.ReadonlyRootfs}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_security_opt="$(docker container inspect --format '{{json .HostConfig.SecurityOpt}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_command="$(docker container inspect --format '{{json .Config.Cmd}}' "${TUNNEL_CONTAINER_NAME}")"
  existing_networks="$(docker container inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' "${TUNNEL_CONTAINER_NAME}")"

  [[ "${existing_image}" == "${TUNNEL_IMAGE}" ]] || echo 'image is not the pinned cloudflared image'
  [[ "${existing_command}" == '["tunnel","--no-autoupdate","run","--token-file","'"${TOKEN_MOUNT_PATH}"'"]' ]] || echo 'configured command is not the expected tunnel run command'
  [[ "${existing_binds}" == '["'"${TOKEN_FILE}"':'"${TOKEN_MOUNT_PATH}"':ro"]' ]] || echo 'bind mounts do not exactly match the read-only token file'
  [[ "${existing_restart_policy}" == unless-stopped ]] || echo 'restart policy is not unless-stopped'
  [[ "${existing_privileged}" == false ]] || echo 'privileged mode is not false'
  [[ "${existing_user}" == '0:0' ]] || echo 'container user is not 0:0'
  [[ "${existing_cap_add}" == null || "${existing_cap_add}" == '[]' ]] || echo 'added Linux capabilities are present'
  [[ "${existing_cap_drop}" == '["ALL"]' ]] || echo 'capabilities are not fully dropped (CapDrop != ["ALL"])'
  [[ "${existing_port_bindings}" == null || "${existing_port_bindings}" == '{}' ]] || echo 'published port bindings are present'
  [[ "${existing_publish_all_ports}" == false ]] || echo 'PublishAllPorts is not false'
  [[ "${existing_network_mode}" == "${TUNNEL_NETWORK_NAME}" ]] || echo 'network mode is not the private tunnel network'
  [[ "${existing_networks}" == "${TUNNEL_NETWORK_NAME} " ]] || echo 'attached networks are not exactly the private tunnel network'
  [[ "${existing_mounts}" == null || "${existing_mounts}" == '[]' ]] || echo 'HostConfig.Mounts is not empty'
  [[ "${existing_volumes_from}" == null || "${existing_volumes_from}" == '[]' ]] || echo 'VolumesFrom is not empty'
  [[ "${existing_readonly}" == true ]] || echo 'root filesystem is not read-only'
  [[ "${existing_security_opt}" == '["no-new-privileges"]' ]] || echo 'security options are not exactly no-new-privileges'
}

verify_stable() {
  local phase="$1"
  if [[ "$(docker container inspect --format '{{.State.Running}}' "${TUNNEL_CONTAINER_NAME}")" != true ]]; then
    echo "Container ${TUNNEL_CONTAINER_NAME} did not remain running after ${phase}." >&2
    return 1
  fi
  sleep "${STABILITY_SECONDS}"
  if [[ "$(docker container inspect --format '{{.State.Running}}' "${TUNNEL_CONTAINER_NAME}")" != true ]]; then
    echo "Container ${TUNNEL_CONTAINER_NAME} did not remain running after ${phase}." >&2
    return 1
  fi
}

case "${subcommand}" in
  status)
    require_docker
    if ! inspect_tunnel_container 2>/dev/null; then
      echo "Container ${TUNNEL_CONTAINER_NAME} does not exist."
      exit 0
    fi
    running="$(docker container inspect --format '{{.State.Running}}' "${TUNNEL_CONTAINER_NAME}")"
    state='stopped'
    [[ "${running}" != true ]] || state='running'
    if mismatch_output="$(contract_mismatches)" && [[ -z "${mismatch_output}" ]]; then
      echo "Container ${TUNNEL_CONTAINER_NAME} matches the expected tunnel contract and is ${state}."
    else
      echo "Container ${TUNNEL_CONTAINER_NAME} exists but does not match the expected tunnel contract (state: ${state})."
      [[ -z "${mismatch_output:-}" ]] || printf -- '- %s\n' "${mismatch_output}"
    fi
    exit 0
    ;;
  stop)
    require_docker
    if ! inspect_tunnel_container 2>/dev/null; then
      echo "Container ${TUNNEL_CONTAINER_NAME} does not exist; nothing to stop."
      exit 0
    fi
    if ! mismatch_output="$(contract_mismatches)"; then
      echo "Unable to validate container ${TUNNEL_CONTAINER_NAME}; refusing to stop. No changes were made." >&2
      exit 1
    fi
    if [[ -n "${mismatch_output}" ]]; then
      echo "Container ${TUNNEL_CONTAINER_NAME} does not match the expected tunnel contract; refusing to stop an unverified container. No changes were made." >&2
      printf -- '- %s\n' "${mismatch_output}" >&2
      exit 1
    fi
    if [[ "$(docker container inspect --format '{{.State.Running}}' "${TUNNEL_CONTAINER_NAME}")" != true ]]; then
      echo "Container ${TUNNEL_CONTAINER_NAME} is already stopped."
      exit 0
    fi
    docker container stop "${TUNNEL_CONTAINER_NAME}" >/dev/null
    echo "Container ${TUNNEL_CONTAINER_NAME} stopped."
    exit 0
    ;;
esac

# --- start ---

dir_info="$(stat -c '%F|%a|%U|%G' -- "${TOKEN_DIR}" 2>/dev/null)" || {
  echo "Tunnel token directory ${TOKEN_DIR} does not exist; provision the token over an interactive SSM session first." >&2
  exit 1
}
IFS='|' read -r dir_type dir_mode dir_owner dir_group dir_extra <<<"${dir_info}"
[[ -z "${dir_extra:-}" ]] || { echo "Unexpected stat output for ${TOKEN_DIR}." >&2; exit 1; }
[[ "${dir_type}" == directory ]] || { echo "${TOKEN_DIR} must be a directory." >&2; exit 1; }
[[ "${dir_mode}" == 700 ]] || { echo "${TOKEN_DIR} must be mode 0700 (found ${dir_mode})." >&2; exit 1; }
[[ "${dir_owner}" == root && "${dir_group}" == root ]] || { echo "${TOKEN_DIR} must be owned by root:root." >&2; exit 1; }

file_info="$(stat -c '%F|%a|%U|%G|%s' -- "${TOKEN_FILE}" 2>/dev/null)" || {
  echo "Tunnel token file ${TOKEN_FILE} does not exist; provision it over an interactive SSM session with terminal echo disabled first." >&2
  exit 1
}
IFS='|' read -r file_type file_mode file_owner file_group file_size file_extra <<<"${file_info}"
[[ -z "${file_extra:-}" ]] || { echo "Unexpected stat output for ${TOKEN_FILE}." >&2; exit 1; }
[[ "${file_type}" == 'regular file' ]] || { echo "${TOKEN_FILE} must be a regular file, not a symlink or other type (found: ${file_type})." >&2; exit 1; }
[[ "${file_mode}" == 600 ]] || { echo "${TOKEN_FILE} must be mode 0600 (found ${file_mode})." >&2; exit 1; }
[[ "${file_owner}" == root && "${file_group}" == root ]] || { echo "${TOKEN_FILE} must be owned by root:root." >&2; exit 1; }
[[ "${file_size}" =~ ^[0-9]+$ ]] || { echo "Unable to determine size of ${TOKEN_FILE}." >&2; exit 1; }
(( file_size > 0 )) || { echo "${TOKEN_FILE} is empty." >&2; exit 1; }
(( file_size <= TOKEN_MAX_BYTES )) || { echo "${TOKEN_FILE} exceeds the maximum expected token size of ${TOKEN_MAX_BYTES} bytes." >&2; exit 1; }
wc_output="$(wc -l -- "${TOKEN_FILE}")" || { echo "Unable to inspect ${TOKEN_FILE}." >&2; exit 1; }
read -r token_newlines _ <<<"${wc_output}"
[[ "${token_newlines}" =~ ^[0-9]+$ ]] || { echo "Unable to determine line count of ${TOKEN_FILE}." >&2; exit 1; }
(( token_newlines == 0 )) || { echo "${TOKEN_FILE} must contain exactly one line with no newline bytes." >&2; exit 1; }

require_docker

docker container inspect "${GATEWAY_CONTAINER_NAME}" >/dev/null 2>&1 || {
  echo "Hermes gateway container ${GATEWAY_CONTAINER_NAME} was not found; start it before starting the tunnel." >&2
  exit 1
}
[[ "$(docker container inspect --format '{{.State.Running}}' "${GATEWAY_CONTAINER_NAME}")" == true ]] || {
  echo "Hermes gateway container ${GATEWAY_CONTAINER_NAME} is not running; start it before starting the tunnel." >&2
  exit 1
}

# Validate any same-named tunnel container before creating or attaching a
# network. Without --recreate, every mismatch must fail without mutation.
tunnel_exists=false
if inspect_tunnel_container 2>/dev/null; then
  tunnel_exists=true
  if [[ "${recreate}" != true ]]; then
    if ! mismatch_output="$(contract_mismatches)"; then
      echo "Unable to validate container ${TUNNEL_CONTAINER_NAME}; no changes were made." >&2
      exit 1
    fi
    mapfile -t mismatches <<<"${mismatch_output}"
    [[ -n "${mismatch_output}" ]] || mismatches=()
    if (( ${#mismatches[@]} > 0 )); then
      echo "Container ${TUNNEL_CONTAINER_NAME} does not match the expected runtime contract:" >&2
      printf -- '- %s\n' "${mismatches[@]}" >&2
      echo 'Explicit --recreate is required; no changes were made.' >&2
      exit 1
    fi
  fi
fi

network_mismatches() {
  local existing_driver existing_internal
  existing_driver="$(docker network inspect --format '{{.Driver}}' "${TUNNEL_NETWORK_NAME}")"
  existing_internal="$(docker network inspect --format '{{.Internal}}' "${TUNNEL_NETWORK_NAME}")"
  [[ "${existing_driver}" == bridge ]] || echo 'network driver is not bridge'
  [[ "${existing_internal}" == false ]] || echo 'network is marked internal'
}

network_created_here=false
gateway_attached_here=false

rollback_owned_mutations() {
  local remove_created_container="${1:-false}"
  local cleanup_failed=false

  if [[ "${remove_created_container}" == true ]]; then
    if ! docker container rm -f "${TUNNEL_CONTAINER_NAME}" >/dev/null; then
      echo "Automatic rollback could not remove ${TUNNEL_CONTAINER_NAME}." >&2
      cleanup_failed=true
    fi
  fi
  if [[ "${gateway_attached_here}" == true ]]; then
    if ! docker network disconnect "${TUNNEL_NETWORK_NAME}" "${GATEWAY_CONTAINER_NAME}" >/dev/null; then
      echo "Automatic rollback could not disconnect ${GATEWAY_CONTAINER_NAME} from ${TUNNEL_NETWORK_NAME}." >&2
      cleanup_failed=true
    fi
  fi
  if [[ "${network_created_here}" == true ]]; then
    if ! docker network rm "${TUNNEL_NETWORK_NAME}" >/dev/null; then
      echo "Automatic rollback could not remove ${TUNNEL_NETWORK_NAME}." >&2
      cleanup_failed=true
    fi
  fi

  [[ "${cleanup_failed}" == false ]]
}

report_owned_rollback() {
  local remove_created_container="$1"
  if rollback_owned_mutations "${remove_created_container}"; then
    echo 'Rolled back Docker resources created or attached by this invocation.' >&2
  else
    echo 'Automatic rollback was incomplete; inspect the named Docker resources before retrying.' >&2
  fi
}

if docker network inspect "${TUNNEL_NETWORK_NAME}" >/dev/null 2>&1; then
  if ! mismatch_output="$(network_mismatches)"; then
    echo "Unable to validate Docker network ${TUNNEL_NETWORK_NAME}; no changes were made." >&2
    exit 1
  fi
  mapfile -t network_mismatch_list <<<"${mismatch_output}"
  [[ -n "${mismatch_output}" ]] || network_mismatch_list=()
  if (( ${#network_mismatch_list[@]} > 0 )); then
    echo "Docker network ${TUNNEL_NETWORK_NAME} does not match the expected contract:" >&2
    printf -- '- %s\n' "${network_mismatch_list[@]}" >&2
    echo 'No changes were made.' >&2
    exit 1
  fi
else
  docker network create --driver bridge "${TUNNEL_NETWORK_NAME}" >/dev/null
  network_created_here=true
fi

# The gateway is already verified present and running above, so attaching it
# to a fresh private network is a normal, additive part of the first tunnel
# start; it never disconnects or recreates the gateway container.
attached_names=" $(docker network inspect --format '{{range .Containers}}{{.Name}} {{end}}' "${TUNNEL_NETWORK_NAME}") "
if [[ "${attached_names}" != *" ${GATEWAY_CONTAINER_NAME} "* ]]; then
  if ! docker network connect "${TUNNEL_NETWORK_NAME}" "${GATEWAY_CONTAINER_NAME}"; then
    if [[ "${network_created_here}" == true ]]; then
      if docker network rm "${TUNNEL_NETWORK_NAME}" >/dev/null; then
        echo "Unable to attach ${GATEWAY_CONTAINER_NAME} to ${TUNNEL_NETWORK_NAME}; removed the network created by this invocation." >&2
      else
        echo "Unable to attach ${GATEWAY_CONTAINER_NAME} to ${TUNNEL_NETWORK_NAME}; automatic network removal failed. Inspect ${TUNNEL_NETWORK_NAME} before retrying." >&2
      fi
    else
      echo "Unable to attach ${GATEWAY_CONTAINER_NAME} to ${TUNNEL_NETWORK_NAME}; the pre-existing network was preserved." >&2
    fi
    exit 1
  fi
  gateway_attached_here=true
fi

if [[ "${tunnel_exists}" == true ]]; then
  if [[ "${recreate}" == true ]]; then
    if ! docker container rm -f "${TUNNEL_CONTAINER_NAME}" >/dev/null; then
      echo "Unable to remove ${TUNNEL_CONTAINER_NAME} for recreation." >&2
      report_owned_rollback false
      exit 1
    fi
  else
    if [[ "$(docker container inspect --format '{{.State.Running}}' "${TUNNEL_CONTAINER_NAME}")" == true ]]; then
      if ! verify_stable retain; then
        report_owned_rollback false
        exit 1
      fi
      echo "Container ${TUNNEL_CONTAINER_NAME} retained and stable."
      exit 0
    fi
    if ! docker container start "${TUNNEL_CONTAINER_NAME}" >/dev/null; then
      echo "Unable to start ${TUNNEL_CONTAINER_NAME}." >&2
      report_owned_rollback false
      exit 1
    fi
    if ! verify_stable start; then
      report_owned_rollback false
      exit 1
    fi
    echo "Container ${TUNNEL_CONTAINER_NAME} started and stable."
    exit 0
  fi
fi

if ! docker run -d \
  --name "${TUNNEL_CONTAINER_NAME}" \
  --restart unless-stopped \
  --network "${TUNNEL_NETWORK_NAME}" \
  --user 0:0 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --read-only \
  --volume "${TOKEN_FILE}:${TOKEN_MOUNT_PATH}:ro" \
  "${TUNNEL_IMAGE}" \
  tunnel --no-autoupdate run --token-file "${TOKEN_MOUNT_PATH}" >/dev/null; then
  echo "Unable to create container ${TUNNEL_CONTAINER_NAME}." >&2
  report_owned_rollback false
  exit 1
fi
if ! verify_stable create; then
  report_owned_rollback true
  exit 1
fi
echo "Container ${TUNNEL_CONTAINER_NAME} created and stable."
