#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
TEST_TMP="$(mktemp -d)"
readonly TEST_TMP
trap 'rm -rf -- "${TEST_TMP}"' EXIT

passed=0
failed=0

pass() {
  printf 'ok - %s\n' "$1"
  passed=$((passed + 1))
}

fail() {
  printf 'not ok - %s\n' "$1"
  [[ -z "${2:-}" ]] || printf '  %s\n' "$2"
  failed=$((failed + 1))
}

run_case() {
  local name="$1"
  shift
  if "$@"; then
    pass "${name}"
  else
    fail "${name}"
  fi
}

make_aws_mock() {
  local case_dir="$1"
  mkdir -p -- "${case_dir}/bin"
  cp -- "${REPO_ROOT}/tests/support/aws-mock.sh" "${case_dir}/bin/aws"
  chmod +x "${case_dir}/bin/aws"
}

profile_overrides_stale_credentials() {
  local case_dir="${TEST_TMP}/profile" output status
  make_aws_mock "${case_dir}"
  output="$(PATH="${case_dir}/bin:${PATH}" MOCK_AWS_MODE=profile \
    AWS_PROFILE=platform-lab-tofu AWS_ACCESS_KEY_ID=STALE \
    AWS_SECRET_ACCESS_KEY=STALE AWS_SESSION_TOKEN=STALE \
    AWS_SECURITY_TOKEN=STALE AWS_CREDENTIAL_EXPIRATION=PAST \
    bash -c 'source "$1/scripts/lib.sh"; aws_preflight' _ "${REPO_ROOT}" 2>&1)"
  status=$?
  (( status == 0 )) || { printf '%s\n' "${output}"; return 1; }
  return 0
}

expired_static_credentials_fail() {
  local case_dir="${TEST_TMP}/expired" output status
  make_aws_mock "${case_dir}"
  output="$(PATH="${case_dir}/bin:${PATH}" MOCK_AWS_MODE=expired \
    AWS_ACCESS_KEY_ID=EXPIRED AWS_SECRET_ACCESS_KEY=EXPIRED \
    bash -c 'source "$1/scripts/lib.sh"; aws_preflight' _ "${REPO_ROOT}" 2>&1)"
  status=$?
  (( status != 0 )) && [[ "${output}" == *'static environment credentials'* ]] && \
    [[ "${output}" == *'ExpiredToken'* ]]
}

wrong_account_is_rejected() {
  local case_dir="${TEST_TMP}/wrong-account" output status
  make_aws_mock "${case_dir}"
  output="$(PATH="${case_dir}/bin:${PATH}" MOCK_AWS_MODE=wrong-account \
    AWS_ACCESS_KEY_ID=VALID AWS_SECRET_ACCESS_KEY=VALID \
    bash -c 'source "$1/scripts/lib.sh"; aws_preflight' _ "${REPO_ROOT}" 2>&1)"
  status=$?
  (( status != 0 )) && [[ "${output}" == *'999999999999'* ]] && \
    [[ "${output}" == *'450895596262'* ]]
}

list_discovery_failure_propagates() {
  local case_dir="${TEST_TMP}/list" output status
  make_aws_mock "${case_dir}"
  output="$(PATH="${case_dir}/bin:${PATH}" MOCK_AWS_MODE=list-failure \
    AWS_ACCESS_KEY_ID=VALID AWS_SECRET_ACCESS_KEY=VALID \
    bash "${REPO_ROOT}/scripts/list.sh" 2>&1)"
  status=$?
  (( status != 0 )) && [[ "${output}" == *'AccessDenied: cannot list buckets'* ]] && \
    [[ "${output}" != *'DEPLOYMENT'* ]]
}

missing_bucket_is_absent() {
  local case_dir="${TEST_TMP}/missing-bucket" status
  make_aws_mock "${case_dir}"
  PATH="${case_dir}/bin:${PATH}" MOCK_AWS_MODE=missing-bucket \
    AWS_ACCESS_KEY_ID=VALID AWS_SECRET_ACCESS_KEY=VALID \
    bash -c 'source "$1/scripts/lib.sh"; aws_preflight; ! state_bucket_exists hms-abcdef123456' \
      _ "${REPO_ROOT}"
  status=$?
  (( status == 0 ))
}

bucket_access_error_is_fatal() {
  local case_dir="${TEST_TMP}/bucket-denied" output status
  make_aws_mock "${case_dir}"
  output="$(PATH="${case_dir}/bin:${PATH}" MOCK_AWS_MODE=bucket-denied \
    AWS_ACCESS_KEY_ID=VALID AWS_SECRET_ACCESS_KEY=VALID \
    bash -c 'source "$1/scripts/lib.sh"; aws_preflight; if state_bucket_exists hms-abcdef123456; then exit 9; else exit 0; fi' \
      _ "${REPO_ROOT}" 2>&1)"
  status=$?
  (( status != 0 )) && [[ "${output}" == *'AccessDenied: cannot read bucket'* ]]
}

missing_credentials_print_canonical_login_flow() {
  local output status
  # `$1` is intentionally expanded by the child shell, not this test process.
  # shellcheck disable=SC2016
  output="$(env -u AWS_PROFILE -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
    -u AWS_SESSION_TOKEN -u AWS_SECURITY_TOKEN -u AWS_CREDENTIAL_EXPIRATION \
    bash -c 'source "$1/scripts/lib.sh"; aws_preflight' _ "${REPO_ROOT}" 2>&1)"
  status=$?
  (( status != 0 )) &&
    [[ "${output}" == *'aws login --profile platform-lab'* ]] &&
    [[ "${output}" == *'export AWS_PROFILE=platform-lab-tofu'* ]] &&
    [[ "${output}" != *'aws sso login'* ]] &&
    [[ "${output}" != *'awslogin && awsexport'* ]]
}

run_case 'AWS_PROFILE overrides stale exported credentials' profile_overrides_stale_credentials
run_case 'expired static credentials fail preflight' expired_static_credentials_fail
run_case 'wrong AWS account is rejected' wrong_account_is_rejected
run_case 'list discovery failure is nonzero' list_discovery_failure_propagates
run_case 'missing state bucket is reported absent' missing_bucket_is_absent
run_case 'state bucket access error is fatal' bucket_access_error_is_fatal
run_case 'missing credentials print canonical login flow' missing_credentials_print_canonical_login_flow

printf '1..%d\n' "$((passed + failed))"
printf '# passed: %d, failed: %d\n' "${passed}" "${failed}"
(( failed == 0 ))
