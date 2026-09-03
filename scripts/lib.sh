#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail

readonly AWS_REGION="eu-north-1"
readonly REVIEWED_AWS_ACCOUNT_ID="450895596262"
readonly OPERATOR_ROOT="${HOME}/hermes-operator"
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly ALIAS_HELPER="${REPO_ROOT}/scripts/support/deployment-aliases.py"
# These constants are consumed by scripts that source this library.
# shellcheck disable=SC2034
readonly STATE_ROOT="${REPO_ROOT}/infrastructure/greenfield-state"
# shellcheck disable=SC2034
readonly HOST_ROOT="${REPO_ROOT}/infrastructure/greenfield"

die() {
  echo "Error: $*" >&2
  exit 1
}

AWS_ACCOUNT_ID=""

aws_preflight() {
  local credential_source caller_identity

  require_tools aws

  if [[ -n "${AWS_PROFILE:-}" ]]; then
    credential_source="AWS profile '${AWS_PROFILE}'"
    export AWS_PROFILE
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN \
      AWS_CREDENTIAL_EXPIRATION
  elif [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    credential_source="static environment credentials"
  elif [[ -n "${AWS_ACCESS_KEY_ID:-}" || -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    die "Incomplete static environment credentials. Set both AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, or unset them and export AWS_PROFILE."
  else
    die "No AWS credentials found. Either:
  1. Run: awslogin && awsexport   (static env vars, valid ~1 hour)
  2. Or:  export AWS_PROFILE=platform-lab-tofu   (auto-refreshing via credential_process)"
  fi

  if ! caller_identity="$(aws --region "${AWS_REGION}" sts get-caller-identity \
    --query Account --output text 2>&1)"; then
    die "Unable to verify ${credential_source} with AWS STS in ${AWS_REGION}.
${caller_identity}
Refresh or replace the selected credentials, then retry."
  fi
  [[ "${caller_identity}" =~ ^[0-9]{12}$ ]] || \
    die "AWS STS returned an invalid account ID for ${credential_source}: ${caller_identity}"
  [[ "${caller_identity}" == "${REVIEWED_AWS_ACCOUNT_ID}" ]] || \
    die "Refusing AWS operation: ${credential_source} resolved to account ${caller_identity}; reviewed account is ${REVIEWED_AWS_ACCOUNT_ID} in region ${AWS_REGION}. Select the reviewed account and retry."
  AWS_ACCOUNT_ID="${caller_identity}"
}

require_tools() {
  local tool
  for tool in "$@"; do
    command -v "${tool}" >/dev/null 2>&1 || die "required command not found: ${tool}"
  done
}

validate_deployment_id() {
  local deployment_id="${1:-}"
  [[ "${deployment_id}" =~ ^hms-[a-f0-9]{12}$ ]] || die "deployment ID must match ^hms-[a-f0-9]{12}$"
}

validate_deployment_alias() {
  local deployment_alias="${1:-}"
  [[ "${deployment_alias}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || \
    die 'deployment alias must be 1-63 lowercase letters, digits, or interior hyphens'
  [[ ! "${deployment_alias}" =~ ^hms-[a-f0-9]{12}$ ]] || \
    die 'deployment aliases may not use the opaque deployment-ID namespace'
}

declare -ag DEPLOYMENT_ALIASES=()
declare -ag ALIAS_DEPLOYMENT_IDS=()

load_alias_registry() {
  local deployment_alias deployment_id index snapshot
  DEPLOYMENT_ALIASES=()
  ALIAS_DEPLOYMENT_IDS=()
  require_tools python3
  [[ -f "${ALIAS_HELPER}" ]] || die "required alias registry helper not found: ${ALIAS_HELPER}"
  snapshot="$(python3 "${ALIAS_HELPER}" read "${OPERATOR_ROOT}")" || return
  if [[ -n "${snapshot}" ]]; then
    while IFS=$'\t' read -r deployment_alias deployment_id; do
      # The helper emitted this canonical snapshot only after exact-field validation.
      DEPLOYMENT_ALIASES+=("${deployment_alias}")
      ALIAS_DEPLOYMENT_IDS+=("${deployment_id}")
    done <<<"${snapshot}"
  fi
}

resolve_deployment_target() {
  local target="$1" index
  if [[ "${target}" =~ ^hms-[a-f0-9]{12}$ ]]; then
    printf '%s\n' "${target}"
    return 0
  fi
  validate_deployment_alias "${target}"
  load_alias_registry
  for index in "${!DEPLOYMENT_ALIASES[@]}"; do
    if [[ "${DEPLOYMENT_ALIASES[index]}" == "${target}" ]]; then
      printf '%s\n' "${ALIAS_DEPLOYMENT_IDS[index]}"
      return 0
    fi
  done
  die "unknown deployment alias: ${target}"
}

alias_for_deployment_id() {
  local deployment_id="$1" index
  for index in "${!ALIAS_DEPLOYMENT_IDS[@]}"; do
    if [[ "${ALIAS_DEPLOYMENT_IDS[index]}" == "${deployment_id}" ]]; then
      printf '%s\n' "${DEPLOYMENT_ALIASES[index]}"
      return 0
    fi
  done
  return 1
}

alias_set() {
  local deployment_alias="$1" deployment_id="$2"
  validate_deployment_alias "${deployment_alias}"
  validate_deployment_id "${deployment_id}"
  require_tools python3
  [[ -f "${ALIAS_HELPER}" ]] || die "required alias registry helper not found: ${ALIAS_HELPER}"
  python3 "${ALIAS_HELPER}" set "${OPERATOR_ROOT}" "${deployment_alias}" "${deployment_id}"
}

alias_remove() {
  local target="$1"
  validate_deployment_alias "${target}"
  require_tools python3
  [[ -f "${ALIAS_HELPER}" ]] || die "required alias registry helper not found: ${ALIAS_HELPER}"
  python3 "${ALIAS_HELPER}" remove "${OPERATOR_ROOT}" "${target}"
}

alias_rename() {
  local old_alias="$1" new_alias="$2"
  validate_deployment_alias "${old_alias}"
  validate_deployment_alias "${new_alias}"
  require_tools python3
  [[ -f "${ALIAS_HELPER}" ]] || die "required alias registry helper not found: ${ALIAS_HELPER}"
  python3 "${ALIAS_HELPER}" rename "${OPERATOR_ROOT}" "${old_alias}" "${new_alias}"
}

alias_list() {
  local index
  load_alias_registry
  printf 'ALIAS\tDEPLOYMENT\n'
  for index in "${!DEPLOYMENT_ALIASES[@]}"; do
    printf '%s\t%s\n' "${DEPLOYMENT_ALIASES[index]}" "${ALIAS_DEPLOYMENT_IDS[index]}"
  done
}

operator_dir() {
  local deployment_id="$1"
  validate_deployment_id "${deployment_id}"
  printf '%s/%s\n' "${OPERATOR_ROOT}" "${deployment_id}"
}

account_id() {
  [[ "${AWS_ACCOUNT_ID}" == "${REVIEWED_AWS_ACCOUNT_ID}" ]] || \
    die "AWS preflight has not verified reviewed account ${REVIEWED_AWS_ACCOUNT_ID} in region ${AWS_REGION}"
  printf '%s\n' "${AWS_ACCOUNT_ID}"
}

state_bucket_name() {
  local deployment_id="$1"
  printf '%s-%s-%s-tofu-state\n' "$(account_id)" "${AWS_REGION}" "${deployment_id}"
}

state_bucket_exists() {
  local deployment_id="$1" bucket error
  bucket="$(state_bucket_name "${deployment_id}")"
  if error="$(aws --region "${AWS_REGION}" s3api head-bucket --bucket "${bucket}" 2>&1)"; then
    return 0
  fi
  if [[ "${error}" == *'(404)'* || "${error}" == *'Not Found'* || "${error}" == *'NoSuchBucket'* ]]; then
    return 1
  fi
  die "Unable to check state bucket ${bucket}:
${error}"
}

state_kms_key_arn() {
  local deployment_id="$1" alias_name
  alias_name="alias/$(state_bucket_name "${deployment_id}")"
  aws --region "${AWS_REGION}" kms describe-key \
    --key-id "${alias_name}" --query 'KeyMetadata.Arn' --output text
}

write_backend_config() {
  local deployment_id="$1" destination="$2" bucket kms_arn
  bucket="$(state_bucket_name "${deployment_id}")"
  kms_arn="$(state_kms_key_arn "${deployment_id}")"
  umask 077
  {
    printf 'bucket       = "%s"\n' "${bucket}"
    printf 'key          = "deployments/%s/terraform.tfstate"\n' "${deployment_id}"
    printf 'region       = "%s"\n' "${AWS_REGION}"
    printf 'encrypt      = true\n'
    printf 'kms_key_id   = "%s"\n' "${kms_arn}"
    printf 'use_lockfile = true\n'
  } >"${destination}"
}

instance_id_for() {
  local deployment_id="$1" instance_ids count
  validate_deployment_id "${deployment_id}"
  instance_ids="$(aws --region "${AWS_REGION}" ec2 describe-instances \
    --filters "Name=tag:Deployment,Values=${deployment_id}" \
      'Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped' \
    --query 'Reservations[].Instances[].InstanceId' --output text)"
  read -r -a instance_array <<<"${instance_ids}"
  count="${#instance_array[@]}"
  (( count > 0 )) || die "no active instance found for ${deployment_id}"
  (( count == 1 )) || die "multiple active instances found for ${deployment_id}: ${instance_ids}"
  printf '%s\n' "${instance_array[0]}"
}

instance_id_for_any_state() {
  local deployment_id="$1" instance_id
  validate_deployment_id "${deployment_id}"
  # Prefer the newest instance so a terminated predecessor does not mask a replacement.
  instance_id="$(aws --region "${AWS_REGION}" ec2 describe-instances \
    --filters "Name=tag:Deployment,Values=${deployment_id}" \
    --query 'sort_by(Reservations[].Instances[], &LaunchTime)[-1].InstanceId' --output text)"
  [[ "${instance_id}" != "None" && -n "${instance_id}" ]] || die "no instance found for ${deployment_id}"
  printf '%s\n' "${instance_id}"
}

data_volume_id_for() {
  local deployment_id="$1" instance_id="$2" response volume_id
  validate_deployment_id "${deployment_id}"
  [[ "${instance_id}" =~ ^i-[a-f0-9]+$ ]] || die "invalid EC2 instance ID: ${instance_id}"
  require_tools jq

  if ! response="$(aws --region "${AWS_REGION}" ec2 describe-volumes \
    --filters "Name=tag:Deployment,Values=${deployment_id}" \
      "Name=tag:Name,Values=${deployment_id}-data" \
      "Name=attachment.instance-id,Values=${instance_id}" \
    --output json)"; then
    die "unable to discover reviewed data volume for ${deployment_id} on ${instance_id}"
  fi
  if ! volume_id="$(jq -er --arg instance_id "${instance_id}" '
    if type == "object"
      and (.Volumes | type == "array")
      and (.Volumes | length == 1)
      and (.Volumes[0] | type == "object")
      and (.Volumes[0].VolumeId | type == "string")
      and (.Volumes[0].VolumeId | test("^vol-[a-f0-9]{8,17}$"))
      and (.Volumes[0].Attachments | type == "array")
      and (.Volumes[0].Attachments | length == 1)
      and (.Volumes[0].Attachments[0] | type == "object")
      and (.Volumes[0].Attachments[0].InstanceId == $instance_id)
      and (.Volumes[0].Attachments[0].State == "attached")
    then .Volumes[0].VolumeId
    else error("expected exactly one valid reviewed data volume") end
  ' <<<"${response}")"; then
    die "expected exactly one valid reviewed data volume for ${deployment_id} on ${instance_id}"
  fi
  printf '%s\n' "${volume_id}"
}

instance_state() {
  local instance_id="$1"
  aws --region "${AWS_REGION}" ec2 describe-instances --instance-ids "${instance_id}" \
    --query 'Reservations[0].Instances[0].State.Name' --output text
}

ssm_ping_status() {
  local instance_id="$1" status
  status="$(aws --region "${AWS_REGION}" ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${instance_id}" \
    --query 'InstanceInformationList[0].PingStatus' --output text)"
  [[ "${status}" != "None" && -n "${status}" ]] || status="unknown"
  printf '%s\n' "${status}"
}

wait_for_ssm() {
  local instance_id="$1" timeout_seconds="${2:-300}" started now
  started="$(date +%s)"
  while true; do
    if [[ "$(ssm_ping_status "${instance_id}")" == "Online" ]]; then
      return 0
    fi
    now="$(date +%s)"
    (( now - started < timeout_seconds )) || die "timed out after ${timeout_seconds}s waiting for ${instance_id} to become SSM Online"
    sleep 10
  done
}

confirm_exact() {
  local prompt="$1" expected="$2" response
  read -r -p "${prompt} Type ${expected} to continue: " response
  [[ "${response}" == "${expected}" ]] || die "confirmation did not match; no changes applied"
}

prepare_host_backend() {
  local deployment_id="$1" work_dir backend_file
  work_dir="$(operator_dir "${deployment_id}")"
  mkdir -p -- "${work_dir}/tofu-data-host"
  backend_file="${work_dir}/backend.hcl"
  write_backend_config "${deployment_id}" "${backend_file}"
  TF_DATA_DIR="${work_dir}/tofu-data-host" tofu -chdir="${HOST_ROOT}" init \
    -reconfigure -input=false -backend-config="${backend_file}"
}

plan_show_confirm_apply() {
  local deployment_id="$1" root="$2" data_dir="$3" plan_file="$4" action="$5" apply_state_file="$6"
  local -a apply_options=()
  shift 6
  if [[ -n "${apply_state_file}" ]]; then
    apply_options+=("-state=${apply_state_file}")
  fi
  TF_DATA_DIR="${data_dir}" tofu -chdir="${root}" plan -input=false -out="${plan_file}" "$@"
  TF_DATA_DIR="${data_dir}" tofu -chdir="${root}" show "${plan_file}"
  confirm_exact "Approve ${action} for ${deployment_id}?" "${deployment_id}"
  TF_DATA_DIR="${data_dir}" tofu -chdir="${root}" apply -input=false "${apply_options[@]}" "${plan_file}"
}

send_ssm_command() {
  local instance_id="$1" comment="$2" parameters
  shift 2
  parameters="$(jq -cn --args '{commands: $ARGS.positional}' -- "$@")"
  aws --region "${AWS_REGION}" ssm send-command --instance-ids "${instance_id}" \
    --document-name AWS-RunShellScript --comment "${comment}" \
    --parameters "${parameters}" \
    --query 'Command.CommandId' --output text
}

ssm_poll_now() {
  date +%s
}

ssm_poll_sleep() {
  sleep "$1"
}

print_ssm_invocation() {
  local invocation="$1"
  jq -r '"Status: \(.Status)\nStandardOutput: |\n  \(.StandardOutputContent | gsub("\n"; "\n  "))\nStandardError: |\n  \(.StandardErrorContent | gsub("\n"; "\n  "))"' \
    <<<"${invocation}"
}

wait_and_print_ssm_command() {
  local command_id="$1" instance_id="$2" deadline_seconds="${3:-600}" poll_interval="${4:-5}"
  local started now invocation status aws_status aws_diagnostics error_file
  [[ "${deadline_seconds}" =~ ^[0-9]+$ && "${poll_interval}" =~ ^[0-9]+$ ]] || \
    die "SSM polling deadline and interval must be nonnegative integers"
  started="$(ssm_poll_now)"

  while true; do
    error_file="$(mktemp)" || return $?
    if invocation="$(aws --region "${AWS_REGION}" ssm get-command-invocation \
      --command-id "${command_id}" --instance-id "${instance_id}" --output json 2>"${error_file}")"; then
      rm -f -- "${error_file}"
    else
      aws_status=$?
      aws_diagnostics="$(<"${error_file}")"
      rm -f -- "${error_file}"
      if [[ "${aws_diagnostics}" =~ (^|[^[:alnum:]_])InvocationDoesNotExist([^[:alnum:]_]|$) ]]; then
        now="$(ssm_poll_now)"
        if (( now - started >= deadline_seconds )); then
          echo "Error: local deadline expired while SSM command ${command_id} on instance ${instance_id} was not yet visible; the command may still be pending or continuing remotely." >&2
          echo "Follow up with: aws --region ${AWS_REGION} ssm get-command-invocation --command-id ${command_id} --instance-id ${instance_id}" >&2
          return 124
        fi
        ssm_poll_sleep "${poll_interval}"
        continue
      fi
      [[ -z "${aws_diagnostics}" ]] || printf '%s\n' "${aws_diagnostics}" >&2
      return "${aws_status}"
    fi
    if ! status="$(jq -er '
      if type == "object"
        and (.Status | type == "string")
        and (.Status | length > 0)
        and (.StandardOutputContent | type == "string")
        and (.StandardErrorContent | type == "string")
      then .Status else error("malformed SSM invocation response") end
    ' <<<"${invocation}")"; then
      echo "Error: malformed SSM invocation response for command ${command_id} on instance ${instance_id}" >&2
      return 1
    fi

    case "${status}" in
      Success)
        print_ssm_invocation "${invocation}"
        return 0
        ;;
      Failed|TimedOut|Cancelled|Undeliverable|Terminated)
        print_ssm_invocation "${invocation}"
        echo "Error: SSM command ${command_id} on instance ${instance_id} reached terminal status ${status}." >&2
        return 1
        ;;
      Pending|InProgress|Delayed|Cancelling)
        now="$(ssm_poll_now)"
        if (( now - started >= deadline_seconds )); then
          print_ssm_invocation "${invocation}"
          echo "Error: local deadline expired while SSM command ${command_id} on instance ${instance_id} was ${status}; remote work may still be continuing remotely." >&2
          echo "Follow up with: aws --region ${AWS_REGION} ssm get-command-invocation --command-id ${command_id} --instance-id ${instance_id}" >&2
          return 124
        fi
        ssm_poll_sleep "${poll_interval}"
        ;;
      *)
        print_ssm_invocation "${invocation}"
        echo "Error: unknown SSM status ${status} for command ${command_id} on instance ${instance_id}; failing closed." >&2
        return 1
        ;;
    esac
  done
}

discover_deployment_ids() {
  local prefix bucket_names bucket_ids instance_tags instance_ids
  prefix="$(account_id)-${AWS_REGION}-hms-"
  bucket_names="$(aws --region "${AWS_REGION}" s3api list-buckets \
    --query "Buckets[?starts_with(Name, \`${prefix}\`)].Name" --output text)" || return
  bucket_ids="$(tr '\t' '\n' <<<"${bucket_names}" | \
    sed -nE "s/^${prefix}(hms-[a-f0-9]{12})-tofu-state$/\1/p")"
  instance_tags="$(aws --region "${AWS_REGION}" ec2 describe-instances \
    --filters 'Name=tag-key,Values=Deployment' \
    --query 'Reservations[].Instances[].Tags[?Key==`Deployment`].Value' --output text)" || return
  instance_ids="$(tr '\t' '\n' <<<"${instance_tags}" | sed -nE '/^hms-[a-f0-9]{12}$/p')"
  printf '%s\n%s\n' "${bucket_ids}" "${instance_ids}" | sed '/^$/d' | sort -u
}

empty_versioned_bucket() {
  local bucket="$1" objects
  while true; do
    objects="$(aws --region "${AWS_REGION}" s3api list-object-versions --bucket "${bucket}" \
      --output json | jq -c '[.Versions[]?, .DeleteMarkers[]?] | map({Key: .Key, VersionId: .VersionId})')"
    [[ "${objects}" != "[]" ]] || break
    aws --region "${AWS_REGION}" s3api delete-objects --bucket "${bucket}" \
      --delete "$(jq -cn --argjson objects "${objects}" '{Objects: $objects, Quiet: true}')" >/dev/null
  done
}
