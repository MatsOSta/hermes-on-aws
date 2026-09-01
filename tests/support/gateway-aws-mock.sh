#!/usr/bin/env bash

set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_GATEWAY_AWS_CALLS}"
args=" $* "
if [[ "${args}" == *' sts get-caller-identity '* ]]; then echo 450895596262; exit 0; fi
if [[ "${args}" == *' ec2 describe-instances '* ]]; then echo i-abc; exit 0; fi
if [[ "${args}" == *' ssm describe-instance-information '* ]]; then echo Online; exit 0; fi
if [[ "${args}" == *' ssm send-command '* ]]; then
  parameters=''
  while (( $# > 0 )); do
    if [[ "$1" == --parameters ]]; then parameters="$2"; break; fi
    shift
  done
  [[ -n "${parameters}" ]] || { echo 'missing parameters' >&2; exit 81; }
  payload_command="$(jq -er '.commands[] | select(startswith("printf"))' <<<"${parameters}")"
  payload="$(sed -nE "s/^printf '%s' '([^']+)' .*$/\1/p" <<<"${payload_command}")"
  [[ -f "${MOCK_GATEWAY_EXPECTED_HELPER}" ]] || { echo 'missing expected helper' >&2; exit 82; }
  decoded_file="$(mktemp)"
  trap 'rm -f -- "${decoded_file}"' EXIT
  base64 -d <<<"${payload}" >"${decoded_file}"
  cmp -s -- "${MOCK_GATEWAY_EXPECTED_HELPER}" "${decoded_file}" || {
    echo 'delivered helper differs from reviewed helper' >&2
    exit 83
  }
  echo DELIVERED_REVIEWED_HELPER >>"${MOCK_GATEWAY_AWS_CALLS}"
  [[ "${parameters}" == *'command -v base64'* ]] || exit 87
  echo REMOTE_BASE64_CHECK >>"${MOCK_GATEWAY_AWS_CALLS}"
  [[ "${parameters}" != *'--recreate'* ]] || echo RECREATE_FORWARDED >>"${MOCK_GATEWAY_AWS_CALLS}"
  echo cmd-123
  exit 0
fi
if [[ "${args}" == *' ssm get-command-invocation '* ]]; then
  [[ "${args}" == *'--output json'* ]] || exit 84
  case "${MOCK_GATEWAY_AWS_MODE}" in
    success) printf '%s\n' '{"Status":"Success","StandardOutputContent":"Container hermes-gateway created and stable.","StandardErrorContent":""}' ;;
    failure) printf '%s\n' '{"Status":"Failed","StandardOutputContent":"","StandardErrorContent":"container exited"}' ;;
    active) printf '%s\n' '{"Status":"InProgress","StandardOutputContent":"","StandardErrorContent":""}' ;;
    *) exit 85 ;;
  esac
  exit 0
fi
echo "unexpected aws invocation: ${args}" >&2
exit 86
