#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly REPO_ROOT
failed=0

git_mode() {
  git -C "${REPO_ROOT}" ls-files -s -- "$1" | awk 'NR == 1 { print $1 }'
}

while IFS= read -r target; do
  mode="$(git_mode "${target}")"
  if [[ -z "${mode}" ]]; then
    printf 'missing tracked executable dispatch target: %s\n' "${target}" >&2
    failed=1
  elif [[ "${mode}" != 100755 ]]; then
    printf 'dispatch target is not mode 100755: %s\n' "${target}" >&2
    failed=1
  fi
done < <(
  awk '
    /^  [^[:space:]].*\)$/ { selector = $0 }
    /exec "\$\{REPO_ROOT\}\/scripts\/\$\{command_name\}\.sh"/ {
      sub(/^  /, "", selector)
      sub(/\)$/, "", selector)
      command_count = split(selector, commands, /\|/)
      for (command_index = 1; command_index <= command_count; command_index++) {
        print "scripts/" commands[command_index] ".sh"
      }
    }
    /exec "\$\{REPO_ROOT\}\/scripts\/[[:alnum:]_-]+\.sh"/ {
      target = $0
      sub(/^.*exec "\$\{REPO_ROOT\}\//, "", target)
      sub(/".*$/, "", target)
      print target
    }
  ' "${REPO_ROOT}/hermes.sh" |
    LC_ALL=C sort -u
)

while read -r mode _object _stage path; do
  if [[ "${mode}" != 100755 ]]; then
    printf 'tracked shell entry point is not mode 100755: %s\n' "${path}" >&2
    failed=1
  fi
done < <(
  git -C "${REPO_ROOT}" ls-files -s -- \
    hermes.sh 'scripts/*.sh' 'tests/*.sh' 'tests/support/*.sh' 'infrastructure/aws/*.sh'
)

exit "${failed}"
