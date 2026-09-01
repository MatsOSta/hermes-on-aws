#!/usr/bin/env bash

set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_VOLUME_CALLS}"
[[ "$*" == *'ec2 describe-volumes'* ]] || exit 91
case "${MOCK_VOLUME_MODE}" in
  valid) printf '{"Volumes":[{"VolumeId":"vol-0abc1234def567890","Attachments":[{"InstanceId":"i-0123456789abcdef0","State":"attached"}]}]}\n' ;;
  too-short) printf '{"Volumes":[{"VolumeId":"vol-0123456","Attachments":[{"InstanceId":"i-0123456789abcdef0","State":"attached"}]}]}\n' ;;
  too-long) printf '{"Volumes":[{"VolumeId":"vol-0123456789abcdef01","Attachments":[{"InstanceId":"i-0123456789abcdef0","State":"attached"}]}]}\n' ;;
  zero) printf '{"Volumes":[]}\n' ;;
  multiple) printf '{"Volumes":[{"VolumeId":"vol-01"},{"VolumeId":"vol-02"}]}\n' ;;
  malformed-id) printf '{"Volumes":[{"VolumeId":"snap-0123"}]}\n' ;;
  malformed-json) printf '{not-json\n' ;;
  malformed-attachment) printf '{"Volumes":[{"VolumeId":"vol-0abc1234def567890","Attachments":"bad"}]}\n' ;;
  wrong-instance) printf '{"Volumes":[{"VolumeId":"vol-0abc1234def567890","Attachments":[{"InstanceId":"i-deadbeef","State":"attached"}]}]}\n' ;;
  not-attached) printf '{"Volumes":[{"VolumeId":"vol-0abc1234def567890","Attachments":[{"InstanceId":"i-0123456789abcdef0","State":"attaching"}]}]}\n' ;;
  multiple-attachments) printf '{"Volumes":[{"VolumeId":"vol-0abc1234def567890","Attachments":[{"InstanceId":"i-0123456789abcdef0","State":"attached"},{"InstanceId":"i-deadbeef","State":"attached"}]}]}\n' ;;
  api-error) echo 'AccessDenied: describe-volumes denied' >&2; exit 73 ;;
  *) exit 92 ;;
esac
