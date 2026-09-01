#!/usr/bin/env bash

set -uo pipefail
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${REPO_ROOT}/scripts/support/mount-hermes-data-volume.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
passed=0 failed=0
pass() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'not ok - %s\n' "$1"; failed=$((failed + 1)); }
run_case() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }

run_helper() {
  local mode="$1" case_dir tool volume_id='vol-0abc1234def567890'
  case_dir="$(mktemp -d "${TEST_TMP}/case.XXXXXX")"
  mkdir -p "${case_dir}/bin"
  cp "${REPO_ROOT}/tests/support/mount-command-mock.sh" "${case_dir}/bin/mock"
  ln -s /bin/bash "${case_dir}/bin/bash"
  for tool in id stat find lsblk wipefs blkid awk tee findmnt readlink mount chmod mkfs.xfs; do
    ln -s mock "${case_dir}/bin/${tool}"
  done
  chmod +x "${case_dir}/bin/mock"
  : >"${case_dir}/calls"
  case "${mode}" in
    malformed-id) volume_id='snap-0123' ;;
    too-short-id) volume_id='vol-0123456' ;;
    too-long-id) volume_id='vol-0123456789abcdef01' ;;
  esac
  PATH="${case_dir}/bin" MOCK_MOUNT_MODE="${mode}" MOCK_MOUNT_CALLS="${case_dir}/calls" \
    MOCK_MOUNT_STATE="${case_dir}/mounted" /bin/bash "${HELPER}" \
      "${volume_id}" \
      >"${case_dir}/output" 2>&1
  RUN_STATUS=$? RUN_CALLS="$(<"${case_dir}/calls")" RUN_OUTPUT="$(<"${case_dir}/output")"
}

event_count() { grep -c "^$1 " <<<"${RUN_CALLS}" || true; }
no_completion() { [[ "$(event_count chmod)" -eq 0 && "${RUN_OUTPUT}" != *'is mounted securely'* ]]; }
no_mutation() { [[ "$(event_count mkfs.xfs)" -eq 0 && "$(event_count tee)" -eq 0 && "$(event_count mount)" -eq 0 ]] && no_completion; }
mutation_events() { grep -E '^(mkfs\.xfs|tee|mount|chmod) ' <<<"${RUN_CALLS}" || true; }

success_first_install_discovered_device() { run_helper xfs-discovered; (( RUN_STATUS == 0 )) && [[ "$(event_count mkfs.xfs)" -eq 0 ]] && [[ "${RUN_CALLS}" == *'blkid -s TYPE -o value -- /dev/nvme7n1'* ]] && [[ "${RUN_CALLS}" == *'findmnt -rn -S /dev/nvme7n1 -o TARGET'* ]] && [[ "${RUN_CALLS}" == *'readlink -f -- /dev/nvme7n1'* ]] && [[ "${RUN_CALLS}" == *'FSTAB_LINE UUID=11111111-2222-3333-4444-555555555555 /var/lib/hermes xfs defaults,nodev,nosuid 0 2'* ]] && [[ "$(grep -c '^mount /var/lib/hermes$' <<<"${RUN_CALLS}")" -eq 1 ]]; }
no_signature_discovered_device_formats_once() { run_helper none-discovered; (( RUN_STATUS == 0 )) && [[ "$(grep -c '^mkfs.xfs /dev/nvme7n1$' <<<"${RUN_CALLS}")" -eq 1 ]] && [[ "$(event_count mkfs.xfs)" -eq 1 ]] && [[ "$(grep -c '^mount /var/lib/hermes$' <<<"${RUN_CALLS}")" -eq 1 ]]; }
mounted_rerun_idempotent() { run_helper mounted; (( RUN_STATUS == 0 )) && [[ "$(event_count mkfs.xfs)" -eq 0 && "$(event_count tee)" -eq 0 && "$(event_count mount)" -eq 0 ]]; }
rejected_before_mutation() { local mode="$1"; run_helper "${mode}"; (( RUN_STATUS != 0 )) && no_mutation; }
invalid_id_rejected_before_storage() { local mode="$1"; run_helper "${mode}"; (( RUN_STATUS != 0 )) && [[ "$(event_count lsblk)" -eq 0 && "$(event_count wipefs)" -eq 0 ]] && no_mutation; }
expected_mount_attempt_failure() { local mode="$1"; run_helper "${mode}"; (( RUN_STATUS != 0 )) && [[ "$(mutation_events)" == $'tee -a /etc/fstab\nmount /var/lib/hermes' ]] && [[ "$(event_count mount)" -eq 1 ]] && no_completion; }
format_failure_is_fatal() { run_helper mkfs-fail; (( RUN_STATUS != 0 )) && [[ "$(grep -c '^mkfs.xfs /dev/nvme1n1$' <<<"${RUN_CALLS}")" -eq 1 ]] && [[ "$(event_count tee)" -eq 0 && "$(event_count mount)" -eq 0 ]] && no_completion; }

run_case 'existing XFS on discovered device is mounted without formatting' success_first_install_discovered_device
run_case 'signature-free discovered device is formatted XFS once' no_signature_discovered_device_formats_once
run_case 'correctly mounted rerun is idempotent' mounted_rerun_idempotent
for mode in ext4 multiple-signatures missing-serial ambiguous-serial child-device nonempty conflicting-fstab duplicate-fstab wrong-source wrong-type wrong-options overriding-options malformed-id non-root blank-conflicting-fstab blank-duplicate-fstab expected-mounted-elsewhere; do
  run_case "${mode} fails before mutation" rejected_before_mutation "${mode}"
done
run_case 'too-short volume ID is rejected before storage inspection' invalid_id_rejected_before_storage too-short-id
run_case 'too-long volume ID is rejected before storage inspection' invalid_id_rejected_before_storage too-long-id
run_case 'mount failure stops after the expected mount attempt' expected_mount_attempt_failure mount-failure
run_case 'post-mount verification failure stops after the expected mount attempt' expected_mount_attempt_failure verify-failure
run_case 'mkfs failure is fatal' format_failure_is_fatal
printf '1..%d\n# passed: %d, failed: %d\n' "$((passed + failed))" "${passed}" "${failed}"
(( failed == 0 ))
