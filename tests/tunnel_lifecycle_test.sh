#!/usr/bin/env bash

set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${REPO_ROOT}/scripts/support/run-hermes-tunnel.sh"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf -- "${TEST_TMP}"' EXIT
passed=0 failed=0
pass() { printf 'ok - %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf 'not ok - %s\n' "$1"; failed=$((failed + 1)); }
run_case() { local name="$1"; shift; if "$@"; then pass "${name}"; else fail "${name}"; fi; }

readonly TOKEN_DIR='/var/lib/hermes/cloudflare-tunnel'
readonly TOKEN_FILE="${TOKEN_DIR}/token"

run_helper() {
  local case_dir
  case_dir="$(mktemp -d "${TEST_TMP}/case.XXXXXX")"
  mkdir -p "${case_dir}/bin"
  cp "${REPO_ROOT}/tests/support/docker-tunnel-mock.sh" "${case_dir}/bin/docker"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${MOCK_UID:-0}"\n' >"${case_dir}/bin/id"
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "${MOCK_TOKEN_NEWLINES:-0}" "${3:-}"\n' >"${case_dir}/bin/wc"
  cat >"${case_dir}/bin/stat" <<STAT
#!/usr/bin/env bash
set -euo pipefail
args="\$*"
if [[ "\${args}" == *"${TOKEN_FILE}"* ]]; then
  case "\${MOCK_FILE_STATE:-valid}" in
    absent) exit 1 ;;
    symlink) printf 'symbolic link|600|root|root|42\n' ;;
    wrong-mode) printf 'regular file|644|root|root|42\n' ;;
    wrong-owner) printf 'regular file|600|operator|operator|42\n' ;;
    empty) printf 'regular file|600|root|root|0\n' ;;
    too-large) printf 'regular file|600|root|root|999999\n' ;;
    *) printf 'regular file|600|root|root|42\n' ;;
  esac
elif [[ "\${args}" == *"${TOKEN_DIR}"* ]]; then
  case "\${MOCK_DIR_STATE:-valid}" in
    absent) exit 1 ;;
    not-directory) printf 'regular file|700|root|root\n' ;;
    wrong-mode) printf 'directory|755|root|root\n' ;;
    wrong-owner) printf 'directory|700|operator|operator\n' ;;
    *) printf 'directory|700|root|root\n' ;;
  esac
else
  echo "unexpected stat target: \${args}" >&2
  exit 90
fi
STAT
  chmod +x "${case_dir}/bin/docker" "${case_dir}/bin/id" "${case_dir}/bin/stat" "${case_dir}/bin/wc"
  : >"${case_dir}/calls"
  PATH="${case_dir}/bin:${PATH}" MOCK_TUNNEL_CALLS="${case_dir}/calls" \
    HERMES_TUNNEL_STABILITY_SECONDS=0 bash "${HELPER}" "$@" >"${case_dir}/output" 2>&1
  RUN_STATUS=$? RUN_OUTPUT="$(<"${case_dir}/output")" RUN_CALLS="$(<"${case_dir}/calls")"
}

non_root_rejected_before_anything() {
  MOCK_UID=1000 run_helper start
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'must be run as root'* ]] && [[ -z "${RUN_CALLS}" ]]
}

invalid_subcommand_rejected() {
  run_helper bogus
  (( RUN_STATUS == 2 )) && [[ -z "${RUN_CALLS}" ]]
}

dir_guard_rejected_before_docker() {
  MOCK_DIR_STATE="$1" run_helper start
  (( RUN_STATUS != 0 )) && [[ -z "${RUN_CALLS}" ]]
}

file_guard_rejected_before_docker() {
  MOCK_FILE_STATE="$1" run_helper start
  (( RUN_STATUS != 0 )) && [[ -z "${RUN_CALLS}" ]]
}

multiline_token_rejected_before_docker() {
  MOCK_TOKEN_NEWLINES=1 run_helper start
  (( RUN_STATUS != 0 )) && [[ -z "${RUN_CALLS}" ]] && [[ "${RUN_OUTPUT}" == *'no newline bytes'* ]]
}

gateway_missing_makes_no_network_call() {
  MOCK_TUNNEL_GATEWAY_MODE=missing run_helper start
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'hermes-gateway'* ]] &&
    [[ "${RUN_CALLS}" != *'network'* ]] && [[ "${RUN_CALLS}" != *'run -d'* ]]
}

gateway_stopped_makes_no_network_call() {
  MOCK_TUNNEL_GATEWAY_MODE=stopped run_helper start
  (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'not running'* ]] &&
    [[ "${RUN_CALLS}" != *'network'* ]] && [[ "${RUN_CALLS}" != *'run -d'* ]]
}

network_absent_is_created() {
  MOCK_TUNNEL_NETWORK_MODE=absent run_helper start
  (( RUN_STATUS == 0 )) && [[ "$(grep -c '^network create --driver bridge hermes-tunnel-net$' <<<"${RUN_CALLS}")" -eq 1 ]]
}

network_mismatch_rejected_before_mutation() {
  MOCK_TUNNEL_NETWORK_MODE="$1" run_helper start
  (( RUN_STATUS != 0 )) && [[ "${RUN_CALLS}" != *'network create'* && "${RUN_CALLS}" != *'network connect'* ]]
}

gateway_detached_is_auto_attached_without_recreate() {
  MOCK_TUNNEL_GATEWAY_MODE=detached run_helper start
  (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" == *'network connect hermes-tunnel-net hermes-gateway'* ]]
}

failed_attach_rolls_back_freshly_created_network() {
  MOCK_TUNNEL_GATEWAY_MODE=connect-fail MOCK_TUNNEL_NETWORK_MODE=absent run_helper start
  (( RUN_STATUS != 0 )) && [[ "${RUN_CALLS}" == *'network create --driver bridge hermes-tunnel-net'* ]] &&
    [[ "${RUN_CALLS}" == *'network rm hermes-tunnel-net'* ]] &&
    [[ "${RUN_CALLS}" != *'network disconnect'* ]] && [[ "${RUN_CALLS}" != *'container rm'* ]]
}

failed_attach_does_not_remove_preexisting_network() {
  MOCK_TUNNEL_GATEWAY_MODE=connect-fail MOCK_TUNNEL_NETWORK_MODE=valid run_helper start
  (( RUN_STATUS != 0 )) && [[ "${RUN_CALLS}" != *'network rm'* ]]
}

matching_running() { run_helper start; (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" != *' rm '* && "${RUN_CALLS}" != *' run '* && "${RUN_CALLS}" != *' start '* ]]; }
matching_stopped() { MOCK_TUNNEL_CONTAINER_MODE=matching-stopped run_helper start; (( RUN_STATUS == 0 )) && [[ "$(grep -c '^container start hermes-cloudflared$' <<<"${RUN_CALLS}")" -eq 1 ]]; }
mismatch_rejected() { MOCK_TUNNEL_CONTAINER_MODE="mismatch-$1" run_helper start; (( RUN_STATUS != 0 )) && [[ "${RUN_CALLS}" != *'network '* && "${RUN_CALLS}" != *' rm '* && "${RUN_CALLS}" != *' start '* && "${RUN_CALLS}" != *' run '* ]] && [[ "${RUN_OUTPUT}" == *'no changes were made'* ]]; }
absent_created() { MOCK_TUNNEL_CONTAINER_MODE=absent run_helper start; (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" == *'run -d --name hermes-cloudflared --restart unless-stopped --network hermes-tunnel-net --user 0:0 --cap-drop ALL --security-opt no-new-privileges --read-only --volume /var/lib/hermes/cloudflare-tunnel/token:/run/secrets/cloudflared-token:ro cloudflare/cloudflared@sha256:51c9cefcb4569df44e1ad403ab1d3d8065aa8e84339bcfc6aee75502e1140339 tunnel --no-autoupdate run --token-file /run/secrets/cloudflared-token'* ]]; }
failed_create_rolls_back_network() { MOCK_TUNNEL_CONTAINER_MODE=run-fail MOCK_TUNNEL_NETWORK_MODE=absent MOCK_TUNNEL_GATEWAY_MODE=detached run_helper start; (( RUN_STATUS != 0 )) && [[ "${RUN_CALLS}" == *'network disconnect hermes-tunnel-net hermes-gateway'* ]] && [[ "${RUN_CALLS}" == *'network rm hermes-tunnel-net'* ]]; }
recreate_replaces() { MOCK_TUNNEL_CONTAINER_MODE=matching-running run_helper start --recreate; (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" == *'container rm -f hermes-cloudflared'* ]] && [[ "${RUN_CALLS}" == *'run -d '* ]]; }
immediate_exit() { MOCK_TUNNEL_CONTAINER_MODE="$1" run_helper start "${2:-}"; (( RUN_STATUS != 0 )) && [[ "${RUN_OUTPUT}" == *'did not remain running'* ]] && [[ "${RUN_CALLS}" != *'logs '* ]]; }
fresh_create_stability_failure_rolls_back_owned_resources() {
  MOCK_TUNNEL_CONTAINER_MODE=absent-exit-after-run MOCK_TUNNEL_NETWORK_MODE=absent MOCK_TUNNEL_GATEWAY_MODE=detached run_helper start
  (( RUN_STATUS != 0 )) &&
    [[ "${RUN_CALLS}" == *'container rm -f hermes-cloudflared'* ]] &&
    [[ "${RUN_CALLS}" == *'network disconnect hermes-tunnel-net hermes-gateway'* ]] &&
    [[ "${RUN_CALLS}" == *'network rm hermes-tunnel-net'* ]]
}
preexisting_start_stability_failure_rolls_back_only_new_attachment() {
  MOCK_TUNNEL_CONTAINER_MODE=exit-after-start MOCK_TUNNEL_NETWORK_MODE=valid MOCK_TUNNEL_GATEWAY_MODE=detached run_helper start
  (( RUN_STATUS != 0 )) &&
    [[ "${RUN_CALLS}" == *'network disconnect hermes-tunnel-net hermes-gateway'* ]] &&
    [[ "${RUN_CALLS}" != *'network rm hermes-tunnel-net'* ]] &&
    [[ "${RUN_CALLS}" != *'container rm -f hermes-cloudflared'* ]]
}

status_absent() { MOCK_TUNNEL_CONTAINER_MODE=absent run_helper status; (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == *'does not exist'* ]] && [[ "${RUN_CALLS}" != *'network'* ]]; }
status_matching() { run_helper status; (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == *'matches the expected tunnel contract and is running'* ]]; }
status_mismatched() { MOCK_TUNNEL_CONTAINER_MODE=mismatch-image run_helper status; (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == *'does not match the expected tunnel contract'* ]]; }
status_requires_no_token() { MOCK_DIR_STATE=absent MOCK_FILE_STATE=absent run_helper status; (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == *'matches the expected tunnel contract'* ]]; }
status_rejects_arguments() { run_helper status extra; (( RUN_STATUS == 2 )) && [[ -z "${RUN_CALLS}" ]]; }

stop_absent_is_idempotent() { MOCK_TUNNEL_CONTAINER_MODE=absent run_helper stop; (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == *'nothing to stop'* ]] && [[ "${RUN_CALLS}" != *'container stop'* ]]; }
stop_running_container() { run_helper stop; (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" == *'container stop hermes-cloudflared'* ]] && [[ "${RUN_OUTPUT}" == *'stopped'* ]]; }
stop_already_stopped_is_idempotent() { MOCK_TUNNEL_CONTAINER_MODE=matching-stopped run_helper stop; (( RUN_STATUS == 0 )) && [[ "${RUN_OUTPUT}" == *'already stopped'* ]] && [[ "${RUN_CALLS}" != *'container stop'* ]]; }
stop_refuses_mismatched_container() { MOCK_TUNNEL_CONTAINER_MODE=mismatch-image run_helper stop; (( RUN_STATUS != 0 )) && [[ "${RUN_CALLS}" != *'container stop'* ]] && [[ "${RUN_OUTPUT}" == *'refusing to stop'* ]]; }
stop_requires_no_token() { MOCK_DIR_STATE=absent MOCK_FILE_STATE=absent run_helper stop; (( RUN_STATUS == 0 )) && [[ "${RUN_CALLS}" == *'container stop hermes-cloudflared'* ]]; }
stop_rejects_arguments() { run_helper stop extra; (( RUN_STATUS == 2 )) && [[ -z "${RUN_CALLS}" ]]; }

run_case 'non-root invocation is rejected before any Docker or stat call' non_root_rejected_before_anything
run_case 'invalid subcommand is rejected before any Docker call' invalid_subcommand_rejected
for guard_mode in absent not-directory wrong-mode wrong-owner; do
  run_case "token directory ${guard_mode} is rejected before Docker" dir_guard_rejected_before_docker "${guard_mode}"
done
for guard_mode in absent symlink wrong-mode wrong-owner empty too-large; do
  run_case "token file ${guard_mode} is rejected before Docker" file_guard_rejected_before_docker "${guard_mode}"
done
run_case 'multiline token file is rejected before Docker' multiline_token_rejected_before_docker
run_case 'missing hermes-gateway container makes no network mutation' gateway_missing_makes_no_network_call
run_case 'stopped hermes-gateway container makes no network mutation' gateway_stopped_makes_no_network_call
run_case 'absent private network is created' network_absent_is_created
for mode in mismatch-driver mismatch-internal; do
  run_case "network ${mode} is rejected before mutation" network_mismatch_rejected_before_mutation "${mode}"
done
run_case 'detached hermes-gateway is auto-attached on normal first start' gateway_detached_is_auto_attached_without_recreate
run_case 'failed attach rolls back a network created by this invocation' failed_attach_rolls_back_freshly_created_network
run_case 'failed attach does not remove a pre-existing network' failed_attach_does_not_remove_preexisting_network
run_case 'matching running tunnel container is retained' matching_running
run_case 'matching stopped tunnel container is started' matching_stopped
for field in image command bind restart privileged capabilities cap-drop user ports publish-all network extra-network extra-mount volumes-from readonly security-opt; do
  run_case "unsafe ${field} is rejected and preserved" mismatch_rejected "${field}"
done
run_case 'absent tunnel container is created exactly' absent_created
run_case 'failed tunnel creation rolls back gateway attachment and fresh network' failed_create_rolls_back_network
run_case '--recreate replaces existing tunnel container' recreate_replaces
run_case 'immediate exit after start is rejected' immediate_exit exit-after-start
run_case 'immediate exit after replacement is rejected' immediate_exit exit-after-run --recreate
run_case 'fresh create stability failure rolls back owned container, attachment, and network' fresh_create_stability_failure_rolls_back_owned_resources
run_case 'pre-existing start stability failure rolls back only the new gateway attachment' preexisting_start_stability_failure_rolls_back_only_new_attachment

run_case 'status reports an absent container without touching the network' status_absent
run_case 'status reports a matching running container' status_matching
run_case 'status reports a mismatched container without failing' status_mismatched
run_case 'status does not require a provisioned token' status_requires_no_token
run_case 'status rejects extra arguments' status_rejects_arguments

run_case 'stop is idempotent when the container is absent' stop_absent_is_idempotent
run_case 'stop stops a running matching container' stop_running_container
run_case 'stop is idempotent when already stopped' stop_already_stopped_is_idempotent
run_case 'stop refuses to touch a mismatched same-name container' stop_refuses_mismatched_container
run_case 'stop does not require a provisioned token' stop_requires_no_token
run_case 'stop rejects extra arguments' stop_rejects_arguments

printf '1..%d\n# passed: %d, failed: %d\n' "$((passed + failed))" "${passed}" "${failed}"
(( failed == 0 ))
