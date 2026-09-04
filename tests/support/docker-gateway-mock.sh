#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_DOCKER_CALLS}"
image='nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e'
mode="${MOCK_DOCKER_MODE}"
state_file="${MOCK_DOCKER_CALLS}.state"
state="$(cat "${state_file}" 2>/dev/null || true)"

if [[ "$*" == 'info' ]]; then exit 0; fi
if [[ "$*" == 'logs --tail 50 hermes-gateway' ]]; then echo 'mock gateway logs'; exit 0; fi
if [[ "$*" == 'container inspect hermes-gateway' ]]; then
  [[ "${mode}" != absent || "${state}" == created ]] || exit 1
  exit 0
fi
if [[ "$1 $2 $3" == 'container inspect --format' ]]; then
  [[ "${5:-}" == hermes-gateway && $# -eq 5 ]] || { echo 'unexpected inspect target' >&2; exit 93; }
  format="$4"
  running=true
  [[ "${mode}" != matching-stopped || "${state}" == started ]] || running=false
  [[ "${mode}" != exit-after-start || -n "${state}" ]] || running=false
  [[ "${mode}" != exit-after-start || "${state}" != started ]] || running=false
  [[ "${mode}" != exit-after-run || "${state}" != created ]] || running=false
  cmd='["hermes","gateway","run"]' binds='["/var/lib/hermes:/opt/data"]' restart='unless-stopped'
  privileged=false caps=null ports='{}' publish=false network=bridge networks='bridge ' mounts=null volumes_from=null
  case "${mode}" in
    mismatch-image) image='wrong:image' ;;
    mismatch-command) cmd='["wrong"]' ;;
    mismatch-bind) binds='["/tmp:/opt/data"]' ;;
    mismatch-restart) restart='always' ;;
    mismatch-privileged) privileged=true ;;
    mismatch-capabilities) caps='["SYS_ADMIN"]' ;;
    mismatch-ports) ports='{"80/tcp":[{"HostPort":"80"}]}' ;;
    mismatch-publish-all) publish=true ;;
    mismatch-host-network) network=host ;;
    matching-tunnel-network) networks='bridge hermes-tunnel-net ' ;;
    mismatch-extra-network) networks='bridge hermes-tunnel-net unexpected-net ' ;;
    mismatch-extra-mount) mounts='[{"Type":"bind"}]' ;;
    mismatch-volumes-from) volumes_from='["other"]' ;;
  esac
  case "${format}" in
    '{{.Config.Image}}') printf '%s\n' "${image}" ;;
    '{{.HostConfig.Privileged}}') printf '%s\n' "${privileged}" ;;
    '{{.HostConfig.NetworkMode}}') printf '%s\n' "${network}" ;;
    '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}') printf '%s\n' "${networks}" ;;
    '{{.HostConfig.RestartPolicy.Name}}') printf '%s\n' "${restart}" ;;
    '{{json .HostConfig.Binds}}') printf '%s\n' "${binds}" ;;
    '{{json .HostConfig.Mounts}}') printf '%s\n' "${mounts}" ;;
    '{{json .HostConfig.VolumesFrom}}') printf '%s\n' "${volumes_from}" ;;
    '{{json .HostConfig.CapAdd}}') printf '%s\n' "${caps}" ;;
    '{{json .HostConfig.PortBindings}}') printf '%s\n' "${ports}" ;;
    '{{.HostConfig.PublishAllPorts}}') printf '%s\n' "${publish}" ;;
    '{{json .Config.Cmd}}') printf '%s\n' "${cmd}" ;;
    '{{.State.Running}}') printf '%s\n' "${running}" ;;
    *) echo "unexpected docker inspect format: ${format}" >&2; exit 92 ;;
  esac
  exit 0
fi
if [[ "$*" == 'container start hermes-gateway' ]]; then echo started >"${state_file}"; exit 0; fi
if [[ "$*" == 'container rm -f hermes-gateway' ]]; then echo removed >"${state_file}"; exit 0; fi
if [[ "$1" == run ]]; then
  [[ "$*" == "run -d --name hermes-gateway --restart unless-stopped --volume /var/lib/hermes:/opt/data ${image} hermes gateway run" ]] || { echo 'unexpected docker run shape' >&2; exit 94; }
  echo created >"${state_file}"; echo mock-container-id; exit 0
fi
echo "unexpected docker invocation: $*" >&2
exit 95
