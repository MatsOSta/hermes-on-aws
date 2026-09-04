#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
passed=0 failed=0
pass() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'not ok - %s\n' "$1"; failed=$((failed + 1)); }
run_case() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }

run_operator() {
  local command="$1" mode="$2"; shift 2
  local case_dir
  case_dir="$(mktemp -d "${TEST_TMP}/operator.XXXXXX")"
  mkdir -p "${case_dir}/bin"
  cp "${REPO_ROOT}/tests/support/tunnel-aws-mock.sh" "${case_dir}/bin/aws"
  chmod +x "${case_dir}/bin/aws"
  : >"${case_dir}/calls"
  PATH="${case_dir}/bin:${PATH}" MOCK_TUNNEL_AWS_MODE="${mode}" \
    MOCK_TUNNEL_AWS_CALLS="${case_dir}/calls" AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock \
    MOCK_TUNNEL_EXPECTED_HELPER="${REPO_ROOT}/scripts/support/run-hermes-tunnel.sh" \
    HERMES_SSM_DEADLINE_SECONDS=0 HERMES_SSM_POLL_INTERVAL_SECONDS=0 \
    bash "${REPO_ROOT}/hermes.sh" "${command}" hms-abcdef123456 "$@" >"${case_dir}/output" 2>"${case_dir}/output.err"
  RUN_STATUS=$?
  RUN_OUTPUT="$(cat "${case_dir}/output" "${case_dir}/output.err")"
  RUN_CALLS="$(<"${case_dir}/calls")"
}

start_success_is_gated() {
  run_operator start-tunnel success
  (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == *'created and stable'* ]] &&
    [[ "${RUN_OUTPUT}" == *'Hermes cloudflared tunnel container is running'* ]] &&
    [[ "${RUN_CALLS}" == *'DELIVERED_REVIEWED_HELPER'* ]] &&
    [[ "${RUN_CALLS}" == *'REMOTE_BASE64_CHECK'* ]] &&
    [[ "${RUN_CALLS}" == *'START_SUBCOMMAND'* ]]
}

start_failure_has_no_success() {
  run_operator start-tunnel failure
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'Status: Failed'* ]] &&
    [[ "${RUN_OUTPUT}" != *'is running'* ]]
}

start_active_timeout_has_no_success() {
  run_operator start-tunnel active
  (( RUN_STATUS == 124 )) && [[ "${RUN_OUTPUT}" == *'may still be continuing remotely'* ]] &&
    [[ "${RUN_OUTPUT}" != *'is running'* ]]
}

start_recreate_is_forwarded() {
  run_operator start-tunnel success --recreate
  (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" == *'RECREATE_FORWARDED'* ]]
}

start_invalid_flag_is_local() {
  run_operator start-tunnel success --unsafe
  (( RUN_STATUS == 2 )) && [[ -z "${RUN_CALLS}" ]]
}

stop_success_is_gated() {
  run_operator stop-tunnel stop-success
  (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == *'hermes-cloudflared stopped'* ]] &&
    [[ "${RUN_CALLS}" == *'STOP_SUBCOMMAND'* ]] && [[ "${RUN_CALLS}" == *'DELIVERED_REVIEWED_HELPER'* ]]
}

stop_failure_has_no_success() {
  run_operator stop-tunnel failure
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'Status: Failed'* ]]
}

stop_rejects_extra_arguments() {
  run_operator stop-tunnel stop-success --recreate
  (( RUN_STATUS == 2 )) && [[ -z "${RUN_CALLS}" ]]
}

status_success_is_gated() {
  run_operator status-tunnel status-success
  (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == *'matches the expected tunnel contract and is running'* ]] &&
    [[ "${RUN_CALLS}" == *'STATUS_SUBCOMMAND'* ]] && [[ "${RUN_CALLS}" == *'DELIVERED_REVIEWED_HELPER'* ]]
}

status_failure_has_no_success() {
  run_operator status-tunnel failure
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'Status: Failed'* ]]
}

status_rejects_extra_arguments() {
  run_operator status-tunnel status-success --recreate
  (( RUN_STATUS == 2 )) && [[ -z "${RUN_CALLS}" ]]
}

run_case 'start-tunnel success waits for terminal Success and remote stability' start_success_is_gated
run_case 'start-tunnel terminal SSM failure cannot print success' start_failure_has_no_success
run_case 'start-tunnel active SSM deadline cannot print success' start_active_timeout_has_no_success
run_case 'start-tunnel --recreate is delivered to reviewed helper' start_recreate_is_forwarded
run_case 'start-tunnel invalid flag makes no AWS call' start_invalid_flag_is_local
run_case 'stop-tunnel success reports the container was stopped' stop_success_is_gated
run_case 'stop-tunnel terminal SSM failure cannot print success' stop_failure_has_no_success
run_case 'stop-tunnel rejects extra arguments before any AWS call' stop_rejects_extra_arguments
run_case 'status-tunnel success reports the container contract and state' status_success_is_gated
run_case 'status-tunnel terminal SSM failure cannot print success' status_failure_has_no_success
run_case 'status-tunnel rejects extra arguments before any AWS call' status_rejects_extra_arguments
printf '1..%d\n# passed: %d, failed: %d\n' "$((passed + failed))" "${passed}" "${failed}"
(( failed == 0 ))
