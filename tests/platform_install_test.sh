#!/usr/bin/env bash

set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
readonly ID='hms-abcdef123456'
passed=0 failed=0
pass() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'not ok - %s\n' "$1"; failed=$((failed + 1)); }
run_case() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }

new_home() {
  local home
  home="$(mktemp -d "${TEST_TMP}/home.XXXXXX")"
  printf '%s\n' "${home}"
}

make_dispatch_fixture() {
  local fixture="$1"
  mkdir -p -- "${fixture}/scripts/support"
  cp -- "${REPO_ROOT}/hermes.sh" "${fixture}/hermes.sh"
  cp -- "${REPO_ROOT}/scripts/lib.sh" "${fixture}/scripts/lib.sh"
  cp -- "${REPO_ROOT}/scripts/support/deployment-aliases.py" "${fixture}/scripts/support/deployment-aliases.py"
  cat >"${fixture}/scripts/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DISPATCH_CALLS}"
EOF
  chmod +x "${fixture}/hermes.sh" "${fixture}/scripts/install.sh" \
    "${fixture}/scripts/support/deployment-aliases.py"
}

run_dispatch() {
  local fixture="$1" home="$2"
  shift 2
  : >"${fixture}/calls"
  HOME="${home}" DISPATCH_CALLS="${fixture}/calls" bash "${fixture}/hermes.sh" "$@" \
    >"${fixture}/output" 2>&1
  RUN_STATUS=$?
  RUN_OUTPUT="$(<"${fixture}/output")"
  RUN_CALLS="$(<"${fixture}/calls")"
}

accepted_spellings_are_canonical() {
  local fixture="${TEST_TMP}/accepted" home spelling
  make_dispatch_fixture "${fixture}"
  home="$(new_home)"
  for spelling in '--platform line' '--line' '-l'; do
    # Deliberate word splitting expands the two-word canonical spelling.
    # shellcheck disable=SC2086
    run_dispatch "${fixture}" "${home}" install "${ID}" ${spelling}
    (( RUN_STATUS == 0 )) || return
    [[ "${RUN_CALLS}" == "${ID} line" ]] || return
  done
}

legacy_install_is_unchanged() {
  local fixture="${TEST_TMP}/legacy" home
  make_dispatch_fixture "${fixture}"
  home="$(new_home)"
  run_dispatch "${fixture}" "${home}" install "${ID}"
  (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" == "${ID}" ]]
}

alias_resolves_before_canonical_dispatch() {
  local fixture="${TEST_TMP}/alias" home
  make_dispatch_fixture "${fixture}"
  home="$(new_home)"
  HOME="${home}" DISPATCH_CALLS="${fixture}/calls" bash "${fixture}/hermes.sh" alias set pilot "${ID}" >/dev/null || return
  run_dispatch "${fixture}" "${home}" install pilot --platform line
  (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" == "${ID} line" ]]
}

invalid_invocation_fails_before_dispatch() {
  local fixture="${TEST_TMP}/invalid" home invocation
  make_dispatch_fixture "${fixture}"
  home="$(new_home)"
  local -a invalid=(
    "install ${ID} --platform signal"
    "install ${ID} --platform"
    "install ${ID} --line -l"
    "install ${ID} --platform line --line"
    "install --platform line ${ID}"
    "install ${ID} -line"
    "install ${ID} --channel-secret do-not-print-this"
  )
  for invocation in "${invalid[@]}"; do
    # Deliberate word splitting exercises invalid argv shapes.
    # shellcheck disable=SC2086
    run_dispatch "${fixture}" "${home}" ${invocation}
    (( RUN_STATUS == 2 )) || return
    [[ -z "${RUN_CALLS}" ]] || return
    [[ "${RUN_OUTPUT}" != *'do-not-print-this'* ]] || return
  done
}

run_real_line_install() {
  local home="$1" mode="$2"
  shift 2
  local case_dir
  case_dir="$(mktemp -d "${TEST_TMP}/install.XXXXXX")"
  mkdir -p "${case_dir}/bin"
  cp "${REPO_ROOT}/tests/support/install-aws-mock.sh" "${case_dir}/bin/aws"
  chmod +x "${case_dir}/bin/aws"
  : >"${case_dir}/calls"
  HOME="${home}" PATH="${case_dir}/bin:${PATH}" MOCK_INSTALL_MODE="${mode}" \
    MOCK_INSTALL_CALLS="${case_dir}/calls" \
    MOCK_INSTALL_EXPECTED_HELPER="${REPO_ROOT}/scripts/support/mount-hermes-data-volume.sh" \
    AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock HERMES_SSM_DEADLINE_SECONDS=0 \
    HERMES_SSM_POLL_INTERVAL_SECONDS=0 bash "${REPO_ROOT}/hermes.sh" install "${ID}" --platform line "$@" \
      >"${case_dir}/output" 2>&1
  RUN_STATUS=$?
  RUN_OUTPUT="$(<"${case_dir}/output")"
  RUN_CALLS="$(<"${case_dir}/calls")"
}

line_install_records_restricted_truthful_state() {
  local home state
  home="$(new_home)"
  state="${home}/hermes-operator/install-platforms/${ID}"
  run_real_line_install "${home}" success
  (( RUN_STATUS == 0 )) || return
  [[ -f "${state}" && ! -L "${state}" ]] || return
  [[ "$(stat -c '%a' -- "${home}/hermes-operator")" == 700 ]] || return
  [[ "$(stat -c '%a' -- "${home}/hermes-operator/install-platforms")" == 700 ]] || return
  [[ "$(stat -c '%a' -- "${state}")" == 600 ]] || return
  [[ "$(<"${state}")" == $'version=1\nplatform=line\nhost_prepared=1' ]] || return
  [[ "${RUN_OUTPUT}" == *'[complete] Platform intent: line'* ]] || return
  [[ "${RUN_OUTPUT}" == *'[complete] Host preparation: verified by this run'* ]] || return
  [[ "${RUN_OUTPUT}" == *'[pending] Secure LINE runtime configuration; run:'* ]] || return
  [[ "${RUN_OUTPUT}" == *'./hermes.sh configure-line hms-abcdef123456'* ]] || return
  [[ "${RUN_OUTPUT}" == *'[pending] Cloudflare tunnel and hostname provisioning; after starting the gateway, run:'* ]] || return
  [[ "${RUN_OUTPUT}" == *'./hermes.sh configure-tunnel hms-abcdef123456'* ]] || return
  [[ "${RUN_OUTPUT}" == *'[unverified] Provider-console settings and live message acceptance (#49)'* ]] || return
  [[ "${RUN_OUTPUT}" != *'LINE ready'* ]]
}

matching_rerun_retains_state() {
  local home state before_inode before_mtime
  home="$(new_home)"
  state="${home}/hermes-operator/install-platforms/${ID}"
  run_real_line_install "${home}" success || return
  before_inode="$(stat -c '%i' -- "${state}")"
  before_mtime="$(stat -c '%Y' -- "${state}")"
  run_real_line_install "${home}" success
  (( RUN_STATUS == 0 )) || return
  [[ "$(stat -c '%i' -- "${state}")" == "${before_inode}" ]] || return
  [[ "$(stat -c '%Y' -- "${state}")" == "${before_mtime}" ]] || return
  [[ "${RUN_OUTPUT}" == *'Retaining matching LINE install intent.'* ]]
}

contradictory_state_fails_before_aws() {
  local home state
  home="$(new_home)"
  mkdir -m 700 -- "${home}/hermes-operator" "${home}/hermes-operator/install-platforms"
  state="${home}/hermes-operator/install-platforms/${ID}"
  printf 'version=1\nplatform=telegram\nhost_prepared=0\n' >"${state}"
  chmod 600 "${state}"
  run_real_line_install "${home}" success
  (( RUN_STATUS != 0 )) && [[ -z "${RUN_CALLS}" ]] &&
    [[ "${RUN_OUTPUT}" == *'recorded platform telegram conflicts with requested platform line'* ]]
}

unsafe_state_fails_before_aws() {
  local home state target
  home="$(new_home)"
  mkdir -m 700 -- "${home}/hermes-operator" "${home}/hermes-operator/install-platforms"
  state="${home}/hermes-operator/install-platforms/${ID}"
  target="${home}/outside"
  printf 'version=1\nplatform=line\nhost_prepared=0\n' >"${target}"
  chmod 600 "${target}"
  ln -s "${target}" "${state}"
  run_real_line_install "${home}" success
  (( RUN_STATUS != 0 )) && [[ -z "${RUN_CALLS}" ]] &&
    [[ "${RUN_OUTPUT}" == *'platform install state must not be a symbolic link'* ]]
}

run_case 'all LINE option spellings dispatch one canonical mode' accepted_spellings_are_canonical
run_case 'legacy install dispatch remains unchanged' legacy_install_is_unchanged
run_case 'deployment aliases resolve before canonical LINE dispatch' alias_resolves_before_canonical_dispatch
run_case 'invalid, duplicate, secret-like, and misplaced options fail before dispatch' invalid_invocation_fails_before_dispatch
run_case 'LINE install records restricted state and truthful phases' line_install_records_restricted_truthful_state
run_case 'matching rerun retains platform state' matching_rerun_retains_state
run_case 'contradictory platform state fails before AWS' contradictory_state_fails_before_aws
run_case 'unsafe platform state fails before AWS' unsafe_state_fails_before_aws
printf '1..%d\n# passed: %d, failed: %d\n' "$((passed + failed))" "${passed}" "${failed}"
(( failed == 0 ))
