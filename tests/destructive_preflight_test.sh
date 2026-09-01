#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT
readonly DEPLOYMENT_ID='hms-abcdef123456'

passed=0
failed=0

pass() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'not ok - %s\n' "$1"; failed=$((failed + 1)); }

setup_case() {
  local name="$1" case_dir="${TEST_TMP}/${1}"
  mkdir -p -- "${case_dir}/bin" "${case_dir}/home/hermes-operator/${DEPLOYMENT_ID}"
  : >"${case_dir}/events.log"
  : >"${case_dir}/raw.log"
  for tool in aws tofu; do
    cp -- "${REPO_ROOT}/tests/support/destructive-preflight-mock.sh" "${case_dir}/bin/${tool}"
    chmod +x "${case_dir}/bin/${tool}"
  done
  printf '%s\n' "${case_dir}"
}

run_operator() {
  local case_dir="$1" script="$2" input="${3:-}" fail_event="${4:-}" account_id="${5:-450895596262}"
  if [[ "${input}" == '@stdin' ]]; then
    env PATH="${case_dir}/bin:${PATH}" HOME="${case_dir}/home" \
      AWS_ACCESS_KEY_ID=TEST AWS_SECRET_ACCESS_KEY=TEST MOCK_CASE_DIR="${case_dir}" \
      MOCK_LOG="${case_dir}/events.log" MOCK_RAW_LOG="${case_dir}/raw.log" \
      MOCK_FAIL_EVENT="${fail_event}" MOCK_ACCOUNT_ID="${account_id}" \
      bash "${REPO_ROOT}/scripts/${script}.sh" "${DEPLOYMENT_ID}" >/dev/null 2>"${case_dir}/stderr"
    return
  fi
  printf '%s' "${input}" | env PATH="${case_dir}/bin:${PATH}" HOME="${case_dir}/home" \
    AWS_ACCESS_KEY_ID=TEST AWS_SECRET_ACCESS_KEY=TEST MOCK_CASE_DIR="${case_dir}" \
    MOCK_LOG="${case_dir}/events.log" MOCK_RAW_LOG="${case_dir}/raw.log" \
    MOCK_FAIL_EVENT="${fail_event}" MOCK_ACCOUNT_ID="${account_id}" \
    bash "${REPO_ROOT}/scripts/${script}.sh" "${DEPLOYMENT_ID}" >/dev/null 2>"${case_dir}/stderr"
}

assert_no_destructive_events() {
  ! grep -Eq '^(host-apply|state-apply|bucket-delete)$' "$1/events.log"
}

assert_no_tofu_or_destructive_aws() {
  local case_dir="$1"
  [[ ! -s "${case_dir}/events.log" ]] &&
    ! grep -Eq 'kms describe-key|s3api (list-object-versions|delete-objects)' "${case_dir}/raw.log"
}

missing_state_aborts_before_work() {
  local case_dir status
  case_dir="$(setup_case missing-state)"
  run_operator "${case_dir}" purge || status=$?
  [[ "${status:-0}" -ne 0 ]] && assert_no_tofu_or_destructive_aws "${case_dir}" &&
    [[ "$(wc -l <"${case_dir}/raw.log")" -eq 1 ]]
}

failed_state_plan_aborts_before_confirmation_or_destruction() {
  local case_dir status
  case_dir="$(setup_case failed-state-plan)"
  : >"${case_dir}/home/hermes-operator/${DEPLOYMENT_ID}/state-foundation.tfstate"
  run_operator "${case_dir}" purge $'destroy-host-hms-abcdef123456\npurge-state-hms-abcdef123456\n' state-plan || status=$?
  [[ "${status:-0}" -ne 0 ]] && assert_no_destructive_events "${case_dir}" &&
    ! grep -q '^state-show$' "${case_dir}/events.log"
}

failed_plan_or_show_aborts_before_destruction() {
  local event case_dir status
  for event in host-plan host-show state-show; do
    case_dir="$(setup_case "failed-${event}")"
    : >"${case_dir}/home/hermes-operator/${DEPLOYMENT_ID}/state-foundation.tfstate"
    status=0
    run_operator "${case_dir}" purge $'destroy-host-hms-abcdef123456\npurge-state-hms-abcdef123456\n' "${event}" || status=$?
    [[ "${status}" -ne 0 ]] && assert_no_destructive_events "${case_dir}" || return 1
  done
}

first_confirmation_mismatch_aborts_before_destruction() {
  local case_dir status
  case_dir="$(setup_case first-confirmation)"
  : >"${case_dir}/home/hermes-operator/${DEPLOYMENT_ID}/state-foundation.tfstate"
  run_operator "${case_dir}" purge $'wrong\n' || status=$?
  [[ "${status:-0}" -ne 0 ]] && assert_no_destructive_events "${case_dir}"
}

second_confirmation_mismatch_aborts_before_destruction() {
  local case_dir status
  case_dir="$(setup_case second-confirmation)"
  : >"${case_dir}/home/hermes-operator/${DEPLOYMENT_ID}/state-foundation.tfstate"
  run_operator "${case_dir}" purge $'destroy-host-hms-abcdef123456\nwrong\n' || status=$?
  [[ "${status:-0}" -ne 0 ]] && assert_no_destructive_events "${case_dir}"
}

write_purge_confirmations() {
  local case_dir="$1" operator_pid="$2" deadline
  deadline=$((SECONDS + 2))
  while ! grep -q '^state-show$' "${case_dir}/events.log"; do
    kill -0 "${operator_pid}" 2>/dev/null || return 73
    (( SECONDS < deadline )) || return 74
    sleep 0.01
  done
  # Each marker is emitted immediately before its token unblocks the corresponding read.
  printf 'confirm-host\n' >>"${case_dir}/events.log"
  printf '%s\n' "destroy-host-${DEPLOYMENT_ID}"
  printf 'confirm-state\n' >>"${case_dir}/events.log"
  printf '%s\n' "purge-state-${DEPLOYMENT_ID}"
}

success_orders_plans_confirmations_and_destruction() {
  local case_dir operator_pid writer_pid status writer_status expected
  case_dir="$(setup_case success)"
  : >"${case_dir}/home/hermes-operator/${DEPLOYMENT_ID}/state-foundation.tfstate"
  mkfifo "${case_dir}/input"
  run_operator "${case_dir}" purge '@stdin' '' <"${case_dir}/input" & operator_pid=$!
  write_purge_confirmations "${case_dir}" "${operator_pid}" >"${case_dir}/input" & writer_pid=$!
  wait "${operator_pid}"; status=$?
  wait "${writer_pid}"; writer_status=$?
  expected=$'host-init\nstate-init\nhost-plan\nhost-show\nstate-plan\nstate-show\nconfirm-host\nconfirm-state\nhost-apply\nbucket-list\nbucket-delete\nbucket-list\nstate-apply'
  (( status == 0 && writer_status == 0 )) && [[ "$(<"${case_dir}/events.log")" == "${expected}" ]]
}

early_pre_state_show_failure_does_not_hang_fifo() {
  local case_dir operator_pid writer_pid status writer_status started
  case_dir="$(setup_case early-pre-state-show)"
  : >"${case_dir}/home/hermes-operator/${DEPLOYMENT_ID}/state-foundation.tfstate"
  mkfifo "${case_dir}/input"
  started=${SECONDS}
  run_operator "${case_dir}" purge '@stdin' host-show <"${case_dir}/input" & operator_pid=$!
  write_purge_confirmations "${case_dir}" "${operator_pid}" >"${case_dir}/input" & writer_pid=$!
  wait "${operator_pid}"; status=$?
  wait "${writer_pid}"; writer_status=$?
  (( status != 0 && writer_status != 0 && SECONDS - started <= 3 )) &&
    assert_no_destructive_events "${case_dir}"
}

teardown_does_not_discover_ec2() {
  local case_dir status
  case_dir="$(setup_case teardown)"
  run_operator "${case_dir}" teardown $'hms-abcdef123456\n' || status=$?
  (( ${status:-0} == 0 )) &&
    [[ "$(<"${case_dir}/events.log")" == $'host-init\nhost-plan\nhost-show\nhost-apply' ]] &&
    ! grep -q 'describe-instances' "${case_dir}/raw.log"
}

teardown_plan_or_show_failure_aborts_before_apply() {
  local event case_dir status
  for event in host-plan host-show; do
    case_dir="$(setup_case "teardown-failed-${event}")"
    status=0
    run_operator "${case_dir}" teardown $'hms-abcdef123456\n' "${event}" || status=$?
    [[ "${status}" -ne 0 ]] && ! grep -q '^host-apply$' "${case_dir}/events.log" || return 1
  done
}

wrong_account_blocks_purge_and_teardown() {
  local script case_dir status
  for script in purge teardown; do
    case_dir="$(setup_case "wrong-account-${script}")"
    : >"${case_dir}/home/hermes-operator/${DEPLOYMENT_ID}/state-foundation.tfstate"
    status=0
    run_operator "${case_dir}" "${script}" '' '' 999999999999 || status=$?
    [[ "${status}" -ne 0 ]] && assert_no_tofu_or_destructive_aws "${case_dir}" || return 1
  done
}

run_named_case() {
  local name="$1"
  if "${name}"; then pass "${name}"; else fail "${name}"; fi
}

if (( $# > 0 )); then
  run_named_case "$1"
else
  for name in \
    missing_state_aborts_before_work \
    failed_state_plan_aborts_before_confirmation_or_destruction \
    failed_plan_or_show_aborts_before_destruction \
    first_confirmation_mismatch_aborts_before_destruction \
    second_confirmation_mismatch_aborts_before_destruction \
    success_orders_plans_confirmations_and_destruction \
    early_pre_state_show_failure_does_not_hang_fifo \
    teardown_does_not_discover_ec2 \
    teardown_plan_or_show_failure_aborts_before_apply \
    wrong_account_blocks_purge_and_teardown; do
    run_named_case "${name}"
  done
fi

printf '1..%d\n' "$((passed + failed))"
printf '# passed: %d, failed: %d\n' "${passed}" "${failed}"
(( failed == 0 ))
