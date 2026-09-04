#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
readonly ID='hms-abcdef123456' OTHER_ID='hms-123456abcdef'
passed=0 failed=0

pass() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'not ok - %s\n' "$1"; failed=$((failed + 1)); }
run_case() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }

new_home() {
  local home
  home="$(mktemp -d "${TEST_TMP}/home.XXXXXX")"
  printf '%s\n' "${home}"
}

run_hermes() {
  local home="$1"; shift
  HOME="${home}" bash "${REPO_ROOT}/hermes.sh" "$@"
}

registry_is_secure() {
  local home="$1" registry="${1}/hermes-operator/aliases"
  [[ -f "${registry}" && ! -L "${registry}" ]] &&
    [[ "$(stat -c '%u:%a' -- "${home}/hermes-operator")" == "$(id -u):700" ]] &&
    [[ "$(stat -c '%u:%a' -- "${registry}")" == "$(id -u):600" ]]
}

id_alias_is_atomic_and_stdout_safe() {
  local home output registry
  home="$(new_home)"
  output="$(run_hermes "${home}" id --alias smoketest 2>"${home}/stderr")" || return
  [[ "${output}" =~ ^hms-[a-f0-9]{12}$ ]] && [[ ! -s "${home}/stderr" ]] || return
  registry="${home}/hermes-operator/aliases"
  registry_is_secure "${home}" && [[ "$(<"${registry}")" == $'smoketest\t'"${output}" ]]
}

plain_id_remains_registry_free() {
  local home output
  home="$(new_home)"; output="$(run_hermes "${home}" id)" || return
  [[ "${output}" =~ ^hms-[a-f0-9]{12}$ ]] && [[ ! -e "${home}/hermes-operator" ]]
}

management_lifecycle_and_uniqueness() {
  local home output status=0
  home="$(new_home)"
  run_hermes "${home}" alias set smoketest "${ID}" >/dev/null || return
  output="$(run_hermes "${home}" alias list)" || return
  [[ "${output}" == $'ALIAS\tDEPLOYMENT\nsmoketest\thms-abcdef123456' ]] || return
  run_hermes "${home}" alias set duplicate "${ID}" >/dev/null 2>&1 && return 1
  run_hermes "${home}" alias set smoketest "${OTHER_ID}" >/dev/null 2>&1 && return 1
  run_hermes "${home}" alias rename smoketest validation >/dev/null || return
  [[ "$(run_hermes "${home}" alias list)" == $'ALIAS\tDEPLOYMENT\nvalidation\thms-abcdef123456' ]] || return
  run_hermes "${home}" alias remove validation >/dev/null || return
  [[ "$(run_hermes "${home}" alias list)" == $'ALIAS\tDEPLOYMENT' ]] || return
  run_hermes "${home}" alias remove validation >/dev/null 2>&1 || status=$?
  (( status != 0 ))
}

alias_format_is_narrow_and_ids_are_reserved() {
  local home alias
  home="$(new_home)"
  for alias in Upper under_score -leading trailing- 'two words' 'hms-abcdef123456' "$(printf 'a%.0s' {1..64})"; do
    if run_hermes "${home}" alias set "${alias}" "${ID}" >/dev/null 2>&1; then return 1; fi
  done
}

make_dispatch_fixture() {
  local fixture="$1" script
  mkdir -p "${fixture}/scripts/support"
  cp "${REPO_ROOT}/hermes.sh" "${fixture}/hermes.sh"
  cp "${REPO_ROOT}/scripts/lib.sh" "${fixture}/scripts/lib.sh"
  cp "${REPO_ROOT}/scripts/support/deployment-aliases.py" "${fixture}/scripts/support/deployment-aliases.py"
  for script in deploy teardown purge install start stop ssm logs start-gateway start-tunnel status-tunnel stop-tunnel status list; do
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nprintf "%%s" "$0" >>"${DISPATCH_LOG}"\nprintf " <%%s>" "$@" >>"${DISPATCH_LOG}"\nprintf "\\n" >>"${DISPATCH_LOG}"\n' >"${fixture}/scripts/${script}.sh"
    chmod +x "${fixture}/scripts/${script}.sh"
  done
  chmod +x "${fixture}/hermes.sh"
}

all_target_dispatch_is_canonical() {
  local home fixture command direct_log alias_log
  home="$(new_home)"; fixture="${TEST_TMP}/dispatch"; make_dispatch_fixture "${fixture}"
  HOME="${home}" bash "${fixture}/hermes.sh" alias set smoketest "${ID}" >/dev/null || return
  for command in deploy teardown purge install start stop ssm logs status-tunnel stop-tunnel; do
    : >"${home}/direct"; : >"${home}/alias"
    HOME="${home}" DISPATCH_LOG="${home}/direct" bash "${fixture}/hermes.sh" "${command}" "${ID}" || return
    HOME="${home}" DISPATCH_LOG="${home}/alias" bash "${fixture}/hermes.sh" "${command}" smoketest || return
    direct_log="$(<"${home}/direct")"; alias_log="$(<"${home}/alias")"
    [[ "${direct_log}" == "${alias_log}" && "${alias_log}" == *" <${ID}>" && "${alias_log}" != *smoketest* ]] || return 1
  done
  for args in 'start-gateway|smoketest|' 'start-gateway|smoketest|--recreate' 'start-tunnel|smoketest|' 'start-tunnel|smoketest|--recreate' 'status|smoketest|'; do
    IFS='|' read -r command _target option <<<"${args}"
    : >"${home}/direct"; : >"${home}/alias"
    HOME="${home}" DISPATCH_LOG="${home}/direct" bash "${fixture}/hermes.sh" "${command}" "${ID}" ${option:+"${option}"} || return
    HOME="${home}" DISPATCH_LOG="${home}/alias" bash "${fixture}/hermes.sh" "${command}" smoketest ${option:+"${option}"} || return
    direct_log="$(<"${home}/direct")"; alias_log="$(<"${home}/alias")"
    [[ "${direct_log}" == "${alias_log}" && "${alias_log}" == *" <${ID}>"* && "${alias_log}" != *smoketest* ]] || return 1
  done
  : >"${home}/alias"
  HOME="${home}" DISPATCH_LOG="${home}/alias" bash "${fixture}/hermes.sh" status || return
  [[ "$(<"${home}/alias")" == *'/status.sh <>' ]]
}

unknown_alias_fails_before_dispatch() {
  local home fixture status=0
  home="$(new_home)"; fixture="${TEST_TMP}/unknown"; make_dispatch_fixture "${fixture}"; : >"${home}/calls"
  HOME="${home}" DISPATCH_LOG="${home}/calls" bash "${fixture}/hermes.sh" deploy unknown >/dev/null 2>&1 || status=$?
  (( status != 0 )) && [[ ! -s "${home}/calls" ]]
}

direct_id_ignores_missing_registry() {
  local home fixture
  home="$(new_home)"; fixture="${TEST_TMP}/missing"; make_dispatch_fixture "${fixture}"; : >"${home}/calls"
  HOME="${home}" DISPATCH_LOG="${home}/calls" bash "${fixture}/hermes.sh" stop "${ID}" || return
  [[ "$(<"${home}/calls")" == *" <${ID}>" ]]
}

legacy_operator_root_reports_exact_migration() {
  local home output status=0
  home="$(new_home)"
  mkdir -m 755 "${home}/hermes-operator"
  output="$(run_hermes "${home}" alias set smoketest "${ID}" 2>&1)" || status=$?
  (( status != 0 )) &&
    [[ "${output}" == *"chmod 700 -- ${home}/hermes-operator"* ]] &&
    [[ "$(stat -c '%a' -- "${home}/hermes-operator")" == 755 ]]
}

loaded_registry_lookup_uses_validated_snapshot() {
  local home output
  home="$(new_home)"
  run_hermes "${home}" alias set smoketest "${ID}" >/dev/null || return
  output="$(HOME="${home}" REPO_ROOT="${REPO_ROOT}" bash -c '
    source "${REPO_ROOT}/scripts/lib.sh"
    load_alias_registry
    rm -- "${OPERATOR_ROOT}/aliases"
    alias_for_deployment_id "hms-abcdef123456"
  ')" || return
  [[ "${output}" == smoketest ]]
}

unsafe_registry_fails_before_dispatch() {
  local mode="$1" home fixture registry status=0
  home="$(new_home)"; fixture="${TEST_TMP}/unsafe-${mode}"; make_dispatch_fixture "${fixture}"
  mkdir -m 700 "${home}/hermes-operator"; registry="${home}/hermes-operator/aliases"
  case "${mode}" in
    symlink) printf 'smoketest\t%s\n' "${ID}" >"${home}/target"; ln -s "${home}/target" "${registry}" ;;
    permissions) printf 'smoketest\t%s\n' "${ID}" >"${registry}"; chmod 644 "${registry}" ;;
    type) mkdir "${registry}" ;;

    malformed) printf 'smoketest %s\n' "${ID}" >"${registry}"; chmod 600 "${registry}" ;;
    duplicate-alias) printf 'smoketest\t%s\nsmoketest\t%s\n' "${ID}" "${OTHER_ID}" >"${registry}"; chmod 600 "${registry}" ;;
    duplicate-id) printf 'smoketest\t%s\nvalidation\t%s\n' "${ID}" "${ID}" >"${registry}"; chmod 600 "${registry}" ;;
  esac
  : >"${home}/calls"
  HOME="${home}" PATH="${fixture}/bin:${PATH}" DISPATCH_LOG="${home}/calls" bash "${fixture}/hermes.sh" start smoketest >/dev/null 2>&1 || status=$?
  (( status != 0 )) && [[ ! -s "${home}/calls" ]]
}

empty_registry_fields_fail_before_dispatch() {
  local record home fixture registry status
  for record in \
    $'smoketest\t\thms-abcdef123456' \
    $'\tsmoketest\thms-abcdef123456' \
    $'smoketest\thms-abcdef123456\t'; do
    home="$(new_home)"; fixture="$(mktemp -d "${TEST_TMP}/empty-field.XXXXXX")"
    make_dispatch_fixture "${fixture}"
    mkdir -m 700 "${home}/hermes-operator"; registry="${home}/hermes-operator/aliases"
    printf '%s\n' "${record}" >"${registry}"; chmod 600 "${registry}"; : >"${home}/calls"
    status=0
    HOME="${home}" DISPATCH_LOG="${home}/calls" bash "${fixture}/hermes.sh" start smoketest >/dev/null 2>&1 || status=$?
    (( status != 0 )) && [[ ! -s "${home}/calls" ]] || return 1
  done
}

helper_swap_is_not_followed() {
  local mode="$1" home
  home="$(new_home)"
  python3 - "${REPO_ROOT}/scripts/support/deployment-aliases.py" "${mode}" "${home}" <<'PY'
import importlib.util
import os
import pathlib
import sys

helper_path, mode, home = sys.argv[1:]
spec = importlib.util.spec_from_file_location("deployment_aliases", helper_path)
assert spec and spec.loader
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

root = pathlib.Path(home) / "hermes-operator"
root.mkdir(mode=0o700)
entry = "aliases" if mode == "registry" else "aliases.lock"
victim = pathlib.Path(home) / "victim"
victim.write_bytes(b"sentinel\n")
victim.chmod(0o600)
(root / entry).write_bytes(b"benign\thms-abcdef123456\n" if mode == "registry" else b"")
(root / entry).chmod(0o600)
before = (victim.stat().st_dev, victim.stat().st_ino, victim.read_bytes())
root_fd = helper.open_root(str(root), create=False)
assert root_fd is not None
real_open = helper.os.open
swapped = False


def swapping_open(path, flags, mode_bits=0o777, *, dir_fd=None):
    global swapped
    if path == entry and dir_fd == root_fd and not swapped:
        os.unlink(entry, dir_fd=root_fd)
        os.symlink(str(victim), entry, dir_fd=root_fd)
        swapped = True
    return real_open(path, flags, mode_bits, dir_fd=dir_fd)


helper.os.open = swapping_open
rejected = False
try:
    if mode == "registry":
        helper.read_registry(root_fd)
    else:
        helper.open_lock(root_fd)
except helper.RegistryError:
    rejected = True
finally:
    os.close(root_fd)

after = (victim.stat().st_dev, victim.stat().st_ino, victim.read_bytes())
if not (swapped and rejected and before == after and (root / entry).is_symlink()):
    raise SystemExit(1)
PY
}

registry_swap_is_not_followed() { helper_swap_is_not_followed registry; }

lock_swap_is_not_followed() { helper_swap_is_not_followed lock; }

opened_registry_owner_is_validated() {
  python3 - "${REPO_ROOT}/scripts/support/deployment-aliases.py" <<'PY'
import importlib.util
import os
import stat
import sys
import types
from unittest import mock

spec = importlib.util.spec_from_file_location("deployment_aliases", sys.argv[1])
assert spec and spec.loader
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
metadata = types.SimpleNamespace(st_mode=stat.S_IFREG | 0o600, st_uid=os.geteuid() + 1)
with mock.patch.object(helper.os, "fstat", return_value=metadata):
    try:
        helper.validate_fd(123, "alias registry", 0o600)
    except helper.RegistryError as error:
        if "alias registry must be owned by the current user" in str(error):
            raise SystemExit(0)
raise SystemExit(1)
PY
}

parallel_updates_are_not_lost() {
  local home pid_one pid_two status_one status_two output
  home="$(new_home)"
  run_hermes "${home}" alias set one "${ID}" >/dev/null & pid_one=$!
  run_hermes "${home}" alias set two "${OTHER_ID}" >/dev/null & pid_two=$!
  wait "${pid_one}"; status_one=$?; wait "${pid_two}"; status_two=$?
  output="$(run_hermes "${home}" alias list)" || return
  (( status_one == 0 && status_two == 0 )) && [[ "${output}" == *$'one\thms-abcdef123456'* ]] && [[ "${output}" == *$'two\thms-123456abcdef'* ]]
}

run_observer() {
  local home="$1"; shift
  local case_dir="${home}/observe"
  mkdir -p "${case_dir}/bin"
  cp "${REPO_ROOT}/tests/support/alias-aws-mock.sh" "${case_dir}/bin/aws"
  chmod +x "${case_dir}/bin/aws"
  : >"${case_dir}/calls"
  HOME="${home}" PATH="${case_dir}/bin:${PATH}" MOCK_ALIAS_AWS_CALLS="${case_dir}/calls" \
    AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock bash "${REPO_ROOT}/hermes.sh" "$@"
}

list_and_status_all_show_alias_and_canonical_id() {
  local home output
  home="$(new_home)"; run_hermes "${home}" alias set smoketest "${ID}" >/dev/null || return
  output="$(run_observer "${home}" list)" || return
  [[ "${output}" == *'ALIAS'* && "${output}" == *'DEPLOYMENT'* && "${output}" == *smoketest* && "${output}" == *"${ID}"* ]] || return
  output="$(run_observer "${home}" status)" || return
  [[ "${output}" == *smoketest* && "${output}" == *"${ID}"* ]] &&
    ! grep -q smoketest "${home}/observe/calls"
}

single_status_labels_alias_without_leaking_it() {
  local home output
  home="$(new_home)"; run_hermes "${home}" alias set smoketest "${ID}" >/dev/null || return
  output="$(run_observer "${home}" status smoketest)" || return
  [[ "${output}" == *'Alias:            smoketest'* && "${output}" == *"Deployment:       ${ID}"* ]] &&
    ! grep -q smoketest "${home}/observe/calls"
}

direct_status_bypasses_malformed_registry() {
  local home registry output
  home="$(new_home)"
  mkdir -m 700 "${home}/hermes-operator"
  registry="${home}/hermes-operator/aliases"
  printf 'malformed-record\n' >"${registry}"
  chmod 600 "${registry}"
  output="$(run_observer "${home}" status "${ID}")" || return
  [[ "${output}" == *"Deployment:       ${ID}"* && "${output}" != *'Alias:'* ]] &&
    ! grep -q malformed-record "${home}/observe/calls"
}

list_without_registry_keeps_legacy_shape() {
  local home output
  home="$(new_home)"; output="$(run_observer "${home}" list)" || return
  [[ "${output}" == DEPLOYMENT* && "${output}" != *ALIAS* && "${output}" == *"${ID}"* ]]
}

alias_teardown_keeps_canonical_confirmation() {
  local home case_dir tool status=0
  home="$(new_home)"; run_hermes "${home}" alias set smoketest "${ID}" >/dev/null || return
  case_dir="${home}/destructive"; mkdir -p "${case_dir}/bin"
  for tool in aws tofu; do
    cp "${REPO_ROOT}/tests/support/destructive-preflight-mock.sh" "${case_dir}/bin/${tool}"
    chmod +x "${case_dir}/bin/${tool}"
  done
  : >"${case_dir}/events"; : >"${case_dir}/raw"
  printf '%s\n' "${ID}" | env HOME="${home}" PATH="${case_dir}/bin:${PATH}" \
    AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock MOCK_CASE_DIR="${case_dir}" \
    MOCK_LOG="${case_dir}/events" MOCK_RAW_LOG="${case_dir}/raw" \
    bash "${REPO_ROOT}/hermes.sh" teardown smoketest >/dev/null 2>"${case_dir}/stderr" || status=$?
  (( status == 0 )) && ! grep -q smoketest "${case_dir}/raw" &&
    [[ "$(<"${case_dir}/events")" == $'host-init\nhost-plan\nhost-show\nhost-apply' ]]
}

run_case 'id --alias atomically records a secure mapping and prints only ID' id_alias_is_atomic_and_stdout_safe
run_case 'plain id remains registry-free and compatible' plain_id_remains_registry_free
run_case 'set/list/rename/remove enforce uniqueness' management_lifecycle_and_uniqueness
run_case 'alias validation is narrow and reserves opaque IDs' alias_format_is_narrow_and_ids_are_reserved
run_case 'all target dispatch groups receive only canonical IDs' all_target_dispatch_is_canonical
run_case 'unknown aliases fail before dispatch' unknown_alias_fails_before_dispatch
run_case 'direct IDs work without a registry' direct_id_ignores_missing_registry
run_case 'legacy operator root reports exact migration without changing it' legacy_operator_root_reports_exact_migration
run_case 'alias display lookup uses one validated registry snapshot' loaded_registry_lookup_uses_validated_snapshot
for mode in symlink permissions type malformed duplicate-alias duplicate-id; do
  run_case "${mode} registry fails before dispatch" unsafe_registry_fails_before_dispatch "${mode}"
done
run_case 'registry records with repeated tabs or empty fields fail closed' empty_registry_fields_fail_before_dispatch
run_case 'registry symlink swap is never followed' registry_swap_is_not_followed
run_case 'lock symlink swap is never followed' lock_swap_is_not_followed
run_case 'opened registry owner is validated with fstat' opened_registry_owner_is_validated
run_case 'parallel atomic updates are not lost' parallel_updates_are_not_lost
run_case 'list and status-all show alias with canonical ID only sent to AWS' list_and_status_all_show_alias_and_canonical_id
run_case 'single status labels local alias without leaking it' single_status_labels_alias_without_leaking_it
run_case 'direct status bypasses a malformed alias registry' direct_status_bypasses_malformed_registry
run_case 'list without a registry keeps its legacy shape' list_without_registry_keeps_legacy_shape
run_case 'alias teardown still requires the canonical confirmation' alias_teardown_keeps_canonical_confirmation

printf '1..%d\n# passed: %d, failed: %d\n' "$((passed + failed))" "${passed}" "${failed}"
(( failed == 0 ))
