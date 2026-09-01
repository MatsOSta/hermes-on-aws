#!/usr/bin/env bash

set -u
tool="${0##*/}"
printf '%s %s\n' "${tool}" "$*" >>"${MOCK_MOUNT_CALLS}"
mode="${MOCK_MOUNT_MODE}"
case "${tool}" in
  id) [[ "${mode}" == non-root ]] && printf '1000\n' || printf '0\n' ;;
  stat) printf 'directory\n' ;;
  find)
    if [[ "${mode}" == nonempty ]]; then
      printf '/var/lib/hermes/secret\n'
    else
      :
    fi ;;
  lsblk)
    case "${mode}" in
      missing-serial) printf '/dev/nvme0n1 disk vol-root\n' ;;
      ambiguous-serial) printf '/dev/nvme1n1 disk vol0abc1234def567890\n/dev/nvme2n1 disk vol-0abc1234def567890\n' ;;
      child-device) printf '/dev/nvme1n1p1 part vol0abc1234def567890\n' ;;
      xfs-discovered|none-discovered) printf '/dev/nvme7n1 disk vol0abc1234def567890\n' ;;
      *) printf '/dev/nvme1n1 disk vol0abc1234def567890\n' ;;
    esac ;;
  wipefs)
    case "${mode}" in
      none|none-discovered|mkfs-fail|blank-conflicting-fstab|blank-duplicate-fstab) : ;;
      ext4) printf 'ext4\n' ;;
      multiple-signatures) printf 'xfs\next4\n' ;;
      *) printf 'xfs\n' ;;
    esac ;;
  blkid)
    [[ "$*" == *'-s TYPE'* ]] && printf 'xfs\n' || printf '11111111-2222-3333-4444-555555555555\n' ;;
  awk)
    [[ "$*" == *'mountpoint=/var/lib/hermes'* && "$*" == *'/etc/fstab'* ]] || exit 97
    case "${mode}" in
      none|none-discovered|mkfs-fail|blank-conflicting-fstab|blank-duplicate-fstab)
        [[ "$*" != *'expected=UUID='* ]] || exit 97 ;;
      *) [[ "$*" == *'expected=UUID=11111111-2222-3333-4444-555555555555'* ]] || exit 97 ;;
    esac
    case "${mode}" in
      conflicting-fstab|blank-conflicting-fstab) printf 'conflict\n' ;;
      duplicate-fstab|blank-duplicate-fstab) printf 'duplicate\n' ;;
      mounted|overriding-options) printf 'valid\n' ;;
      *) printf 'absent\n' ;;
    esac ;;
  tee)
    IFS= read -r line
    [[ "${line}" == 'UUID=11111111-2222-3333-4444-555555555555 /var/lib/hermes xfs defaults,nodev,nosuid 0 2' ]] || exit 96
    printf 'FSTAB_LINE %s\n' "${line}" >>"${MOCK_MOUNT_CALLS}"
    ;;
  findmnt)
    if [[ "$*" == *' -S /dev/nvme1n1 '* || "$*" == *' -S /dev/nvme1n1' || "$*" == *' -S /dev/nvme7n1 '* || "$*" == *' -S /dev/nvme7n1' ]]; then
      [[ "${mode}" == expected-mounted-elsewhere ]] && printf '/srv/other\n' || exit 1
    elif [[ -e "${MOCK_MOUNT_STATE}" || "${mode}" == mounted || "${mode}" == wrong-source || "${mode}" == wrong-type || "${mode}" == wrong-options || "${mode}" == overriding-options ]]; then
      case "${mode}" in
        wrong-source) printf '/dev/nvme9n1 xfs rw,nodev,nosuid\n' ;;
        wrong-type) printf '/dev/nvme1n1 ext4 rw,nodev,nosuid\n' ;;
        wrong-options) printf '/dev/nvme1n1 xfs rw\n' ;;
        overriding-options) printf '/dev/nvme1n1 xfs rw,nodev,dev,nosuid,suid\n' ;;
        verify-failure) exit 1 ;;
        xfs-discovered|none-discovered) printf '/dev/nvme7n1 xfs rw,nodev,nosuid\n' ;;
        *) printf '/dev/nvme1n1 xfs rw,nodev,nosuid\n' ;;
      esac
    else
      exit 1
    fi ;;
  readlink)
    if [[ "${mode}" == wrong-source && "$*" == *nvme9n1* ]]; then
      printf '/dev/nvme9n1\n'
    elif [[ "${mode}" == xfs-discovered || "${mode}" == none-discovered ]]; then
      printf '/dev/nvme7n1\n'
    else
      printf '/dev/nvme1n1\n'
    fi ;;
  mount) [[ "${mode}" == mount-failure ]] && exit 1; : >"${MOCK_MOUNT_STATE}" ;;
  chmod) : ;;
  mkfs.xfs)
    if [[ "${mode}" == mkfs-fail ]]; then
      exit 1
    else
      :
    fi ;;
  *) exit 98 ;;
esac
