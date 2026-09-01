#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
passed=0 failed=0

pass() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'not ok - %s\n' "$1"; failed=$((failed + 1)); }
run_case() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }

run_wait() {
  local statuses="$1" deadline="${2:-30}" case_dir output_file status_file calls_file
  case_dir="$(mktemp -d "${TEST_TMP}/case.XXXXXX")"
  output_file="${case_dir}/output"
  status_file="${case_dir}/statuses"
  calls_file="${case_dir}/calls"
  printf '%s\n' "${statuses}" >"${status_file}"
  : >"${calls_file}"
  mkdir -p "${case_dir}/bin"
  cp "${REPO_ROOT}/tests/support/ssm-aws-mock.sh" "${case_dir}/bin/aws"
  chmod +x "${case_dir}/bin/aws"
  PATH="${case_dir}/bin:${PATH}" MOCK_SSM_STATUS_FILE="${status_file}" \
    MOCK_SSM_CALLS_FILE="${calls_file}" \
    MOCK_SSM_CLOCK_FILE="${case_dir}/clock" \
    bash -c '
      source "$1/scripts/lib.sh"
      printf "0\n" >"${MOCK_SSM_CLOCK_FILE}"
      ssm_poll_now() {
        tick="$(<"${MOCK_SSM_CLOCK_FILE}")"
        printf "%s\n" "${tick}"
        printf "%s\n" "$((tick + 10))" >"${MOCK_SSM_CLOCK_FILE}"
      }
      ssm_poll_sleep() { :; }
      wait_and_print_ssm_command cmd-123 i-abc "$2" 1
    ' _ "${REPO_ROOT}" "${deadline}" >"${output_file}" 2>&1
  RUN_STATUS=$?
  RUN_OUTPUT="$(<"${output_file}")"
  RUN_CALL_COUNT="$(wc -l <"${calls_file}")"
}

not_visible_to_success() {
  run_wait $'__INVOCATION_NOT_VISIBLE__\nPending\nSuccess'
  (( RUN_STATUS == 0 && RUN_CALL_COUNT == 3 )) &&
    [[ "${RUN_OUTPUT}" == *'Status: Success'* ]] &&
    [[ "$(grep -c '^Status:' <<<"${RUN_OUTPUT}")" -eq 1 ]]
}

not_visible_deadline() {
  run_wait $'__INVOCATION_NOT_VISIBLE__\n__INVOCATION_NOT_VISIBLE__\n__INVOCATION_NOT_VISIBLE__' 15
  (( RUN_STATUS == 124 && RUN_CALL_COUNT == 2 )) &&
    [[ "${RUN_OUTPUT}" == *'cmd-123'* && "${RUN_OUTPUT}" == *'i-abc'* ]] &&
    [[ "${RUN_OUTPUT}" == *'may still be'* && "${RUN_OUTPUT}" == *'pending'* ]] &&
    [[ "${RUN_OUTPUT}" == *'get-command-invocation'* ]] &&
    [[ "${RUN_OUTPUT}" != *'completed failure'* && "${RUN_OUTPUT}" != *'terminal status'* ]]
}

active_to_success() {
  run_wait $'Pending\nInProgress\nSuccess'
  (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == *'Status: Success'* ]] &&
    [[ "$(grep -c '^Status:' <<<"${RUN_OUTPUT}")" -eq 1 ]]
}

active_deadline() {
  run_wait $'Pending\nInProgress\nInProgress' 15
  (( RUN_STATUS == 124 )) && [[ "${RUN_OUTPUT}" == *'may still be continuing remotely'* ]] &&
    [[ "${RUN_OUTPUT}" == *'cmd-123'* ]] && [[ "${RUN_OUTPUT}" == *'i-abc'* ]] &&
    [[ "${RUN_OUTPUT}" == *'get-command-invocation'* ]] &&
    [[ "${RUN_OUTPUT}" != *'finished with status'* ]]
}

terminal_failure() {
  local terminal="$1"
  run_wait "${terminal}"
  (( RUN_STATUS != 0 && RUN_STATUS != 124 )) && [[ "${RUN_OUTPUT}" == *"Status: ${terminal}"* ]]
}

unknown_fails_closed() {
  run_wait 'Mystery'
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'unknown SSM status Mystery'* ]] &&
    [[ "${RUN_OUTPUT}" == *'cmd-123'* ]]
}

api_error_propagates() {
  run_wait $'__API_ERROR__\nSuccess'
  (( RUN_STATUS == 73 && RUN_CALL_COUNT == 1 )) && [[ "${RUN_OUTPUT}" == *'mock API failure'* ]]
}

malformed_fails() {
  run_wait '__MALFORMED__'
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'malformed'* ]]
}

empty_status_fails_closed() {
  run_wait '__EMPTY__'
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'malformed SSM invocation response'* ]] &&
    [[ "${RUN_OUTPUT}" == *'cmd-123'* ]]
}

run_case 'Pending to InProgress to Success' active_to_success
run_case 'InvocationDoesNotExist to Pending to Success' not_visible_to_success
run_case 'persistent InvocationDoesNotExist reaches actionable deadline' not_visible_deadline
run_case 'active local deadline is distinct and actionable' active_deadline
for status in Failed TimedOut Cancelled Undeliverable Terminated; do
  run_case "terminal ${status} fails" terminal_failure "${status}"
done
run_case 'unknown status fails closed' unknown_fails_closed
run_case 'AWS API error propagates' api_error_propagates
run_case 'malformed response fails' malformed_fails
run_case 'empty status fails closed with command ID' empty_status_fails_closed

printf '1..%d\n# passed: %d, failed: %d\n' "$((passed + failed))" "${passed}" "${failed}"
(( failed == 0 ))
