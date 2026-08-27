#!/usr/bin/env bash

set -euo pipefail

if (( EUID != 0 )); then
  echo "Hermes setup must be run as root." >&2
  exit 1
fi

HERMES_IMAGE="nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e"
HERMES_DATA_DIR="/var/lib/hermes"

if ! command -v docker >/dev/null 2>&1; then
  echo "Hermes setup requires Docker, but the docker binary was not found." >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Hermes setup requires a running Docker daemon, but it did not respond." >&2
  exit 1
fi

install -d -m 0700 "${HERMES_DATA_DIR}"

docker run --rm -it \
  --volume "${HERMES_DATA_DIR}:/opt/data" \
  "${HERMES_IMAGE}" \
  setup

docker run --rm \
  --volume "${HERMES_DATA_DIR}:/opt/data" \
  "${HERMES_IMAGE}" \
  hermes tools disable terminal file vision skills --platform cli
