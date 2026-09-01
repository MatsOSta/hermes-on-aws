#!/usr/bin/env bash

set -euo pipefail

[[ "$*" == *' ssm get-command-invocation '* ]] || { echo "unexpected aws invocation: $*" >&2; exit 90; }
[[ "$*" == *'--command-id cmd-123'* && "$*" == *'--instance-id i-abc'* ]] || exit 91
[[ "$*" == *'--output json'* ]] || { echo 'expected one JSON request' >&2; exit 92; }
if [[ -n "${MOCK_SSM_CALLS_FILE:-}" ]]; then
  printf 'get-command-invocation\n' >>"${MOCK_SSM_CALLS_FILE}"
fi
status="$(head -n 1 "${MOCK_SSM_STATUS_FILE}")"
tail -n +2 "${MOCK_SSM_STATUS_FILE}" >"${MOCK_SSM_STATUS_FILE}.next"
mv "${MOCK_SSM_STATUS_FILE}.next" "${MOCK_SSM_STATUS_FILE}"
case "${status}" in
  __INVOCATION_NOT_VISIBLE__)
    echo 'An error occurred (InvocationDoesNotExist) when calling the GetCommandInvocation operation: Command ID cmd-123 has not become visible' >&2
    exit 254
    ;;
  __API_ERROR__) echo 'mock API failure' >&2; exit 73 ;;
  __MALFORMED__) printf '{bad json\n'; exit 0 ;;
  __EMPTY__) status='' ;;
  '') status='InProgress' ;;
esac
printf '{"Status":"%s","StandardOutputContent":"stdout-%s","StandardErrorContent":"stderr-%s"}\n' \
  "${status}" "${status}" "${status}"
