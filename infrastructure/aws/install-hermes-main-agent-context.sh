#!/usr/bin/env bash

set -euo pipefail

if (( EUID != 0 )); then
  echo "Hermes main-agent context installation must be run as root." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOUL_SOURCE="${SCRIPT_DIR}/hermes/SOUL.md"
HERMES_DATA_DIR="/var/lib/hermes"
SOUL_DESTINATION="${HERMES_DATA_DIR}/SOUL.md"

if [[ ! -f "${SOUL_SOURCE}" ]]; then
  echo "Reviewed Hermes identity was not found at ${SOUL_SOURCE}." >&2
  exit 1
fi

if [[ ! -d "${HERMES_DATA_DIR}" ]]; then
  echo "Hermes data directory ${HERMES_DATA_DIR} does not exist; run Hermes setup first." >&2
  exit 1
fi

temporary_soul="$(mktemp "${HERMES_DATA_DIR}/.SOUL.md.XXXXXX")"
trap 'rm -f -- "${temporary_soul}"' EXIT

install -m 0644 "${SOUL_SOURCE}" "${temporary_soul}"
mv -f -- "${temporary_soul}" "${SOUL_DESTINATION}"

echo "Installed reviewed Hermes identity at ${SOUL_DESTINATION}."
echo "Restart the Hermes gateway explicitly so new sessions reliably load it."
