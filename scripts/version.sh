#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly RUNTIME_HELPER="${REPO_ROOT}/scripts/support/run-hermes-gateway.sh"

die() {
  echo "Error: $*" >&2
  exit 1
}

command -v git >/dev/null 2>&1 || die 'version requires git'
command -v sed >/dev/null 2>&1 || die 'version requires sed'
[[ -f "${RUNTIME_HELPER}" && ! -L "${RUNTIME_HELPER}" ]] || \
  die 'unable to determine one digest-pinned Hermes runtime image'

git_commit="$(git -C "${REPO_ROOT}" rev-parse --verify HEAD 2>/dev/null)" || \
  die 'unable to determine the repository commit'
[[ "${git_commit}" =~ ^[0-9a-f]{40}$ ]] || die 'repository commit is not a full Git object ID'

git_status="$(git -C "${REPO_ROOT}" status --porcelain=v1 --untracked-files=no 2>/dev/null)" || \
  die 'unable to inspect tracked Git state'
git_tracked_dirty=false
if [[ -n "${git_status}" ]]; then
  git_tracked_dirty=true
fi

hermes_image="$(sed -n "s/^readonly HERMES_IMAGE='\([^']*\)'$/\1/p" "${RUNTIME_HELPER}")" || \
  die 'unable to determine one digest-pinned Hermes runtime image'
if [[ -z "${hermes_image}" || "${hermes_image}" == *$'\n'* || \
      ! "${hermes_image}" =~ ^[^[:space:]@]+@sha256:[0-9a-f]{64}$ ]]; then
  die 'unable to determine one digest-pinned Hermes runtime image'
fi

printf 'git_commit=%s\n' "${git_commit}"
printf 'git_tracked_dirty=%s\n' "${git_tracked_dirty}"
printf 'hermes_image=%s\n' "${hermes_image}"
