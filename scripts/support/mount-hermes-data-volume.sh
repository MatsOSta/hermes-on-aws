#!/usr/bin/env bash

set -euo pipefail

readonly HERMES_MOUNTPOINT='/var/lib/hermes'
readonly FSTAB='/etc/fstab'
expected_volume_id="${1:-}"

die() {
  echo "Error: $*" >&2
  exit 1
}

[[ "$(id -u)" == 0 ]] || die 'Hermes data-volume mount helper must be run as root.'
[[ "${expected_volume_id}" =~ ^vol-[a-f0-9]{8,17}$ ]] || die 'expected volume ID must match ^vol-[a-f0-9]{8,17}$'
(( $# == 1 )) || die 'mount helper accepts exactly one expected volume ID'

normalized_expected="${expected_volume_id//-/}"
matches=()
match_types=()
lsblk_output="$(lsblk -nrpo NAME,TYPE,SERIAL)" || die 'unable to enumerate block devices'
while read -r device_name device_type device_serial extra; do
  [[ -n "${device_name:-}" ]] || continue
  [[ -z "${extra:-}" ]] || die 'lsblk returned an unexpected device record'
  normalized_serial="${device_serial//-/}"
  if [[ "${normalized_serial}" == "${normalized_expected}" ]]; then
    matches+=("${device_name}")
    match_types+=("${device_type}")
  fi
done <<<"${lsblk_output}"

(( ${#matches[@]} == 1 )) || die "expected exactly one block device with serial ${expected_volume_id}; found ${#matches[@]}"
[[ "${match_types[0]}" == disk ]] || die "expected volume serial resolved to a child or non-whole device: ${matches[0]} (${match_types[0]})"
device="${matches[0]}"

verify_mount() {
  local record source filesystem options canonical_source canonical_device
  record="$(findmnt -rn -M "${HERMES_MOUNTPOINT}" -o SOURCE,FSTYPE,OPTIONS)" || return 1
  read -r source filesystem options extra <<<"${record}"
  [[ -n "${source:-}" && -n "${filesystem:-}" && -n "${options:-}" && -z "${extra:-}" ]] || return 1
  canonical_source="$(readlink -f -- "${source}")" || return 1
  canonical_device="$(readlink -f -- "${device}")" || return 1
  [[ "${canonical_source}" == "${canonical_device}" ]] || return 1
  [[ "${filesystem}" == xfs ]] || return 1
  [[ ",${options}," == *,nodev,* && ",${options}," == *,nosuid,* ]] || return 1
  [[ ",${options}," != *,dev,* && ",${options}," != *,suid,* ]] || return 1
}

already_mounted=false
if findmnt -rn -M "${HERMES_MOUNTPOINT}" -o SOURCE,FSTYPE,OPTIONS >/dev/null 2>&1; then
  already_mounted=true
  verify_mount || die "${HERMES_MOUNTPOINT} is not the expected secure XFS mount from ${device}"
fi

if [[ "${already_mounted}" == false ]]; then
  [[ "$(stat -c '%F' -- "${HERMES_MOUNTPOINT}" 2>/dev/null || true)" == directory ]] || die "${HERMES_MOUNTPOINT} must be a directory"
  existing_entry="$(find "${HERMES_MOUNTPOINT}" -mindepth 1 -maxdepth 1 -print -quit)" || die "unable to check whether ${HERMES_MOUNTPOINT} is empty"
  [[ -z "${existing_entry}" ]] || die "refusing to hide pre-existing data in ${HERMES_MOUNTPOINT}"

  if other_target="$(findmnt -rn -S "${device}" -o TARGET 2>/dev/null)"; then
    die "expected device ${device} is already mounted at ${other_target}"
  fi

fi

signatures=()
signature_output="$(wipefs -n --noheadings --output TYPE -- "${device}")" || die "unable to inspect all signatures on ${device}"
while read -r signature extra; do
  [[ -n "${signature:-}" ]] || continue
  [[ -z "${extra:-}" ]] || die "unexpected signature output for ${device}"
  signatures+=("${signature}")
done <<<"${signature_output}"
case "${#signatures[@]}:${signatures[0]:-}" in
  0:) filesystem_uuid='' ;;
  1:xfs)
    filesystem_type="$(blkid -s TYPE -o value -- "${device}")" || die "unable to read filesystem type from ${device}"
    [[ "${filesystem_type}" == xfs ]] || die "expected XFS on ${device}, found ${filesystem_type:-none}"
    filesystem_uuid="$(blkid -s UUID -o value -- "${device}")" || die "unable to read filesystem UUID from ${device}"
    [[ "${filesystem_uuid}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid filesystem UUID on ${device}"
    ;;
  1:*) die "refusing non-XFS signature ${signatures[0]} on ${device}" ;;
  *) die "refusing multiple filesystem signatures on ${device}" ;;
esac

fstab_state="$(awk -v mountpoint="${HERMES_MOUNTPOINT}" -v expected="${filesystem_uuid:+UUID=${filesystem_uuid}}" '
  /^[[:space:]]*#/ || NF == 0 { next }
  $2 == mountpoint {
    count++
    if (expected != "" && NF == 6 && $1 == expected && $3 == "xfs" && $4 == "defaults,nodev,nosuid" && $5 == "0" && $6 == "2") valid++
  }
  END {
    if (count == 0) print "absent"
    else if (count == 1 && valid == 1) print "valid"
    else if (count > 1) print "duplicate"
    else print "conflict"
  }
' "${FSTAB}")" || die "unable to validate ${FSTAB}"
case "${fstab_state}" in
  absent)
    [[ "${already_mounted}" == false ]] || die "mounted Hermes data volume has no persistent fstab entry"
    ;;
  valid) ;;
  duplicate) die "duplicate ${HERMES_MOUNTPOINT} entries in ${FSTAB}" ;;
  conflict) die "conflicting ${HERMES_MOUNTPOINT} entry in ${FSTAB}" ;;
  *) die "invalid fstab validation result: ${fstab_state}" ;;
esac

if [[ -z "${filesystem_uuid}" ]]; then
  [[ "${already_mounted}" == false ]] || die 'mounted expected device has no filesystem signature'
  mkfs.xfs "${device}"
  filesystem_type="$(blkid -s TYPE -o value -- "${device}")" || die "unable to read filesystem type from ${device}"
  [[ "${filesystem_type}" == xfs ]] || die "expected XFS on ${device}, found ${filesystem_type:-none}"
  filesystem_uuid="$(blkid -s UUID -o value -- "${device}")" || die "unable to read filesystem UUID from ${device}"
  [[ "${filesystem_uuid}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid filesystem UUID on ${device}"
fi

if [[ "${fstab_state}" == absent ]]; then
  printf 'UUID=%s %s xfs defaults,nodev,nosuid 0 2\n' "${filesystem_uuid}" "${HERMES_MOUNTPOINT}" | tee -a "${FSTAB}" >/dev/null
fi

if [[ "${already_mounted}" == false ]]; then
  mount "${HERMES_MOUNTPOINT}" || die "failed to mount ${HERMES_MOUNTPOINT}"
  verify_mount || die "mounted ${HERMES_MOUNTPOINT} failed source, filesystem, or option verification"
fi
chmod 0700 "${HERMES_MOUNTPOINT}"
echo "Hermes data volume ${expected_volume_id} is mounted securely at ${HERMES_MOUNTPOINT}."
