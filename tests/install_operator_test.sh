#!/usr/bin/env bash

set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
passed=0 failed=0
pass() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'not ok - %s\n' "$1"; failed=$((failed + 1)); }
run_case() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }

run_install() {
  local mode="$1" case_dir
  case_dir="$(mktemp -d "${TEST_TMP}/case.XXXXXX")"
  mkdir -p "${case_dir}/bin"
  cp "${REPO_ROOT}/tests/support/install-aws-mock.sh" "${case_dir}/bin/aws"
  chmod +x "${case_dir}/bin/aws"
  : >"${case_dir}/calls"
  PATH="${case_dir}/bin:${PATH}" MOCK_INSTALL_MODE="${mode}" MOCK_INSTALL_CALLS="${case_dir}/calls" \
    MOCK_INSTALL_EXPECTED_HELPER="${REPO_ROOT}/scripts/support/mount-hermes-data-volume.sh" \
    AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock HERMES_SSM_DEADLINE_SECONDS=0 \
    HERMES_SSM_POLL_INTERVAL_SECONDS=0 bash "${REPO_ROOT}/scripts/install.sh" hms-abcdef123456 \
      >"${case_dir}/output" 2>&1
  RUN_STATUS=$? RUN_OUTPUT="$(<"${case_dir}/output")" RUN_CALLS="$(<"${case_dir}/calls")"
}

success_contract() {
  local mount_event docker_start_event docker_pull_event
  run_install success
  mount_event="$(grep -n '^MOUNT_HELPER ' <<<"${RUN_CALLS}" | cut -d: -f1)"
  docker_start_event="$(grep -n '^DOCKER_START$' <<<"${RUN_CALLS}" | cut -d: -f1)"
  docker_pull_event="$(grep -n '^DOCKER_PULL$' <<<"${RUN_CALLS}" | cut -d: -f1)"
  (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" == *DELIVERED_REVIEWED_MOUNT_HELPER* ]] &&
    [[ -n "${mount_event}" && -n "${docker_start_event}" && -n "${docker_pull_event}" ]] &&
    (( mount_event < docker_start_event && docker_start_event < docker_pull_event )) &&
    [[ "${RUN_CALLS}" == *'PACKAGES docker xfsprogs'* ]] && [[ "${RUN_OUTPUT}" == *'Status: Success'* ]]
}
discovery_failure_is_local() { run_install "$1"; (( RUN_STATUS != 0 )) && [[ "${RUN_CALLS}" != *'ssm send-command'* ]]; }
terminal_failure_no_success() { run_install terminal-failure; (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" != *'Run the setup wizard'* ]]; }

run_case 'install delivers exact helper, packages, ID, and mount-before-pull order' success_contract
for mode in volume-zero volume-multiple volume-malformed volume-too-short volume-too-long volume-api-error; do
  run_case "${mode} prevents SSM" discovery_failure_is_local "${mode}"
done
run_case 'terminal SSM failure cannot report setup readiness' terminal_failure_no_success
printf '1..%d\n# passed: %d, failed: %d\n' "$((passed + failed))" "${passed}" "${failed}"
(( failed == 0 ))
