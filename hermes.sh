#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/lib.sh"

usage() {
  cat <<'EOF'
Usage: ./hermes.sh <command> [deployment-id] [options]

Commands:
  help                  Print this usage
  id [--alias <alias>]  Generate an ID; optionally register its local alias
  alias set <alias> <id>
  alias list
  alias rename <old> <new>
  alias remove <alias>  Manage operator-local deployment aliases
  deploy <id>           Provision state foundation if needed, then host
  teardown <id>         Destroy the host only
  purge <id>            Destroy the host and state foundation
  install <id>          Install Docker and pull Hermes image (step 1/3)
  start-gateway <id> [--recreate]
                        Safely start/retain the gateway; explicitly replace with --recreate
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
    [[ $# -eq 1 || ( $# -eq 3 && "$2" == '--alias' ) ]] || { usage >&2; exit 2; }
    generated_id="hms-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
    [[ $# -eq 1 ]] || alias_set "$3" "${generated_id}"
    printf '%s\n' "${generated_id}"
    ;;
  alias)
    subcommand="${2:-}"
    case "${subcommand}" in
      set) [[ $# -eq 4 ]] || { usage >&2; exit 2; }; alias_set "$3" "$4" ;;
      list) [[ $# -eq 2 ]] || { usage >&2; exit 2; }; alias_list ;;
      rename) [[ $# -eq 4 ]] || { usage >&2; exit 2; }; alias_rename "$3" "$4" ;;
      remove) [[ $# -eq 3 ]] || { usage >&2; exit 2; }; alias_remove "$3" ;;
      *) usage >&2; exit 2 ;;
    esac
    ;;
  start-gateway)
    [[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 2; }
    [[ $# -eq 2 || "$3" == '--recreate' ]] || { usage >&2; exit 2; }
    deployment_id="$(resolve_deployment_target "$2")"
    exec "${REPO_ROOT}/scripts/start-gateway.sh" "${deployment_id}" "${3:-}"
    ;;
  deploy|teardown|purge|install|start|stop|ssm|logs)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    deployment_id="$(resolve_deployment_target "$2")"
    exec "${REPO_ROOT}/scripts/${command_name}.sh" "${deployment_id}"
    ;;
  status)
    [[ $# -le 2 ]] || { usage >&2; exit 2; }
    if [[ $# -eq 2 ]]; then
      deployment_id="$(resolve_deployment_target "$2")"
      deployment_alias=''
      if [[ ! "$2" =~ ^hms-[a-f0-9]{12}$ ]]; then
        deployment_alias="$2"
      fi
      HERMES_LOCAL_DEPLOYMENT_ALIAS="${deployment_alias}" \
        exec "${REPO_ROOT}/scripts/status.sh" "${deployment_id}"
    fi
    exec "${REPO_ROOT}/scripts/status.sh" ''
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
