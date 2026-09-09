#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CASE_DIR="$(mktemp -d)"
trap 'rm -rf -- "${CASE_DIR}"' EXIT
mkdir -p "${CASE_DIR}/bin"
CALLS="${CASE_DIR}/calls"
: >"${CALLS}"
cat >"${CASE_DIR}/bin/aws" <<'MOCK'
#!/usr/bin/env bash
printf '%q ' "$@" >>"${MOCK_CALLS}"
printf '\n' >>"${MOCK_CALLS}"
if [[ " $* " == *' ec2 describe-instances '* && " $* " == *' --instance-ids '* ]]; then echo running; exit 0; fi
case " $* " in
  *' sts get-caller-identity '*) echo 450895596262 ;;
  *' ec2 describe-volumes '*) printf '{"Volumes":[{"VolumeId":"vol-0123456789abcdef0","Attachments":[{"InstanceId":"i-abcdef1234567890","State":"attached"}]}]}\n' ;;
  *' ec2 describe-instances '*) echo i-abcdef1234567890 ;;
  *' ssm describe-instance-information '*) echo Online ;;
  *' ssm send-command '*) echo cmd-install ;;
  *' ssm get-command-invocation '*) printf '{"Status":"Success","StandardOutputContent":"helpers installed","StandardErrorContent":""}\n' ;;
  *' ssm start-session '*) echo interactive-started ;;
  *) echo "unexpected aws call: $*" >&2; exit 90 ;;
esac
MOCK
chmod +x "${CASE_DIR}/bin/aws"

set +e
PATH="${CASE_DIR}/bin:${PATH}" MOCK_CALLS="${CALLS}" AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock \
  HERMES_SSM_DEADLINE_SECONDS=0 HERMES_SSM_POLL_INTERVAL_SECONDS=0 \
  bash "${REPO_ROOT}/hermes.sh" configure-tunnel hms-abcdef123456 >"${CASE_DIR}/output" 2>&1
status=$?
set -e
output="$(< "${CASE_DIR}/output")"
calls="$(< "${CALLS}")"
(( status == 0 ))
[[ "${calls}" == *'ssm send-command'* && "${calls}" == *'ssm start-session'* ]]
[[ "${calls}" == *'AWS-StartInteractiveCommand'* ]]
[[ "${calls}" == *'/usr/local/sbin/configure-cloudflare-tunnel'* ]]
[[ "${calls}" == *'/usr/local/sbin/run-hermes-tunnel'* ]]
[[ "${calls}" == *'vol-0123456789abcdef0'* ]]
[[ "${calls}" != *'CLOUDFLARE_API_TOKEN'* && "${calls}" != *'Bearer'* ]]
[[ "${calls}" != *'authorize-security-group-ingress'* && "${calls}" != *'--publish'* ]]
[[ "${output}" == *'API token only in the remote hidden prompt'* ]]

: >"${CALLS}"
set +e
PATH="${CASE_DIR}/bin:${PATH}" MOCK_CALLS="${CALLS}" AWS_ACCESS_KEY_ID=mock AWS_SECRET_ACCESS_KEY=mock \
  bash "${REPO_ROOT}/hermes.sh" configure-tunnel hms-abcdef123456 --token secret >/dev/null 2>&1
invalid_status=$?
set -e
(( invalid_status == 2 ))
[[ ! -s "${CALLS}" ]]

printf '%s\n' 'configure_tunnel_operator_test.sh: PASS'
