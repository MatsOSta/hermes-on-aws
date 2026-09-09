#!/usr/bin/env python3
"""Secure, remote-only LINE configuration and webhook bootstrap."""

from __future__ import annotations

import getpass
import ipaddress
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

HERMES_HOME = Path("/var/lib/hermes")
ENV_PATH = HERMES_HOME / ".env"
PINNED_IMAGE = "nousresearch/hermes-agent@sha256:f5efd66dfdc0a434adf20af4030ac856eea6631405f7d44a827c6d7a76bf083e"
LINE_KEYS = ("LINE_CHANNEL_ACCESS_TOKEN", "LINE_CHANNEL_SECRET", "LINE_PUBLIC_URL")


def validate_public_url(value: str) -> str:
    value = value.strip()
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("LINE public URL must be an HTTPS origin with no credentials")
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment or parsed.port not in (None, 443):
        raise ValueError("LINE public URL must contain only an HTTPS hostname")
    try:
        ipaddress.ip_address(parsed.hostname)
    except ValueError:
        pass
    else:
        raise ValueError("LINE public URL must use a DNS hostname")
    if not re.fullmatch(r"(?=.{1,253}\Z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", parsed.hostname.lower()):
        raise ValueError("LINE public URL hostname is invalid")
    return f"https://{parsed.hostname.lower()}"


def _read_env(path: Path) -> tuple[list[str], dict[str, str]]:
    if path.is_symlink():
        raise ValueError("refusing symlinked Hermes environment file")
    if not path.exists():
        return [], {}
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or opened.st_uid != 0 or stat.S_IMODE(opened.st_mode) != 0o600:
            raise ValueError("Hermes environment file must be a root-owned regular file with mode 0600")
        if opened.st_size > 1024 * 1024:
            raise ValueError("Hermes environment file is unexpectedly large")
        chunks: list[bytes] = []
        remaining = opened.st_size + 1
        while remaining:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        text = b"".join(chunks).decode("utf-8")
    finally:
        os.close(fd)
    lines = text.splitlines()
    values: dict[str, str] = {}
    for line in lines:
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in LINE_KEYS:
            if key in values:
                raise ValueError(f"duplicate existing {key}")
            values[key] = value
    return lines, values


def update_env(path: Path, requested: dict[str, str]) -> None:
    lines, existing = _read_env(path)
    for key, value in requested.items():
        if key not in LINE_KEYS or "\n" in value or "\r" in value or not value:
            raise ValueError("invalid LINE runtime configuration")
        if key in existing and existing[key] != value:
            raise ValueError(f"conflicting existing {key}; no values were changed")

    retained = [line for line in lines if not any(line.startswith(f"{key}=") for key in requested)]
    content = "\n".join(retained + [f"{key}={requested[key]}" for key in LINE_KEYS if key in requested]) + "\n"
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.parent.is_symlink() or path.parent.stat().st_uid != 0:
        raise ValueError("Hermes home must be a root-owned directory")
    fd, name = tempfile.mkstemp(prefix=".env.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        payload = content.encode("utf-8")
        view = memoryview(payload)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(name, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass


class LineClient:
    def __init__(self, token: str):
        self.token = token

    def request(self, method: str, path: str, payload: dict[str, Any] | None = None) -> tuple[dict[str, Any], int]:
        data = None if payload is None else json.dumps(payload, separators=(",", ":")).encode()
        request = urllib.request.Request(
            f"https://api.line.me{path}", data=data, method=method,
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                body = response.read()
                return (json.loads(body) if body else {}), response.status
        except (urllib.error.URLError, json.JSONDecodeError) as exc:
            raise RuntimeError("LINE API request failed; credentials and response were redacted") from exc


def configure_webhook(client: LineClient, public_url: str) -> None:
    endpoint = f"{public_url}/line/webhook"
    _, status = client.request("PUT", "/v2/bot/channel/webhook/endpoint", {"endpoint": endpoint})
    if status != 200:
        raise RuntimeError("LINE webhook update failed")
    current, status = client.request("GET", "/v2/bot/channel/webhook/endpoint")
    if status != 200 or current.get("endpoint") != endpoint:
        raise RuntimeError("LINE webhook read-back did not match the requested endpoint")
    tested, status = client.request("POST", "/v2/bot/channel/webhook/test", {"endpoint": endpoint})
    if status != 200 or tested.get("success") is not True:
        raise RuntimeError("LINE webhook test did not succeed; configuration remains resumable")


def verify_storage(expected_volume_id: str) -> None:
    if not re.fullmatch(r"vol-[0-9a-f]{8,17}", expected_volume_id):
        raise ValueError("expected EBS volume ID is malformed")
    lsblk = subprocess.run(
        ["lsblk", "--json", "--paths", "--output", "PATH,TYPE,SERIAL"],
        check=True, text=True, capture_output=True,
    )
    try:
        devices = json.loads(lsblk.stdout).get("blockdevices", [])
    except (json.JSONDecodeError, AttributeError) as exc:
        raise RuntimeError("block-device inventory is malformed") from exc
    serial = expected_volume_id.replace("-", "")
    matches = [item for item in devices if item.get("serial") == serial]
    if len(matches) != 1 or matches[0].get("type") != "disk" or not matches[0].get("path"):
        raise RuntimeError("reviewed EBS data volume did not resolve to exactly one whole device")
    result = subprocess.run(
        ["findmnt", "-rn", "-M", str(HERMES_HOME), "-o", "TARGET,SOURCE,FSTYPE,OPTIONS"],
        check=True, text=True, capture_output=True,
    )
    fields = result.stdout.strip().split()
    if len(fields) != 4 or fields[0] != str(HERMES_HOME) or fields[2] != "xfs":
        raise RuntimeError("/var/lib/hermes is not the expected XFS data mount")
    if os.path.realpath(fields[1]) != os.path.realpath(str(matches[0]["path"])):
        raise RuntimeError("/var/lib/hermes is backed by the wrong device")
    options = set(fields[3].split(","))
    if not {"rw", "nosuid", "nodev", "noexec"}.issubset(options):
        raise RuntimeError("/var/lib/hermes mount options are unsafe")


def enable_line() -> None:
    subprocess.run([
        "docker", "run", "--rm", "--volume", "/var/lib/hermes:/opt/data",
        PINNED_IMAGE, "config", "set", "gateway.platforms.line.enabled", "true",
    ], check=True, stdout=subprocess.DEVNULL)


def main() -> int:
    if len(sys.argv) != 2:
        print("Error: internal helper usage requires one reviewed EBS volume ID", file=sys.stderr)
        return 1
    if os.geteuid() != 0 or not sys.stdin.isatty():
        print("Error: run as root in an interactive SSM session", file=sys.stderr)
        return 1
    verify_storage(sys.argv[1])
    token = getpass.getpass("LINE channel access token (hidden): ").strip()
    secret = getpass.getpass("LINE channel secret (hidden): ").strip()
    public_url = validate_public_url(input("LINE public HTTPS base URL: "))
    if not re.fullmatch(r"[\x21-\x7e]{20,4096}", token):
        raise ValueError("LINE channel access token is missing or malformed")
    if not re.fullmatch(r"[A-Za-z0-9]{32}", secret):
        raise ValueError("LINE channel secret must be 32 alphanumeric characters")
    update_env(ENV_PATH, {
        "LINE_CHANNEL_ACCESS_TOKEN": token,
        "LINE_CHANNEL_SECRET": secret,
        "LINE_PUBLIC_URL": public_url,
    })
    enable_line()
    configure_webhook(LineClient(token), public_url)
    print("LINE runtime configuration saved with mode 0600; Hermes LINE enabled.")
    print("LINE webhook endpoint write, exact read-back, and endpoint test succeeded.")
    print("UNVERIFIED manual settings: Use webhook, webhook redelivery, error statistics, greeting, auto-response.")
    print("NEXT: complete those console settings, then continue tunnel and allowlist/pairing phases.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        print("NEXT: correct the reported condition and rerun ./hermes.sh configure-line <deployment-id>.", file=sys.stderr)
        raise SystemExit(1)
