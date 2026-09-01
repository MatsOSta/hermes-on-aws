#!/usr/bin/env bash

set -u

args=" $* "

if [[ "${args}" == *' sts get-caller-identity '* ]]; then
  case "${MOCK_AWS_MODE:-}" in
    profile)
      [[ "${AWS_PROFILE:-}" == 'platform-lab-tofu' ]] || { echo 'wrong profile' >&2; exit 41; }
      for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN AWS_CREDENTIAL_EXPIRATION; do
        [[ -z "${!name:-}" ]] || { echo "stale credential remained: ${name}" >&2; exit 42; }
      done
      ;;
    expired)
      echo 'An error occurred (ExpiredToken) when calling GetCallerIdentity: token expired' >&2
      exit 43
      ;;
  esac
  if [[ "${MOCK_AWS_MODE:-}" == 'wrong-account' ]]; then
    echo '999999999999'
  else
    echo '450895596262'
  fi
  exit 0
fi

if [[ "${args}" == *' s3api list-buckets '* ]]; then
  echo 'AccessDenied: cannot list buckets' >&2
  exit 44
fi

if [[ "${args}" == *' s3api head-bucket '* ]]; then
  case "${MOCK_AWS_MODE:-}" in
    missing-bucket)
      echo 'An error occurred (404) when calling the HeadBucket operation: Not Found' >&2
      exit 45
      ;;
    bucket-denied)
      echo 'An error occurred (403) when calling the HeadBucket operation: AccessDenied: cannot read bucket' >&2
      exit 46
      ;;
  esac
fi

echo "unexpected aws invocation:${args}" >&2
exit 47
