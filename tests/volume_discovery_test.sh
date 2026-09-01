#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
passed=0 failed=0

pass() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'not ok - %s\n' "$1"; failed=$((failed + 1)); }
run_case() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }

run_discovery() {
  local mode="$1" case_dir
  case_dir="$(mktemp -d "${TEST_TMP}/case.XXXXXX")"
  mkdir -p "${case_dir}/bin"
  cp "${REPO_ROOT}/tests/support/volume-discovery-aws-mock.sh" "${case_dir}/bin/aws"
  chmod +x "${case_dir}/bin/aws"
  : >"${case_dir}/calls"
  PATH="${case_dir}/bin:${PATH}" MOCK_VOLUME_MODE="${mode}" MOCK_VOLUME_CALLS="${case_dir}/calls" \
    bash -c 'source "$1/scripts/lib.sh"; data_volume_id_for hms-abcdef123456 i-0123456789abcdef0' \
      _ "${REPO_ROOT}" >"${case_dir}/output" 2>&1
  RUN_STATUS=$? RUN_OUTPUT="$(<"${case_dir}/output")" RUN_CALLS="$(<"${case_dir}/calls")"
}

valid_exact_match() {
  run_discovery valid
  (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == vol-0abc1234def567890 ]] &&
    [[ "${RUN_CALLS}" == *'Name=tag:Deployment,Values=hms-abcdef123456'* ]] &&
    [[ "${RUN_CALLS}" == *'Name=tag:Name,Values=hms-abcdef123456-data'* ]] &&
    [[ "${RUN_CALLS}" == *'Name=attachment.instance-id,Values=i-0123456789abcdef0'* ]] &&
    [[ "${RUN_CALLS}" == *'--output json'* ]]
}

fails_closed() {
  local mode="$1"
  run_discovery "${mode}"
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" != vol-* ]]
}

run_case 'exact reviewed volume is returned with all filters' valid_exact_match
for mode in zero multiple malformed-id too-short too-long malformed-json api-error malformed-attachment wrong-instance not-attached multiple-attachments; do
  run_case "${mode} response is fatal" fails_closed "${mode}"
done

printf '1..%d\n# passed: %d, failed: %d\n' "$((passed + failed))" "${passed}" "${failed}"
(( failed == 0 ))
