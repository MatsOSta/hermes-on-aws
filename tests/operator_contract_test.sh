#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
CHECKER="${REPO_ROOT}/tests/support/check-operator-contract.sh"
readonly CHECKER
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

make_fixture() {
  local fixture="$1"
  mkdir -p -- "${fixture}/scripts" "${fixture}/tests/support" "${fixture}/infrastructure/aws"
  cp -- "${CHECKER}" "${fixture}/tests/support/check-operator-contract.sh"
  cp -- "${REPO_ROOT}/hermes.sh" "${fixture}/hermes.sh"
  cp -- "${REPO_ROOT}"/scripts/*.sh "${fixture}/scripts/"
  cp -- "${REPO_ROOT}"/infrastructure/aws/*.sh "${fixture}/infrastructure/aws/"
  printf '#!/usr/bin/env bash\n' >"${fixture}/tests/example_test.sh"
  chmod +x "${fixture}/hermes.sh" "${fixture}"/scripts/*.sh \
    "${fixture}"/tests/*.sh "${fixture}"/tests/support/*.sh \
    "${fixture}"/infrastructure/aws/*.sh
  git -C "${fixture}" init -q
  git -C "${fixture}" add .
}

checker_accepts_complete_contract() {
  local fixture="${TEST_TMP}/complete"
  make_fixture "${fixture}"
  "${CHECKER}" "${fixture}"
}

checker_rejects_missing_dispatch_target() {
  local fixture="${TEST_TMP}/missing-target" output
  make_fixture "${fixture}"
  rm -- "${fixture}/scripts/deploy.sh"
  git -C "${fixture}" add -u scripts/deploy.sh
  if output="$("${CHECKER}" "${fixture}" 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'missing tracked executable dispatch target: scripts/deploy.sh'* ]]
}

checker_rejects_missing_status_dispatch_target() {
  local fixture="${TEST_TMP}/missing-status-target" output
  make_fixture "${fixture}"
  rm -- "${fixture}/scripts/status.sh"
  git -C "${fixture}" add -u scripts/status.sh
  if output="$("${CHECKER}" "${fixture}" 2>&1)"; then
    return 1
  fi
  [[ "${output}" == 'missing tracked executable dispatch target: scripts/status.sh' ]]
}

checker_rejects_missing_list_dispatch_target() {
  local fixture="${TEST_TMP}/missing-list-target" output
  make_fixture "${fixture}"
  rm -- "${fixture}/scripts/list.sh"
  git -C "${fixture}" add -u scripts/list.sh
  if output="$("${CHECKER}" "${fixture}" 2>&1)"; then
    return 1
  fi
  [[ "${output}" == 'missing tracked executable dispatch target: scripts/list.sh' ]]
}

checker_rejects_non_executable_entry_point() {
  local fixture="${TEST_TMP}/non-executable" output
  make_fixture "${fixture}"
  chmod -x "${fixture}/scripts/deploy.sh"
  git -C "${fixture}" add scripts/deploy.sh
  if output="$("${CHECKER}" "${fixture}" 2>&1)"; then
    return 1
  fi
  [[ "${output}" == *'tracked shell entry point is not mode 100755: scripts/deploy.sh'* ]]
}

checker_accepts_complete_contract
checker_rejects_missing_dispatch_target
checker_rejects_missing_status_dispatch_target
checker_rejects_missing_list_dispatch_target
checker_rejects_non_executable_entry_point
