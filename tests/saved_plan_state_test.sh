#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly DEPLOYMENT_ID='hms-abcdef123456'
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

run_operator() {
  local script="$1" input="$2" case_dir
  case_dir="${TEST_TMP}/${script}"
  mkdir -p -- "${case_dir}/bin" "${case_dir}/home/hermes-operator/${DEPLOYMENT_ID}"
  for tool in aws tofu; do
    cp -- "${REPO_ROOT}/tests/support/saved-plan-state-mock.sh" "${case_dir}/bin/${tool}"
    chmod +x "${case_dir}/bin/${tool}"
  done
  if [[ "${script}" == purge ]]; then
    : >"${case_dir}/home/hermes-operator/${DEPLOYMENT_ID}/state-foundation.tfstate"
  fi
  printf '%s' "${input}" | env PATH="${case_dir}/bin:${PATH}" HOME="${case_dir}/home" \
    AWS_ACCESS_KEY_ID=TEST AWS_SECRET_ACCESS_KEY=TEST MOCK_RAW_LOG="${case_dir}/raw.log" \
    bash "${REPO_ROOT}/scripts/${script}.sh" "${DEPLOYMENT_ID}" >/dev/null
}

assert_matching_external_state() {
  local script="$1" root_fragment="$2" plan_name="$3"
  local log="${TEST_TMP}/${script}/raw.log"
  local state_path="${TEST_TMP}/${script}/home/hermes-operator/${DEPLOYMENT_ID}/state-foundation.tfstate"
  local plan_line apply_line
  plan_line="$(grep "tofu .*${root_fragment}.* plan .*${plan_name}" "${log}")"
  apply_line="$(grep "tofu .*${root_fragment}.* apply .*${plan_name}" "${log}")"
  [[ " ${plan_line} " == *" -state=${state_path} "* ]]
  [[ " ${apply_line} " == *" -state=${state_path} "* ]]
}

assert_host_remote_state_free() {
  local script="$1"
  local log="${TEST_TMP}/${script}/raw.log"
  local host_commands
  host_commands="$(grep 'tofu .*/infrastructure/greenfield \(plan\|apply\) ' "${log}")"
  [[ "$(wc -l <<<"${host_commands}")" -eq 2 ]]
  [[ "${host_commands}" != *'-state'* ]]
}

deploy_saved_plan_uses_planned_external_state() {
  run_operator deploy $'hms-abcdef123456\nhms-abcdef123456\n'
  assert_matching_external_state deploy '/infrastructure/greenfield-state' 'state-foundation.tfplan'
  assert_host_remote_state_free deploy
}

teardown_host_saved_plan_uses_remote_state() {
  run_operator teardown $'hms-abcdef123456\n'
  assert_host_remote_state_free teardown
}

purge_saved_plan_uses_planned_external_state() {
  run_operator purge $'destroy-host-hms-abcdef123456\npurge-state-hms-abcdef123456\n'
  assert_matching_external_state purge '/greenfield-state-purge' 'state-foundation-destroy.tfplan'
  assert_host_remote_state_free purge
}

case "${1:-all}" in
  deploy) deploy_saved_plan_uses_planned_external_state ;;
  teardown) teardown_host_saved_plan_uses_remote_state ;;
  purge) purge_saved_plan_uses_planned_external_state ;;
  all)
    deploy_saved_plan_uses_planned_external_state
    teardown_host_saved_plan_uses_remote_state
    purge_saved_plan_uses_planned_external_state
    ;;
  *) printf 'unknown test case: %s\n' "$1" >&2; exit 2 ;;
esac
