#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_INSTALL_CALLS}"
args=" $* "
if [[ "${args}" == *' sts get-caller-identity '* ]]; then echo 450895596262; exit 0; fi
if [[ "${args}" == *' ec2 describe-instances '* ]]; then echo i-abc123; exit 0; fi
if [[ "${args}" == *' ec2 describe-volumes '* ]]; then
  case "${MOCK_INSTALL_MODE}" in
    volume-zero) printf '{"Volumes":[]}\n' ;;
    volume-multiple) printf '{"Volumes":[{"VolumeId":"vol-01"},{"VolumeId":"vol-02"}]}\n' ;;
    volume-malformed) printf '{"Volumes":[{"VolumeId":"bad"}]}\n' ;;
    volume-too-short) printf '{"Volumes":[{"VolumeId":"vol-0123456","Attachments":[{"InstanceId":"i-abc123","State":"attached"}]}]}\n' ;;
    volume-too-long) printf '{"Volumes":[{"VolumeId":"vol-0123456789abcdef01","Attachments":[{"InstanceId":"i-abc123","State":"attached"}]}]}\n' ;;
    volume-api-error) echo denied >&2; exit 73 ;;
    *) printf '{"Volumes":[{"VolumeId":"vol-0abc1234def567890","Attachments":[{"InstanceId":"i-abc123","State":"attached"}]}]}\n' ;;
  esac
  exit 0
fi
if [[ "${args}" == *' ssm describe-instance-information '* ]]; then echo Online; exit 0; fi
if [[ "${args}" == *' ssm send-command '* ]]; then
  parameters=''
  while (( $# > 0 )); do [[ "$1" == --parameters ]] && { parameters="$2"; break; }; shift; done
  payload_command="$(jq -er '.commands[] | select(contains("base64 -d"))' <<<"${parameters}")"
  payload="$(sed -nE "s/^printf '%s' '([^']+)'.*$/\1/p" <<<"${payload_command}")"
  decoded="$(mktemp)"; trap 'rm -f -- "${decoded}"' EXIT
  base64 -d <<<"${payload}" >"${decoded}"
  cmp -s "${MOCK_INSTALL_EXPECTED_HELPER}" "${decoded}" || exit 81
  echo DELIVERED_REVIEWED_MOUNT_HELPER >>"${MOCK_INSTALL_CALLS}"
  commands="$(jq -r '.commands[]' <<<"${parameters}")"
  [[ "${commands}" == *'mktemp /tmp/hermes-mount-helper.XXXXXX'* ]] || exit 84
  [[ "${commands}" == *"trap 'rm -f -- \"\${mount_helper}\"' EXIT"* ]] || exit 85
  [[ "${commands}" == *'chmod 0700 "${mount_helper}"'* ]] || exit 86
  [[ "${commands}" == *'"${mount_helper}" '\''vol-0abc1234def567890'\'''* ]] || exit 87
  [[ "${commands}" != *'/usr/local/sbin/mount-hermes-data-volume'* ]] || exit 88
  [[ "${commands}" == *'dnf install -y docker xfsprogs'* ]] || exit 82
  echo 'PACKAGES docker xfsprogs' >>"${MOCK_INSTALL_CALLS}"
  mount_line="$(grep -n 'vol-0abc1234def567890' <<<"${commands}" | tail -1 | cut -d: -f1)"
  docker_start_line="$(grep -n 'systemctl enable --now docker' <<<"${commands}" | cut -d: -f1)"
  remove_line="$(grep -n 'rm -f -- "${mount_helper}"' <<<"${commands}" | tail -1 | cut -d: -f1)"
  pull_line="$(grep -n 'docker pull' <<<"${commands}" | cut -d: -f1)"
  (( mount_line < docker_start_line && docker_start_line < pull_line && mount_line < remove_line && remove_line < pull_line )) || exit 83
  {
    echo 'MOUNT_HELPER vol-0abc1234def567890'
    echo DOCKER_START
    echo DOCKER_PULL
  } >>"${MOCK_INSTALL_CALLS}"
  echo cmd-install
  exit 0
fi
if [[ "${args}" == *' ssm get-command-invocation '* ]]; then
  if [[ "${MOCK_INSTALL_MODE}" == terminal-failure ]]; then
    printf '{"Status":"Failed","StandardOutputContent":"","StandardErrorContent":"mount failed"}\n'
  else
    printf '{"Status":"Success","StandardOutputContent":"mounted","StandardErrorContent":""}\n'
  fi
  exit 0
fi
exit 90
