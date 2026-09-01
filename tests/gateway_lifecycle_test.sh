#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${REPO_ROOT}/scripts/support/run-hermes-gateway.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
passed=0 failed=0
pass() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'not ok - %s\n' "$1"; failed=$((failed + 1)); }
run_case() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }

run_helper() {
  local mode="$1"; shift
  local case_dir volume_id='vol-0abc1234def567890'
  case "${mode}" in
    too-short-id) volume_id='vol-0123456' ;;
    too-long-id) volume_id='vol-0123456789abcdef01' ;;
  esac
  case_dir="$(mktemp -d "${TEST_TMP}/docker.XXXXXX")"
  mkdir -p "${case_dir}/bin"
  cp "${REPO_ROOT}/tests/support/docker-gateway-mock.sh" "${case_dir}/bin/docker"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${MOCK_UID:-0}"\n' >"${case_dir}/bin/id"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n[[ "$*" == "-c %%F -- /var/lib/hermes" ]] || exit 96\n[[ "${MOCK_DATA_DIR_ABSENT:-false}" != true ]] || exit 1\nprintf "%%s\\n" "${MOCK_DATA_DIR_TYPE:-directory}"\n' >"${case_dir}/bin/stat"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\ncase "${MOCK_MOUNT_GUARD_MODE:-valid}" in missing-serial) printf "/dev/nvme0n1 disk volroot\\n";; ambiguous-serial) printf "/dev/nvme1n1 disk vol0abc1234def567890\\n/dev/nvme2n1 disk vol-0abc1234def567890\\n";; child-device) printf "/dev/nvme1n1p1 part vol0abc1234def567890\\n";; *) printf "/dev/nvme1n1 disk vol0abc1234def567890\\n";; esac\n' >"${case_dir}/bin/lsblk"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\ncase "${MOCK_MOUNT_GUARD_MODE:-valid}" in absent) exit 1;; wrong-source) printf "/dev/nvme9n1 xfs rw,nodev,nosuid\\n";; wrong-type) printf "/dev/nvme1n1 ext4 rw,nodev,nosuid\\n";; wrong-options) printf "/dev/nvme1n1 xfs rw\\n";; overriding-options) printf "/dev/nvme1n1 xfs rw,nodev,dev,nosuid,suid\\n";; *) printf "/dev/nvme1n1 xfs rw,nodev,nosuid\\n";; esac\n' >"${case_dir}/bin/findmnt"
  printf '#!/usr/bin/env bash\n[[ "$*" == *nvme9n1* ]] && printf "/dev/nvme9n1\\n" || printf "/dev/nvme1n1\\n"\n' >"${case_dir}/bin/readlink"
  chmod +x "${case_dir}/bin/docker" "${case_dir}/bin/id" "${case_dir}/bin/stat" \
    "${case_dir}/bin/lsblk" "${case_dir}/bin/findmnt" "${case_dir}/bin/readlink"
  : >"${case_dir}/calls"
  PATH="${case_dir}/bin:${PATH}" MOCK_DOCKER_MODE="${mode}" MOCK_DOCKER_CALLS="${case_dir}/calls" \
    HERMES_GATEWAY_STABILITY_SECONDS=0 bash "${HELPER}" "${volume_id}" "$@" >"${case_dir}/output" 2>&1
  RUN_STATUS=$? RUN_OUTPUT="$(<"${case_dir}/output")" RUN_CALLS="$(<"${case_dir}/calls")"
}

non_root_rejected_before_docker() {
  MOCK_UID=1000 run_helper matching-running
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'must be run as root'* ]] && [[ -z "${RUN_CALLS}" ]]
}

absent_data_dir_rejected_before_mutation() {
  MOCK_DATA_DIR_ABSENT=true run_helper absent
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'/var/lib/hermes does not exist'* ]] &&
    [[ "${RUN_CALLS}" != *' rm '* && "${RUN_CALLS}" != *' start '* && "${RUN_CALLS}" != *' run '* ]]
}

non_directory_data_path_rejected_before_mutation() {
  MOCK_DATA_DIR_TYPE='regular file' run_helper absent
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'/var/lib/hermes does not exist'* ]] &&
    [[ "${RUN_CALLS}" != *' rm '* && "${RUN_CALLS}" != *' start '* && "${RUN_CALLS}" != *' run '* ]]
}

mount_guard_rejected_before_docker() {
  MOCK_MOUNT_GUARD_MODE="$1" run_helper absent
  (( RUN_STATUS != 0 )) && [[ -z "${RUN_CALLS}" ]]
}
invalid_id_rejected_before_docker() {
  run_helper "$1"
  (( RUN_STATUS != 0 )) && [[ -z "${RUN_CALLS}" ]]
}

matching_running() { run_helper matching-running; (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" != *' rm '* && "${RUN_CALLS}" != *' run '* && "${RUN_CALLS}" != *' start '* ]]; }
matching_stopped() { run_helper matching-stopped; (( RUN_STATUS == 0 )) && [[ "$(grep -c '^container start hermes-gateway$' <<<"${RUN_CALLS}")" -eq 1 ]]; }
mismatch_rejected() { run_helper "$1"; (( RUN_STATUS != 0 )) && [[ "${RUN_CALLS}" != *' rm '* && "${RUN_CALLS}" != *' start '* && "${RUN_CALLS}" != *' run '* ]] && [[ "${RUN_OUTPUT}" == *'no changes were made'* ]]; }
absent_created() { run_helper absent; (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" == *'run -d --name hermes-gateway --restart unless-stopped --volume /var/lib/hermes:/opt/data nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e hermes gateway run'* ]]; }
recreate_replaces() { run_helper matching-running --recreate; (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" == *'container rm -f hermes-gateway'* ]] && [[ "${RUN_CALLS}" == *'run -d '* ]]; }
immediate_exit() { run_helper "$1" "${2:-}"; (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'did not remain running'* ]] && [[ "${RUN_CALLS}" == *'logs --tail 50 hermes-gateway'* ]]; }

run_case 'matching running container is retained' matching_running
run_case 'mocked non-root uid is rejected before Docker' non_root_rejected_before_docker
run_case 'absent data directory is rejected before Docker mutation' absent_data_dir_rejected_before_mutation
run_case 'non-directory data path is rejected before Docker mutation' non_directory_data_path_rejected_before_mutation
for guard_mode in absent missing-serial ambiguous-serial child-device wrong-source wrong-type wrong-options overriding-options; do
  run_case "mount guard rejects ${guard_mode} before Docker" mount_guard_rejected_before_docker "${guard_mode}"
done
run_case 'too-short volume ID is rejected before Docker' invalid_id_rejected_before_docker too-short-id
run_case 'too-long volume ID is rejected before Docker' invalid_id_rejected_before_docker too-long-id
run_case 'matching stopped container is started' matching_stopped
for field in image command bind restart privileged capabilities ports publish-all host-network extra-mount volumes-from; do
  run_case "unsafe ${field} is rejected and preserved" mismatch_rejected "mismatch-${field}"
done
run_case 'absent container is created exactly' absent_created
run_case '--recreate replaces existing container' recreate_replaces
run_case 'immediate exit after start is rejected' immediate_exit exit-after-start
run_case 'immediate exit after replacement is rejected' immediate_exit exit-after-run --recreate

printf '1..%d\n# passed: %d, failed: %d\n' "$((passed + failed))" "${passed}" "${failed}"
(( failed == 0 ))
