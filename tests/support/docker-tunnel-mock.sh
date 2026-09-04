#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_TUNNEL_CALLS}"

image='cloudflare/cloudflared@sha256:51c9cefcb4569df44e1ad403ab1d3d8065aa8e84339bcfc6aee75502e1140339'
container_mode="${MOCK_TUNNEL_CONTAINER_MODE:-matching-running}"
network_mode="${MOCK_TUNNEL_NETWORK_MODE:-valid}"
gateway_mode="${MOCK_TUNNEL_GATEWAY_MODE:-attached}"
container_state_file="${MOCK_TUNNEL_CALLS}.container.state"
container_state="$(cat "${container_state_file}" 2>/dev/null || true)"

if [[ "$*" == 'info' ]]; then exit 0; fi
if [[ "$*" == 'logs --tail 50 hermes-cloudflared' ]]; then echo 'mock tunnel logs'; exit 0; fi

# --- gateway container existence / running state ---
if [[ "$*" == 'container inspect hermes-gateway' ]]; then
  [[ "${gateway_mode}" != missing ]] || exit 1
  exit 0
fi
if [[ "$1 $2 $3" == 'container inspect --format' && "${5:-}" == hermes-gateway ]]; then
  [[ "$4" == '{{.State.Running}}' && $# -eq 5 ]] || { echo 'unexpected gateway inspect format' >&2; exit 93; }
  if [[ "${gateway_mode}" == stopped ]]; then printf 'false\n'; else printf 'true\n'; fi
  exit 0
fi

# --- network existence / creation / attachment ---
if [[ "$*" == 'network inspect hermes-tunnel-net' ]]; then
  [[ "${network_mode}" != absent ]] || exit 1
  exit 0
fi
if [[ "$1 $2 $3" == 'network inspect --format' ]]; then
  format="$4"
  target="${5:-}"
  [[ "${target}" == hermes-tunnel-net && $# -eq 5 ]] || { echo 'unexpected network inspect target' >&2; exit 93; }
  driver=bridge internal=false
  case "${network_mode}" in
    mismatch-driver) driver=macvlan ;;
    mismatch-internal) internal=true ;;
  esac
  case "${format}" in
    '{{.Driver}}') printf '%s\n' "${driver}" ;;
    '{{.Internal}}') printf '%s\n' "${internal}" ;;
    '{{range .Containers}}{{.Name}} {{end}}')
      case "${gateway_mode}" in
        attached) printf 'hermes-gateway \n' ;;
        *) printf '\n' ;;
      esac
      ;;
    *) echo "unexpected network inspect format: ${format}" >&2; exit 92 ;;
  esac
  exit 0
fi
if [[ "$*" == 'network create --driver bridge hermes-tunnel-net' ]]; then exit 0; fi
if [[ "$*" == 'network connect hermes-tunnel-net hermes-gateway' ]]; then
  [[ "${gateway_mode}" != connect-fail ]] || exit 1
  : >"${MOCK_TUNNEL_CALLS}.connect.state"
  exit 0
fi
if [[ "$*" == 'network disconnect hermes-tunnel-net hermes-gateway' ]]; then exit 0; fi
if [[ "$*" == 'network rm hermes-tunnel-net' ]]; then exit 0; fi

# --- cloudflared container ---
if [[ "$*" == 'container inspect hermes-cloudflared' ]]; then
  [[ ( "${container_mode}" != absent && "${container_mode}" != absent-exit-after-run && "${container_mode}" != run-fail ) || "${container_state}" == created ]] || exit 1
  exit 0
fi
if [[ "$1 $2 $3" == 'container inspect --format' && "${5:-}" == hermes-cloudflared ]]; then
  [[ $# -eq 5 ]] || { echo 'unexpected inspect target' >&2; exit 93; }
  format="$4"
  running=true
  [[ "${container_mode}" != matching-stopped || "${container_state}" == started ]] || running=false
  [[ "${container_mode}" != exit-after-start || -n "${container_state}" ]] || running=false
  [[ "${container_mode}" != exit-after-start || "${container_state}" != started ]] || running=false
  [[ "${container_mode}" != exit-after-run || "${container_state}" != created ]] || running=false
  [[ "${container_mode}" != absent-exit-after-run || "${container_state}" != created ]] || running=false
  cmd='["tunnel","--no-autoupdate","run","--token-file","/run/secrets/cloudflared-token"]'
  binds='["/var/lib/hermes/cloudflare-tunnel/token:/run/secrets/cloudflared-token:ro"]'
  restart='unless-stopped'
  privileged=false caps=null cap_drop='["ALL"]' ports='{}' publish=false network=hermes-tunnel-net
  mounts=null volumes_from=null readonly=true security_opt='["no-new-privileges"]' user='0:0' networks='hermes-tunnel-net '
  case "${container_mode}" in
    mismatch-image) image='wrong:image' ;;
    mismatch-command) cmd='["wrong"]' ;;
    mismatch-bind) binds='["/tmp:/run/secrets/cloudflared-token:ro"]' ;;
    mismatch-restart) restart='always' ;;
    mismatch-privileged) privileged=true ;;
    mismatch-capabilities) caps='["SYS_ADMIN"]' ;;
    mismatch-cap-drop) cap_drop='[]' ;;
    mismatch-user) user='1000:1000' ;;
    mismatch-ports) ports='{"80/tcp":[{"HostPort":"80"}]}' ;;
    mismatch-publish-all) publish=true ;;
    mismatch-network) network=bridge ;;
    mismatch-extra-network) networks='hermes-tunnel-net unexpected-net ' ;;
    mismatch-extra-mount) mounts='[{"Type":"bind"}]' ;;
    mismatch-volumes-from) volumes_from='["other"]' ;;
    mismatch-readonly) readonly=false ;;
    mismatch-security-opt) security_opt='[]' ;;
  esac
  case "${format}" in
    '{{.Config.Image}}') printf '%s\n' "${image}" ;;
    '{{.Config.User}}') printf '%s\n' "${user}" ;;
    '{{.HostConfig.Privileged}}') printf '%s\n' "${privileged}" ;;
    '{{.HostConfig.NetworkMode}}') printf '%s\n' "${network}" ;;
    '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}') printf '%s\n' "${networks}" ;;
    '{{.HostConfig.RestartPolicy.Name}}') printf '%s\n' "${restart}" ;;
    '{{json .HostConfig.Binds}}') printf '%s\n' "${binds}" ;;
    '{{json .HostConfig.Mounts}}') printf '%s\n' "${mounts}" ;;
    '{{json .HostConfig.VolumesFrom}}') printf '%s\n' "${volumes_from}" ;;
    '{{json .HostConfig.CapAdd}}') printf '%s\n' "${caps}" ;;
    '{{json .HostConfig.CapDrop}}') printf '%s\n' "${cap_drop}" ;;
    '{{json .HostConfig.PortBindings}}') printf '%s\n' "${ports}" ;;
    '{{.HostConfig.PublishAllPorts}}') printf '%s\n' "${publish}" ;;
    '{{.HostConfig.ReadonlyRootfs}}') printf '%s\n' "${readonly}" ;;
    '{{json .HostConfig.SecurityOpt}}') printf '%s\n' "${security_opt}" ;;
    '{{json .Config.Cmd}}') printf '%s\n' "${cmd}" ;;
    '{{.State.Running}}') printf '%s\n' "${running}" ;;
    *) echo "unexpected docker inspect format: ${format}" >&2; exit 92 ;;
  esac
  exit 0
fi
if [[ "$*" == 'container start hermes-cloudflared' ]]; then echo started >"${container_state_file}"; exit 0; fi
if [[ "$*" == 'container stop hermes-cloudflared' ]]; then echo stopped >"${container_state_file}"; exit 0; fi
if [[ "$*" == 'container rm -f hermes-cloudflared' ]]; then echo removed >"${container_state_file}"; exit 0; fi
if [[ "$1" == run ]]; then
  [[ "${container_mode}" != run-fail ]] || exit 1
  [[ "$*" == "run -d --name hermes-cloudflared --restart unless-stopped --network hermes-tunnel-net --user 0:0 --cap-drop ALL --security-opt no-new-privileges --read-only --volume /var/lib/hermes/cloudflare-tunnel/token:/run/secrets/cloudflared-token:ro ${image} tunnel --no-autoupdate run --token-file /run/secrets/cloudflared-token" ]] || { echo 'unexpected docker run shape' >&2; exit 94; }
  echo created >"${container_state_file}"; echo mock-container-id; exit 0
fi
echo "unexpected docker invocation: $*" >&2
exit 95
