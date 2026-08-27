#!/usr/bin/env bash

set -euo pipefail

if (( EUID != 0 )); then
  echo "Hermes gateway setup must be run as root." >&2
  exit 1
fi

HERMES_IMAGE="nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e"
HERMES_DATA_DIR="/var/lib/hermes"
HERMES_CONTAINER_NAME="hermes-gateway"

if ! command -v docker >/dev/null 2>&1; then
  echo "Hermes gateway setup requires Docker, but the docker binary was not found." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Hermes gateway setup requires a running Docker daemon, but it did not respond." >&2
  exit 1
fi

if [[ ! -d "${HERMES_DATA_DIR}" ]]; then
  echo "Hermes data directory ${HERMES_DATA_DIR} does not exist; run the base Hermes setup first." >&2
  exit 1
fi

if docker container inspect "${HERMES_CONTAINER_NAME}" >/dev/null 2>&1 &&
  [[ "$(docker container inspect --format '{{.State.Running}}' "${HERMES_CONTAINER_NAME}")" == "true" ]]; then
  echo "Container ${HERMES_CONTAINER_NAME} is running; stop it explicitly before reconfiguring Hermes." >&2
  exit 1
fi

docker run --rm -it \
  --volume "${HERMES_DATA_DIR}:/opt/data" \
  "${HERMES_IMAGE}" \
  hermes setup gateway

docker run --rm \
  --volume "${HERMES_DATA_DIR}:/opt/data" \
  "${HERMES_IMAGE}" \
  hermes tools disable terminal file skills --platform telegram
