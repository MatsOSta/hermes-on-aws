#!/usr/bin/env python3
"""Provision one bounded Cloudflare Tunnel from an interactive EC2 session."""

from __future__ import annotations

import getpass
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

HERMES_HOME = Path("/var/lib/hermes")
TUNNEL_HOME = HERMES_HOME / "cloudflare-tunnel"
STATE_PATH = TUNNEL_HOME / "state.json"
TOKEN_PATH = TUNNEL_HOME / "token"
RUNTIME_HELPER = Path("/usr/local/sbin/run-hermes-tunnel")
API_BASE = "https://api.cloudflare.com/client/v4"
REQUIRED_PERMISSIONS = (
    "Account / Cloudflare Tunnel / Edit",
    "Zone / DNS / Edit",
    "Zone / Zone / Read",
)
DEPLOYMENT_RE = re.compile(r"hms-[a-f0-9]{12}")
ID_RE = re.compile(r"[a-f0-9]{32}")
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}")
ZONE_RE = re.compile(r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}")
HOST_LABEL_RE = re.compile(r"edge-[a-f0-9]{12}")


def desired_ingress(hostname: str) -> list[dict[str, str]]:
    return [
        {"hostname": hostname, "service": "http://hermes-gateway:8646"},
        {"service": "http_status:404"},
    ]


def desired_dns(tunnel_id: str, hostname: str) -> dict[str, Any]:
    return {
        "type": "CNAME",
        "name": hostname,
        "content": f"{tunnel_id}.cfargotunnel.com",
        "proxied": True,
        "ttl": 1,
    }


def _atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    parent = path.parent.stat()
    if path.parent.is_symlink() or not stat.S_ISDIR(parent.st_mode) or parent.st_uid != 0:
        raise ValueError("tunnel state directory must be a root-owned real directory")
    os.chmod(path.parent, 0o700)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        view = memoryview(payload)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(temporary, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _secure_read(path: Path, maximum: int) -> bytes | None:
    if path.is_symlink():
        raise ValueError(f"refusing symlinked {path.name}")
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except FileNotFoundError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError(f"{path.name} must be a regular file with mode 0600")
        if info.st_uid != 0:
            raise ValueError(f"{path.name} must be owned by root")
        if info.st_size <= 0 or info.st_size > maximum:
            raise ValueError(f"{path.name} has an invalid size")
        data = bytearray()
        while len(data) <= maximum:
            chunk = os.read(fd, min(65536, maximum + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > maximum:
            raise ValueError(f"{path.name} is unexpectedly large")
        return bytes(data)
    finally:
        os.close(fd)


def load_state(path: Path) -> dict[str, Any] | None:
    payload = _secure_read(path, 16384)
    if payload is None:
        return None
    try:
        state = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("tunnel state is malformed") from exc
    required = {
        "version", "deployment_id", "account_id", "zone_id", "zone_name",
        "tunnel_id", "tunnel_name", "hostname",
    }
    if not isinstance(state, dict) or set(state) != required or state.get("version") != 1:
        raise ValueError("tunnel state has an unexpected schema")
    return state


def write_state(path: Path, state: dict[str, Any]) -> None:
    existing = load_state(path)
    if existing is not None and existing != state:
        raise ValueError("existing tunnel state conflicts; no state was replaced")
    if existing == state:
        return
    _atomic_write(path, (json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n").encode())


def write_connector_token(path: Path, token: str) -> None:
    if not re.fullmatch(r"[\x21-\x7e]{20,4096}", token):
        raise ValueError("connector credential is missing or malformed")
    existing = _secure_read(path, 4096)
    if existing is not None:
        try:
            current = existing.decode("ascii")
        except UnicodeDecodeError as exc:
            raise ValueError("existing connector credential is malformed") from exc
        if not secrets.compare_digest(current, token):
            raise ValueError("existing connector credential conflicts; rotation is a separate reviewed action")
        return
    _atomic_write(path, token.encode("ascii"))


class CloudflareAPI:
    def __init__(self, token: str):
        self._token = token

    def request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        query: dict[str, str] | None = None,
    ) -> Any:
        url = f"{API_BASE}{path}"
        if query:
            url = f"{url}?{urllib.parse.urlencode(query)}"
        data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
        request = urllib.request.Request(
            url,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self._token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                envelope = json.loads(response.read())
        except (urllib.error.URLError, json.JSONDecodeError) as exc:
            raise RuntimeError("Cloudflare API request failed; token and response were redacted") from exc
        if not isinstance(envelope, dict) or envelope.get("success") is not True or "result" not in envelope:
            raise RuntimeError("Cloudflare API rejected the request; token and response were redacted")
        return envelope["result"]


def resolve_zone(api: Any, zone_name: str) -> tuple[str, str]:
    zones = api.request("GET", "/zones", query={"name": zone_name})
    if not isinstance(zones, list) or len(zones) != 1:
        raise RuntimeError("Cloudflare zone lookup is ambiguous; no API mutation was attempted")
    zone = zones[0]
    if not isinstance(zone, dict) or zone.get("name") != zone_name:
        raise RuntimeError("Cloudflare zone lookup is malformed; no API mutation was attempted")
    zone_id = zone.get("id")
    account = zone.get("account")
    account_id = account.get("id") if isinstance(account, dict) else None
    if not isinstance(zone_id, str) or not ID_RE.fullmatch(zone_id):
        raise RuntimeError("Cloudflare zone identifier is malformed; no API mutation was attempted")
    if not isinstance(account_id, str) or not ID_RE.fullmatch(account_id):
        raise RuntimeError("Cloudflare account identifier is malformed; no API mutation was attempted")
    return account_id, zone_id


def _validate_tunnel(item: Any, tunnel_id: str, tunnel_name: str, account_id: str) -> None:
    if not isinstance(item, dict):
        raise RuntimeError("Cloudflare tunnel read-back is malformed")
    remote = item.get("config_src") == "cloudflare" or item.get("remote_config") is True
    if (
        item.get("id") != tunnel_id
        or item.get("name") != tunnel_name
        or item.get("account_tag") != account_id
        or item.get("deleted_at") is not None
        or not remote
    ):
        raise RuntimeError("Cloudflare tunnel ownership conflicts; no resource was replaced")


def _config_matches(result: Any, hostname: str) -> bool:
    if not isinstance(result, dict) or not isinstance(result.get("config"), dict):
        return False
    config = result["config"]
    if set(config) - {"ingress", "originRequest", "warp-routing"}:
        return False
    if config.get("warp-routing") not in (None, {}, {"enabled": False}):
        return False
    ingress = config.get("ingress")
    if not isinstance(ingress, list) or len(ingress) != 2:
        return False
    normalized = []
    for rule in ingress:
        if not isinstance(rule, dict):
            return False
        if set(rule) - {"hostname", "service", "originRequest", "path"}:
            return False
        if rule.get("path") not in (None, ""):
            return False
        normalized.append({key: rule[key] for key in ("hostname", "service") if key in rule})
    return normalized == desired_ingress(hostname)


def _ingress_is_unconfigured(ingress: Any) -> bool:
    if ingress in (None, []):
        return True
    if not isinstance(ingress, list):
        return False
    for rule in ingress:
        if not isinstance(rule, dict):
            return False
        if rule.get("hostname") or rule.get("path"):
            return False
        if rule.get("service") not in (None, "http_status:404"):
            return False
    return True


def _config_is_empty(result: Any) -> bool:
    if result in (None, {}):
        return True
    if not isinstance(result, dict):
        return False
    config = result.get("config")
    if config in (None, {}):
        return True
    if not isinstance(config, dict):
        return False
    if set(config) - {"ingress", "originRequest", "warp-routing"}:
        return False
    if config.get("warp-routing") not in (None, {}, {"enabled": False}):
        return False
    return _ingress_is_unconfigured(config.get("ingress"))


def _config_shape(result: Any) -> str:
    if not isinstance(result, dict):
        return type(result).__name__
    config = result.get("config")
    if not isinstance(config, dict):
        return f"outer={sorted(result)} config={type(config).__name__ if config is not None else 'null'}"
    origin = config.get("originRequest")
    origin_keys = sorted(origin) if isinstance(origin, dict) else type(origin).__name__
    rules = config.get("ingress")
    ingress = []
    if isinstance(rules, list):
        for rule in rules:
            if not isinstance(rule, dict):
                ingress.append(type(rule).__name__)
                continue
            service = str(rule.get("service", ""))
            ingress.append({
                "keys": sorted(rule),
                "hostname": bool(rule.get("hostname")),
                "path": bool(rule.get("path")),
                "service": "http_status" if service.startswith("http_status:") else "origin",
            })
    else:
        ingress = type(rules).__name__ if rules is not None else "null"
    warp = config.get("warp-routing")
    if isinstance(warp, dict):
        warp_shape = {"keys": sorted(warp), "enabled": bool(warp.get("enabled"))}
    else:
        warp_shape = type(warp).__name__ if warp is not None else "null"
    return (
        f"config_keys={sorted(config)} warp={warp_shape} "
        f"originRequest_keys={origin_keys} ingress={ingress}"
    )


def _dns_matches(record: Any, expected: dict[str, Any]) -> bool:
    return isinstance(record, dict) and all(record.get(key) == value for key, value in expected.items())


def _validated_state(
    state: dict[str, Any] | None,
    deployment_id: str,
    account_id: str,
    zone_id: str,
    zone_name: str,
) -> None:
    if state is None:
        return
    expected = {
        "deployment_id": deployment_id,
        "account_id": account_id,
        "zone_id": zone_id,
        "zone_name": zone_name,
        "tunnel_name": f"hermes-{deployment_id}",
    }
    labels = {
        "deployment_id": "deployment",
        "account_id": "account",
        "zone_id": "zone",
        "zone_name": "requested zone",
        "tunnel_name": "tunnel",
    }
    for key, value in expected.items():
        if state.get(key) != value:
            raise ValueError(f"existing tunnel state conflicts with {labels[key]}; no API mutation was attempted")
    if not UUID_RE.fullmatch(str(state.get("tunnel_id", ""))):
        raise ValueError("existing tunnel state contains a malformed tunnel identifier")
    hostname = str(state.get("hostname", ""))
    suffix = f".{zone_name}"
    if not hostname.endswith(suffix) or not HOST_LABEL_RE.fullmatch(hostname[: -len(suffix)]):
        raise ValueError("existing tunnel state contains a conflicting hostname")


def provision(
    api: Any,
    deployment_id: str,
    account_id: str,
    zone_id: str,
    zone_name: str,
    state_path: Path = STATE_PATH,
    hostname_label: Callable[[], str] = lambda: secrets.token_hex(6),
    token_path: Path | None = None,
) -> dict[str, str]:
    state = load_state(state_path)
    _validated_state(state, deployment_id, account_id, zone_id, zone_name)
    existing_token_bytes = _secure_read(token_path, 4096) if token_path is not None else None
    if state is None and existing_token_bytes is not None:
        raise ValueError("an unmanaged connector credential exists; no API mutation was attempted")
    tunnel_name = f"hermes-{deployment_id}"

    verified = api.request("GET", "/user/tokens/verify")
    if not isinstance(verified, dict) or verified.get("status") != "active":
        raise RuntimeError("Cloudflare API token is not active")
    zone = api.request("GET", f"/zones/{zone_id}")
    if (
        not isinstance(zone, dict)
        or zone.get("id") != zone_id
        or zone.get("name") != zone_name
        or not isinstance(zone.get("account"), dict)
        or zone["account"].get("id") != account_id
    ):
        raise RuntimeError("Cloudflare zone/account read-back conflicts; no API mutation was attempted")

    tunnels = api.request(
        "GET", f"/accounts/{account_id}/cfd_tunnel",
        query={"is_deleted": "false", "name": tunnel_name},
    )
    if not isinstance(tunnels, list) or len(tunnels) > 1:
        raise RuntimeError("Cloudflare tunnel lookup is ambiguous; no API mutation was attempted")

    if state is None:
        if tunnels:
            raise RuntimeError("an unmanaged same-name tunnel exists; no API mutation was attempted")
        label = hostname_label()
        if not re.fullmatch(r"[a-f0-9]{12}", label):
            raise ValueError("generated hostname label is malformed")
        hostname = f"edge-{label}.{zone_name}"
        records = api.request("GET", f"/zones/{zone_id}/dns_records", query={"name": hostname})
        if not isinstance(records, list) or records:
            raise RuntimeError("generated hostname is already owned; no API mutation was attempted")
        created = api.request("POST", f"/accounts/{account_id}/cfd_tunnel", {
            "name": tunnel_name,
            "config_src": "cloudflare",
        })
        if not isinstance(created, dict) or not UUID_RE.fullmatch(str(created.get("id", ""))):
            raise RuntimeError("Cloudflare tunnel creation returned malformed state")
        tunnel_id = created["id"]
        current = api.request("GET", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}")
        _validate_tunnel(current, tunnel_id, tunnel_name, account_id)
        state = {
            "version": 1,
            "deployment_id": deployment_id,
            "account_id": account_id,
            "zone_id": zone_id,
            "zone_name": zone_name,
            "tunnel_id": tunnel_id,
            "tunnel_name": tunnel_name,
            "hostname": hostname,
        }
        write_state(state_path, state)
    else:
        hostname = state["hostname"]
        tunnel_id = state["tunnel_id"]
        if len(tunnels) != 1:
            raise RuntimeError("managed Cloudflare tunnel is absent; automatic replacement is forbidden")
        _validate_tunnel(tunnels[0], tunnel_id, tunnel_name, account_id)
        current = api.request("GET", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}")
        _validate_tunnel(current, tunnel_id, tunnel_name, account_id)

    connector_token = api.request("GET", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/token")
    if not isinstance(connector_token, str) or not re.fullmatch(r"[\x21-\x7e]{20,4096}", connector_token):
        raise RuntimeError("Cloudflare connector credential response is malformed")
    if existing_token_bytes is not None:
        try:
            existing_token = existing_token_bytes.decode("ascii")
        except UnicodeDecodeError as exc:
            raise ValueError("existing connector credential is malformed") from exc
        if not secrets.compare_digest(existing_token, connector_token):
            raise ValueError("existing connector credential conflicts; no API mutation was attempted")

    configuration_path = f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations"
    configuration = api.request("GET", configuration_path)
    config_matches = _config_matches(configuration, hostname)
    if not config_matches and not _config_is_empty(configuration):
        raise RuntimeError(
            "published application configuration conflicts; no route was replaced "
            f"({_config_shape(configuration)})"
        )

    records_path = f"/zones/{zone_id}/dns_records"
    expected_dns = desired_dns(tunnel_id, hostname)
    records = api.request("GET", records_path, query={"name": hostname})
    if not isinstance(records, list):
        raise RuntimeError("Cloudflare DNS read-back is malformed")
    dns_matches = len(records) == 1 and _dns_matches(records[0], expected_dns)
    if records and not dns_matches:
        raise RuntimeError("Cloudflare DNS ownership conflicts; no record was replaced")

    # All ownership checks above are read-only. Mutate only after the entire
    # tunnel/configuration/DNS preflight is conflict-free.
    if not config_matches:
        api.request("PUT", configuration_path, {"config": {"ingress": desired_ingress(hostname)}})
        configuration = api.request("GET", configuration_path)
        if not _config_matches(configuration, hostname):
            raise RuntimeError("published application exact read-back failed")

    if not dns_matches:
        api.request("POST", records_path, expected_dns)
        records = api.request("GET", records_path, query={"name": hostname})
    if len(records) != 1 or not _dns_matches(records[0], expected_dns):
        raise RuntimeError("Cloudflare DNS exact read-back failed")

    return {"hostname": hostname, "connector_token": connector_token}


def verify_storage(expected_volume_id: str) -> None:
    if not re.fullmatch(r"vol-[0-9a-f]{8,17}", expected_volume_id):
        raise ValueError("expected EBS volume ID is malformed")
    inventory = subprocess.run(
        ["lsblk", "--json", "--paths", "--output", "PATH,TYPE,SERIAL"],
        check=True, text=True, capture_output=True,
    )
    try:
        devices = json.loads(inventory.stdout).get("blockdevices", [])
    except (json.JSONDecodeError, AttributeError) as exc:
        raise RuntimeError("block-device inventory is malformed") from exc
    serial = expected_volume_id.replace("-", "")
    matches = [item for item in devices if item.get("serial") == serial]
    if len(matches) != 1 or matches[0].get("type") != "disk" or not matches[0].get("path"):
        raise RuntimeError("reviewed EBS data volume did not resolve to exactly one whole device")
    mounted = subprocess.run(
        ["findmnt", "-rn", "-M", str(HERMES_HOME), "-o", "TARGET,SOURCE,FSTYPE,OPTIONS"],
        check=True, text=True, capture_output=True,
    )
    fields = mounted.stdout.strip().split()
    if len(fields) != 4 or fields[0] != str(HERMES_HOME) or fields[2] != "xfs":
        raise RuntimeError("/var/lib/hermes is not the expected XFS data mount")
    if os.path.realpath(fields[1]) != os.path.realpath(str(matches[0]["path"])):
        raise RuntimeError("/var/lib/hermes is backed by the wrong device")
    options = set(fields[3].split(","))
    if not {"rw", "nosuid", "nodev"}.issubset(options):
        raise RuntimeError("/var/lib/hermes mount options are unsafe")


def main() -> int:
    if len(sys.argv) != 3 or not DEPLOYMENT_RE.fullmatch(sys.argv[1]):
        print("Error: internal helper requires deployment ID and reviewed EBS volume ID", file=sys.stderr)
        return 1
    if os.geteuid() != 0 or not sys.stdin.isatty():
        print("Error: run as root in an interactive SSM session", file=sys.stderr)
        return 1
    verify_storage(sys.argv[2])
    if not RUNTIME_HELPER.is_file() or RUNTIME_HELPER.is_symlink():
        raise RuntimeError("reviewed tunnel runtime helper is missing or unsafe")
    zone_name = input("Cloudflare zone name (for example, example.com): ").strip().lower()
    if not ZONE_RE.fullmatch(zone_name):
        raise ValueError("Cloudflare zone name is malformed")
    api_token = getpass.getpass("Cloudflare scoped API token (hidden): ").strip()
    if not re.fullmatch(r"[\x21-\x7e]{20,4096}", api_token):
        raise ValueError("Cloudflare API token is missing or malformed")
    api = CloudflareAPI(api_token)
    account_id, zone_id = resolve_zone(api, zone_name)
    result = provision(
        api, sys.argv[1], account_id, zone_id, zone_name,
        token_path=TOKEN_PATH,
    )
    write_connector_token(TOKEN_PATH, result["connector_token"])
    del api_token
    del result["connector_token"]
    subprocess.run([str(RUNTIME_HELPER), "start"], check=True)
    print(f"Cloudflare tunnel resources and active connector verified for https://{result['hostname']}")
    print("No inbound AWS rule or published Docker host port was created.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(1)
