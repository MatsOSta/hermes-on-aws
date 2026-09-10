#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
passed=0
failed=0

pass() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'not ok - %s\n' "$1"; failed=$((failed + 1)); }
run_case() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }

make_fixture() {
  local fixture="$1"
  mkdir -p -- "${fixture}/scripts/support"
  cp -- "${REPO_ROOT}/hermes.sh" "${fixture}/hermes.sh"
  cp -- "${REPO_ROOT}/scripts/lib.sh" "${fixture}/scripts/lib.sh"
  cp -- "${REPO_ROOT}/scripts/support/run-hermes-gateway.sh" \
    "${fixture}/scripts/support/run-hermes-gateway.sh"
  if [[ -f "${REPO_ROOT}/scripts/version.sh" ]]; then
    cp -- "${REPO_ROOT}/scripts/version.sh" "${fixture}/scripts/version.sh"
  fi
  chmod +x "${fixture}/hermes.sh" "${fixture}/scripts/lib.sh" \
    "${fixture}/scripts/support/run-hermes-gateway.sh"
  [[ ! -f "${fixture}/scripts/version.sh" ]] || chmod +x "${fixture}/scripts/version.sh"
  git -C "${fixture}" init -q
  git -C "${fixture}" config user.name 'Version Test'
  git -C "${fixture}" config user.email 'version-test@example.invalid'
  git -C "${fixture}" add .
  git -C "${fixture}" commit -qm 'fixture'
}

run_version() {
  local fixture="$1" cwd="$2"
  shift 2
  (
    cd -- "${cwd}" || exit 1
    HOME="${TEST_TMP}/home" bash "${fixture}/hermes.sh" version "$@"
  ) >"${fixture}/output" 2>&1
  RUN_STATUS=$?
  RUN_OUTPUT="$(<"${fixture}/output")"
}

clean_checkout_reports_stable_exact_provenance() {
  local fixture="${TEST_TMP}/clean" expected_commit expected_image
  make_fixture "${fixture}"
  expected_commit="$(git -C "${fixture}" rev-parse HEAD)"
  expected_image="$(sed -n "s/^readonly HERMES_IMAGE='\([^']*\)'$/\1/p" \
    "${fixture}/scripts/support/run-hermes-gateway.sh")"

  run_version "${fixture}" "${TEST_TMP}"

  (( RUN_STATUS == 0 )) &&
    [[ "${RUN_OUTPUT}" == "git_commit=${expected_commit}"$'\n'"git_tracked_dirty=false"$'\n'"hermes_image=${expected_image}" ]]
}

tracked_changes_are_dirty_but_untracked_files_are_ignored() {
  local fixture="${TEST_TMP}/dirty"
  make_fixture "${fixture}"
  : >"${fixture}/scratch.txt"
  run_version "${fixture}" /tmp
  (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == *$'git_tracked_dirty=false\n'* ]] || return

  printf '\n# tracked change\n' >>"${fixture}/hermes.sh"
  run_version "${fixture}" /
  (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == *$'git_tracked_dirty=true\n'* ]]
}

runtime_helper_is_the_reported_image_source() {
  local fixture="${TEST_TMP}/runtime-source"
  make_fixture "${fixture}"
  sed -i "s#^readonly HERMES_IMAGE=.*#readonly HERMES_IMAGE='example.invalid/hermes@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'#" \
    "${fixture}/scripts/support/run-hermes-gateway.sh"

  run_version "${fixture}" "${fixture}"

  (( RUN_STATUS == 0 )) &&
    [[ "${RUN_OUTPUT}" == *$'hermes_image=example.invalid/hermes@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]]
}

malformed_or_mutable_runtime_image_fails_closed() {
  local fixture="${TEST_TMP}/malformed" bad_assignment
  for bad_assignment in \
    "readonly HERMES_IMAGE='nousresearch/hermes-agent:latest'" \
    "readonly HERMES_IMAGE='broken'" \
    ''; do
    rm -rf -- "${fixture}"
    make_fixture "${fixture}"
    sed -i '/^readonly HERMES_IMAGE=/d' "${fixture}/scripts/support/run-hermes-gateway.sh"
    [[ -z "${bad_assignment}" ]] || printf '%s\n' "${bad_assignment}" >>"${fixture}/scripts/support/run-hermes-gateway.sh"
    run_version "${fixture}" "${fixture}"
    (( RUN_STATUS != 0 )) || return
    [[ "${RUN_OUTPUT}" == *'unable to determine one digest-pinned Hermes runtime image'* ]] || return
  done
}

git_status_failure_fails_closed() {
  local fixture="${TEST_TMP}/git-failure" fake_bin="${TEST_TMP}/fake-bin" real_git
  make_fixture "${fixture}"
  real_git="$(command -v git)"
  mkdir -p -- "${fake_bin}"
  # The generated fixture expands these variables at runtime.
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ " $* " == *" status "* ]]; then exit 77; fi' \
    'exec "${REAL_GIT}" "$@"' >"${fake_bin}/git"
  chmod +x "${fake_bin}/git"

  PATH="${fake_bin}:${PATH}" REAL_GIT="${real_git}" HOME="${TEST_TMP}/home" \
    bash "${fixture}/hermes.sh" version >"${fixture}/output" 2>&1
  RUN_STATUS=$?
  RUN_OUTPUT="$(<"${fixture}/output")"

  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'unable to inspect tracked Git state'* ]]
}

extra_arguments_are_rejected() {
  local fixture="${TEST_TMP}/args"
  make_fixture "${fixture}"
  run_version "${fixture}" "${fixture}" unexpected
  (( RUN_STATUS == 2 )) && [[ "${RUN_OUTPUT}" == *'Usage:'* ]]
}

production_image_assignments_cannot_silently_drift() {
  local reported_image assignment_file assignment image_count=0
  reported_image="$(bash "${REPO_ROOT}/hermes.sh" version | sed -n 's/^hermes_image=//p')" || return
  while IFS= read -r assignment_file; do
    assignment="$(sed -n "s/^\(readonly \)\{0,1\}HERMES_IMAGE=['\"]\([^'\"]*\)['\"]$/\2/p" "${assignment_file}")"
    [[ -n "${assignment}" && "${assignment}" == "${reported_image}" ]] || return
    image_count=$((image_count + 1))
  done < <(git -C "${REPO_ROOT}" grep -l '^\(readonly \)\{0,1\}HERMES_IMAGE=' -- \
    scripts infrastructure/aws)
  (( image_count >= 2 ))
}

run_case 'clean checkout reports stable exact provenance from any cwd' clean_checkout_reports_stable_exact_provenance
run_case 'tracked changes are dirty while untracked files are ignored' tracked_changes_are_dirty_but_untracked_files_are_ignored
run_case 'gateway runtime helper is the reported image source' runtime_helper_is_the_reported_image_source
run_case 'malformed or mutable runtime image fails closed' malformed_or_mutable_runtime_image_fails_closed
run_case 'Git status failure fails closed' git_status_failure_fails_closed
run_case 'extra arguments are rejected' extra_arguments_are_rejected
run_case 'production image assignments cannot silently drift' production_image_assignments_cannot_silently_drift

printf '1..%d\n# passed: %d, failed: %d\n' "$((passed + failed))" "${passed}" "${failed}"
(( failed == 0 ))
