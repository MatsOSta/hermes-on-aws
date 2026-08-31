#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: ./hermes.sh <command> [deployment-id]

Commands:
  help                  Print this usage
  id                    Generate a new hms-[a-f0-9]{12} deployment ID
  deploy <id>           Provision state foundation if needed, then host
  teardown <id>         Destroy the host only
  purge <id>            Destroy the host and state foundation
  install <id>          Install Docker and Hermes through SSM
  start <id>            Start a stopped instance
  stop <id>             Stop a running instance
  ssm <id>              Open an interactive SSM session
  status [id]           Show one or all deployment statuses
  list                  List discovered deployments
  logs <id>             Follow Hermes gateway logs through SSM
EOF
}

command_name="${1:-help}"
case "${command_name}" in
  help|-h|--help)
    usage
    ;;
  id)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    printf 'hms-%s\n' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
    ;;
  deploy|teardown|purge|install|start|stop|ssm|logs)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    exec "${REPO_ROOT}/scripts/${command_name}.sh" "$2"
    ;;
  status)
    [[ $# -le 2 ]] || { usage >&2; exit 2; }
    exec "${REPO_ROOT}/scripts/status.sh" "${2:-}"
    ;;
  list)
    [[ $# -eq 1 ]] || { usage >&2; exit 2; }
    exec "${REPO_ROOT}/scripts/list.sh"
    ;;
  *)
    echo "Unknown command: ${command_name}" >&2
    usage >&2
    exit 2
    ;;
esac
