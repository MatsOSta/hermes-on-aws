#!/usr/bin/env bash

set -euo pipefail

MOCK_TOOL="${MOCK_TOOL:-$(basename -- "$0")}"
readonly MOCK_TOOL

printf '%s %s\n' "${MOCK_TOOL}" "$*" >>"${MOCK_RAW_LOG:?}"

case "${MOCK_TOOL:?}: $*" in
  'aws: --region eu-north-1 sts get-caller-identity --query Account --output text')
    printf '%s\n' "${MOCK_ACCOUNT_ID:-450895596262}"
    ;;
  aws:\ --region\ eu-north-1\ kms\ describe-key\ --key-id\ alias/*)
    printf 'arn:aws:kms:eu-north-1:450895596262:key/mock\n'
    ;;
  aws:\ --region\ eu-north-1\ s3api\ list-object-versions\ --bucket\ *)
    printf 'bucket-list\n' >>"${MOCK_LOG:?}"
    if [[ "${MOCK_FAIL_EVENT:-}" == 'malformed-bucket-list' ]]; then
      printf '[]\n'
    elif [[ ! -f "${MOCK_CASE_DIR:?}/bucket-listed" ]]; then
      : >"${MOCK_CASE_DIR}/bucket-listed"
      if [[ "${MOCK_FAIL_EVENT:-}" == 'oversized-bucket-delete' ]]; then
        jq -cn '[range(1001) | {Key:"state", VersionId:(. | tostring)}] | {Versions:.}'
      else
        printf '{"Versions":[{"Key":"state","VersionId":"one"}]}\n'
      fi
    else
      printf '{"Versions":[]}\n'
    fi
    ;;
  aws:\ --region\ eu-north-1\ s3api\ delete-objects\ --bucket\ *)
    printf 'bucket-delete\n' >>"${MOCK_LOG:?}"
    delete_payload="${*: -1}"
    if (( $(jq '.Objects | length' <<<"${delete_payload}") > 1000 )); then
      printf 'oversized-bucket-delete\n' >>"${MOCK_LOG:?}"
      exit 73
    elif [[ "${MOCK_FAIL_EVENT:-}" == 'malformed-bucket-delete' ]]; then
      printf '[]\n'
    elif [[ "${MOCK_FAIL_EVENT:-}" == 'bucket-delete-errors' ]]; then
      printf '{"Errors":[{"Key":"state","VersionId":"one","Code":"AccessDenied","Message":"denied"}]}\n'
    elif [[ "${MOCK_FAIL_EVENT:-}" == 'empty-bucket-delete-response' ]]; then
      :
    else
      printf '{"Deleted":[{"Key":"state","VersionId":"one"}]}\n'
    fi
    ;;
  tofu:*)
    operation=''
    case " $* " in
      *' init '*) operation=init ;;
      *' plan '*) operation=plan ;;
      *' show '*) operation=show ;;
      *' apply '*) operation=apply ;;
    esac
    case "$*" in
      *greenfield-state-purge*) root=state ;;
      *) root=host ;;
    esac
    event="${root}-${operation}"
    case "${event}: $*" in
      host-init:*'-chdir='*'/infrastructure/greenfield init -reconfigure -input=false -backend-config='*) ;;
      state-init:*'-chdir='*'/greenfield-state-purge init -backend=false -input=false') ;;
      host-plan:*'-chdir='*'/infrastructure/greenfield plan -destroy -input=false -out='*'host-'*'.tfplan -var=deployment_id='*) ;;
      host-plan:*'-chdir='*'/infrastructure/greenfield plan -input=false -out='*'host-'*'.tfplan -destroy -var=deployment_id='*) ;;
      state-plan:*'-chdir='*'/greenfield-state-purge plan -destroy -input=false -state='*'state-foundation.tfstate -out='*'state-foundation-destroy.tfplan -var=deployment_id='*) ;;
      host-show:*'-chdir='*'/infrastructure/greenfield show '*'/host-'*'.tfplan') ;;
      state-show:*'-chdir='*'/greenfield-state-purge show '*'/state-foundation-destroy.tfplan') ;;
      host-apply:*'-chdir='*'/infrastructure/greenfield apply -input=false '*'/host-'*'.tfplan') ;;
      state-apply:*'-chdir='*'/greenfield-state-purge apply -input=false -state='*'/state-foundation.tfstate '*'/state-foundation-destroy.tfplan') ;;
      *)
        printf 'unexpected tofu invocation: %s\n' "$*" >&2
        exit 71
        ;;
    esac
    printf '%s\n' "${event}" >>"${MOCK_LOG:?}"
    [[ "${MOCK_FAIL_EVENT:-}" != "${event}" ]] || exit 72
    ;;
  *)
    printf 'unexpected %s invocation: %s\n' "${MOCK_TOOL}" "$*" >&2
    exit 70
    ;;
esac
