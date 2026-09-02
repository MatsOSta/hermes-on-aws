#!/usr/bin/env bash

set -euo pipefail

tool="$(basename -- "$0")"
printf '%s %s\n' "${tool}" "$*" >>"${MOCK_RAW_LOG:?}"

if [[ "${tool}" == tofu ]]; then
  exit 0
fi

case " $* " in
  *' sts get-caller-identity '*) printf '450895596262\n' ;;
  *' s3api head-bucket '*) printf 'Not Found\n' >&2; exit 1 ;;
  *' kms describe-key '*) printf 'arn:aws:kms:eu-north-1:450895596262:key/mock\n' ;;
  *' ec2 describe-instances '*) printf 'i-abcdef1234567890\n' ;;
  *' ssm describe-instance-information '*) printf 'Online\n' ;;
  *' s3api list-object-versions '*) printf '{"Versions":[]}\n' ;;
  *) printf 'unexpected aws invocation: %s\n' "$*" >&2; exit 70 ;;
esac
