#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_TUNNEL_AWS_CALLS}"
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
  payload_command="$(jq -er '.commands[] | select(startswith("printf"))' <<<"${parameters}")" || {
    echo 'missing base64 delivery command' >&2
    exit 88
  }
  payload="$(sed -nE "s/^printf '%s' '([^']+)' .*\$/\1/p" <<<"${payload_command}")"
  [[ -f "${MOCK_TUNNEL_EXPECTED_HELPER}" ]] || { echo 'missing expected helper' >&2; exit 82; }
  decoded_file="$(mktemp)"
  trap 'rm -f -- "${decoded_file}"' EXIT
  base64 -d <<<"${payload}" >"${decoded_file}"
  cmp -s -- "${MOCK_TUNNEL_EXPECTED_HELPER}" "${decoded_file}" || {
    echo 'delivered helper differs from reviewed helper' >&2
    exit 83
  }
  echo DELIVERED_REVIEWED_HELPER >>"${MOCK_TUNNEL_AWS_CALLS}"
  [[ "${parameters}" == *'command -v base64'* ]] || exit 87
  echo REMOTE_BASE64_CHECK >>"${MOCK_TUNNEL_AWS_CALLS}"
  invocation_command="$(jq -er '.commands[-1]' <<<"${parameters}")"
  case "${invocation_command}" in
    *'"${runtime_helper}" start'*'--recreate'*) echo RECREATE_FORWARDED >>"${MOCK_TUNNEL_AWS_CALLS}" ;;
  esac
  case "${invocation_command}" in
    *'"${runtime_helper}" start'*) echo START_SUBCOMMAND >>"${MOCK_TUNNEL_AWS_CALLS}" ;;
    *'"${runtime_helper}" status'*) echo STATUS_SUBCOMMAND >>"${MOCK_TUNNEL_AWS_CALLS}" ;;
    *'"${runtime_helper}" stop'*) echo STOP_SUBCOMMAND >>"${MOCK_TUNNEL_AWS_CALLS}" ;;
    *) echo "unexpected runtime invocation: ${invocation_command}" >&2; exit 89 ;;
  esac
  echo cmd-123
  exit 0
fi
if [[ "${args}" == *' ssm get-command-invocation '* ]]; then
  [[ "${args}" == *'--output json'* ]] || exit 84
  case "${MOCK_TUNNEL_AWS_MODE}" in
    success) printf '%s\n' '{"Status":"Success","StandardOutputContent":"Container hermes-cloudflared created and stable.","StandardErrorContent":""}' ;;
    stop-success) printf '%s\n' '{"Status":"Success","StandardOutputContent":"Container hermes-cloudflared stopped.","StandardErrorContent":""}' ;;
    status-success) printf '%s\n' '{"Status":"Success","StandardOutputContent":"Container hermes-cloudflared matches the expected tunnel contract and is running.","StandardErrorContent":""}' ;;
    failure) printf '%s\n' '{"Status":"Failed","StandardOutputContent":"","StandardErrorContent":"container exited"}' ;;
    active) printf '%s\n' '{"Status":"InProgress","StandardOutputContent":"","StandardErrorContent":""}' ;;
    *) exit 85 ;;
  esac
  exit 0
fi
echo "unexpected aws invocation: ${args}" >&2
exit 86
