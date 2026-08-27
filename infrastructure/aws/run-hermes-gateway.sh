#!/usr/bin/env bash

set -euo pipefail

if (( EUID != 0 )); then
  echo "Hermes gateway runtime must be run as root." >&2
  exit 1
fi

HERMES_IMAGE="nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e"
HERMES_DATA_DIR="/var/lib/hermes"
HERMES_CONTAINER_NAME="hermes-gateway"

if ! command -v docker >/dev/null 2>&1; then
  echo "Hermes gateway runtime requires Docker, but the docker binary was not found." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Hermes gateway runtime requires a running Docker daemon, but it did not respond." >&2
  exit 1
fi

if [[ ! -d "${HERMES_DATA_DIR}" ]]; then
  echo "Hermes data directory ${HERMES_DATA_DIR} does not exist; run Hermes setup first." >&2
  exit 1
fi

if docker container inspect "${HERMES_CONTAINER_NAME}" >/dev/null 2>&1; then
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
  contract_mismatches=()

  if [[ "${existing_image}" != "${HERMES_IMAGE}" ]]; then
    contract_mismatches+=("image is not the pinned Hermes image")
  fi
  if [[ "${existing_privileged}" != "false" ]]; then
    contract_mismatches+=("privileged mode is not false")
  fi
  if [[ "${existing_network_mode}" == "host" ]]; then
    contract_mismatches+=("network mode is host")
  fi
  if [[ "${existing_restart_policy}" != "unless-stopped" ]]; then
    contract_mismatches+=("restart policy is not unless-stopped")
  fi
  if [[ "${existing_binds}" != "[\"${HERMES_DATA_DIR}:/opt/data\"]" ]]; then
    contract_mismatches+=("host bind mounts do not exactly match ${HERMES_DATA_DIR}:/opt/data")
  fi
  if [[ "${existing_mounts}" != "null" && "${existing_mounts}" != "[]" ]]; then
    contract_mismatches+=("HostConfig.Mounts is not empty")
  fi
  if [[ "${existing_volumes_from}" != "null" && "${existing_volumes_from}" != "[]" ]]; then
    contract_mismatches+=("VolumesFrom is not empty")
  fi
  if [[ "${existing_cap_add}" != "null" && "${existing_cap_add}" != "[]" ]]; then
    contract_mismatches+=("added Linux capabilities are present")
  fi
  if [[ "${existing_port_bindings}" != "null" && "${existing_port_bindings}" != "{}" ]]; then
    contract_mismatches+=("published port bindings are present")
  fi
  if [[ "${existing_publish_all_ports}" != "false" ]]; then
    contract_mismatches+=("PublishAllPorts is not false")
  fi
  if [[ "${existing_command}" != '["hermes","gateway","run"]' ]]; then
    contract_mismatches+=("configured command is not hermes gateway run")
  fi

  if (( ${#contract_mismatches[@]} > 0 )); then
    echo "Container ${HERMES_CONTAINER_NAME} does not match the expected runtime contract:" >&2
    for mismatch in "${contract_mismatches[@]}"; do
      echo "- ${mismatch}" >&2
    done
    echo "Explicit operator review and replacement are required; no changes were made." >&2
    exit 1
  fi

  if [[ "$(docker container inspect --format '{{.State.Running}}' "${HERMES_CONTAINER_NAME}")" == "true" ]]; then
    echo "Container ${HERMES_CONTAINER_NAME} is already running with the expected runtime contract."
    exit 0
  fi

  docker start "${HERMES_CONTAINER_NAME}"
  exit 0
fi

docker run -d \
  --name "${HERMES_CONTAINER_NAME}" \
  --restart unless-stopped \
  --volume "${HERMES_DATA_DIR}:/opt/data" \
  "${HERMES_IMAGE}" \
  hermes gateway run
