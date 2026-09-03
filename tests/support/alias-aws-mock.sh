#!/usr/bin/env bash

set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_ALIAS_AWS_CALLS}"
[[ "$*" != *smoketest* ]] || { echo 'alias leaked to AWS' >&2; exit 90; }
case " $* " in
  *' sts get-caller-identity '*) printf '450895596262\n' ;;
  *' s3api list-buckets '*) printf '450895596262-eu-north-1-hms-abcdef123456-tofu-state\n' ;;
  *' ec2 describe-instances '*'Name=tag-key,Values=Deployment'*) printf 'hms-abcdef123456\n' ;;
  *' ec2 describe-instances '*'Name=tag:Deployment,Values=hms-abcdef123456'*) printf 'i-abcdef1234567890\n' ;;
  *' ec2 describe-instances --instance-ids i-abcdef1234567890 '*) printf 'running\n' ;;
  *' ssm describe-instance-information '*) printf 'Online\n' ;;
  *' ssm send-command '*) printf 'cmd-status\n' ;;
  *' ssm wait command-executed '*) : ;;
  *' ssm get-command-invocation '*) printf 'docker=running\ncontainer=running\n' ;;
  *) echo "unexpected aws invocation: $*" >&2; exit 91 ;;
esac
