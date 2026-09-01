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
  local mode="$1"; shift
  local case_dir
  case_dir="$(mktemp -d "${TEST_TMP}/operator.XXXXXX")"
  mkdir -p "${case_dir}/bin"
  cp "${REPO_ROOT}/tests/support/gateway-aws-mock.sh" "${case_dir}/bin/aws"
  chmod +x "${case_dir}/bin/aws"
  : >"${case_dir}/calls"
  PATH="${case_dir}/bin:${PATH}" MOCK_GATEWAY_AWS_MODE="${mode}" \
    MOCK_GATEWAY_AWS_CALLS="${case_dir}/calls" AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock \
    MOCK_GATEWAY_EXPECTED_HELPER="${REPO_ROOT}/scripts/support/run-hermes-gateway.sh" \
    HERMES_SSM_DEADLINE_SECONDS=0 HERMES_SSM_POLL_INTERVAL_SECONDS=0 \
    bash "${REPO_ROOT}/hermes.sh" start-gateway hms-abcdef123456 "$@" >"${case_dir}/output" 2>&1
  RUN_STATUS=$? RUN_OUTPUT="$(<"${case_dir}/output")" RUN_CALLS="$(<"${case_dir}/calls")"
}

success_is_gated() {
  run_operator success
  (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == *'created and stable'* ]] &&
    [[ "${RUN_OUTPUT}" == *'Hermes gateway container is running'* ]] &&
    [[ "${RUN_CALLS}" == *'DELIVERED_REVIEWED_HELPER'* ]] &&
    [[ "${RUN_CALLS}" == *'REMOTE_BASE64_CHECK'* ]] &&
    [[ "${RUN_CALLS}" == *'EXPECTED_VOLUME_FORWARDED'* ]]
}

failure_has_no_success() {
  run_operator failure
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'Status: Failed'* ]] &&
    [[ "${RUN_OUTPUT}" != *'Hermes gateway container is running'* ]]
}

active_timeout_has_no_success() {
  run_operator active
  (( RUN_STATUS == 124 )) && [[ "${RUN_OUTPUT}" == *'may still be continuing remotely'* ]] &&
    [[ "${RUN_OUTPUT}" != *'Hermes gateway container is running'* ]]
}

recreate_is_forwarded() {
  run_operator success --recreate
  (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" == *'RECREATE_FORWARDED'* ]]
}

invalid_flag_is_local() {
  run_operator success --unsafe
  (( RUN_STATUS == 2 )) && [[ -z "${RUN_CALLS}" ]]
}

discovery_failure_has_no_ssm() {
  run_operator volume-failure
  (( RUN_STATUS != 0 )) && [[ "${RUN_CALLS}" != *'ssm send-command'* ]]
}

run_case 'success waits for terminal Success and remote stability' success_is_gated
run_case 'terminal SSM failure cannot print success' failure_has_no_success
run_case 'active SSM deadline cannot print success' active_timeout_has_no_success
run_case '--recreate is delivered to reviewed helper' recreate_is_forwarded
run_case 'invalid flag makes no AWS call' invalid_flag_is_local
run_case 'volume discovery failure makes no SSM call' discovery_failure_has_no_ssm
printf '1..%d\n# passed: %d, failed: %d\n' "$((passed + failed))" "${passed}" "${failed}"
(( failed == 0 ))
