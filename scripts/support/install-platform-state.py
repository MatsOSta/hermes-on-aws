#!/usr/bin/env python3
"""Safely persist non-secret platform intent for resumable installs."""

from __future__ import annotations

import errno
import fcntl
import os
import re
import secrets
import stat
import sys
from typing import Never

ID_RE = re.compile(r"^hms-[a-f0-9]{12}$")
PLATFORM_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
STATE_DIRECTORY = "install-platforms"
VERSION = "1"


class StateError(Exception):
    """An operator-facing platform-state safety or validation failure."""


def fail(message: str) -> Never:
    raise StateError(message)


def validate_id(value: str) -> None:
    if not ID_RE.fullmatch(value):
        fail("deployment ID must match ^hms-[a-f0-9]{12}$")


def validate_platform(value: str) -> None:
    if not PLATFORM_RE.fullmatch(value):
        fail("platform must be a lowercase identifier")


def validate_fd(fd: int, description: str, expected_mode: int, directory: bool = False) -> None:
    metadata = os.fstat(fd)
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected_type(metadata.st_mode):
        fail(f"{description} must be a {'directory' if directory else 'regular file'}")
    if metadata.st_uid != os.geteuid():
        fail(f"{description} must be owned by the current user")
    if stat.S_IMODE(metadata.st_mode) != expected_mode:
        fail(f"{description} permissions must be 0{expected_mode:o}")


def open_root(path: str) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        return_fd = os.open(path, flags)
    except FileNotFoundError:
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
        except OSError as error:
            fail(f"unable to create operator root: {error.strerror}")
        try:
            return_fd = os.open(path, flags)
        except OSError as error:
            fail(f"unable to open operator root safely: {error.strerror}")
    except OSError as error:
        if error.errno == errno.ELOOP:
            fail("operator root must not be a symbolic link")
        fail(f"unable to open operator root safely: {error.strerror}")
    validate_fd(return_fd, "operator root", 0o700, directory=True)
    return return_fd


def open_state_directory(root_fd: int) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        directory_fd = os.open(STATE_DIRECTORY, flags, dir_fd=root_fd)
    except FileNotFoundError:
        try:
            os.mkdir(STATE_DIRECTORY, 0o700, dir_fd=root_fd)
        except FileExistsError:
            pass
        except OSError as error:
            fail(f"unable to create platform install state directory: {error.strerror}")
        try:
            directory_fd = os.open(STATE_DIRECTORY, flags, dir_fd=root_fd)
        except OSError as error:
            fail(f"unable to open platform install state directory safely: {error.strerror}")
    except OSError as error:
        if error.errno == errno.ELOOP:
            fail("platform install state directory must not be a symbolic link")
        fail(f"unable to open platform install state directory safely: {error.strerror}")
    validate_fd(directory_fd, "platform install state directory", 0o700, directory=True)
    return directory_fd


def open_regular(directory_fd: int, name: str, description: str, missing_ok: bool) -> int | None:
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=directory_fd)
    except FileNotFoundError:
        if missing_ok:
            return None
        fail(f"{description} does not exist")
    except OSError as error:
        if error.errno == errno.ELOOP:
            fail(f"{description} must not be a symbolic link")
        fail(f"unable to open {description} safely: {error.strerror}")
    validate_fd(fd, description, 0o600)
    return fd


def read_all(fd: int) -> bytes:
    chunks: list[bytes] = []
    while True:
        chunk = os.read(fd, 4096)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def parse_state(data: bytes) -> tuple[str, bool]:
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        fail("platform install state is malformed")
    lines = text.splitlines()
    if len(lines) != 3 or not text.endswith("\n"):
        fail("platform install state is malformed")
    expected_keys = ("version", "platform", "host_prepared")
    values: dict[str, str] = {}
    for line, expected_key in zip(lines, expected_keys, strict=True):
        key, separator, value = line.partition("=")
        if separator != "=" or key != expected_key or not value:
            fail("platform install state is malformed")
        values[key] = value
    if values["version"] != VERSION:
        fail(f"unsupported platform install state version: {values['version']}")
    validate_platform(values["platform"])
    if values["host_prepared"] not in {"0", "1"}:
        fail("platform install state is malformed")
    return values["platform"], values["host_prepared"] == "1"


def read_state(directory_fd: int, deployment_id: str) -> tuple[str, bool] | None:
    fd = open_regular(directory_fd, deployment_id, "platform install state", missing_ok=True)
    if fd is None:
        return None
    try:
        return parse_state(read_all(fd))
    finally:
        os.close(fd)


def serialize(platform: str, host_prepared: bool) -> bytes:
    return (
        f"version={VERSION}\nplatform={platform}\nhost_prepared={int(host_prepared)}\n"
    ).encode("ascii")


def replace_state(directory_fd: int, deployment_id: str, platform: str, host_prepared: bool) -> None:
    temp_name = f".{deployment_id}.{os.getpid()}.{secrets.token_hex(8)}"
    fd: int | None = None
    try:
        fd = os.open(
            temp_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=directory_fd,
        )
        os.fchmod(fd, 0o600)
        payload = serialize(platform, host_prepared)
        view = memoryview(payload)
        while view:
            view = view[os.write(fd, view) :]
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.replace(temp_name, deployment_id, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        os.fsync(directory_fd)
    except OSError as error:
        fail(f"unable to replace platform install state safely: {error.strerror}")
    finally:
        if fd is not None:
            os.close(fd)
        try:
            os.unlink(temp_name, dir_fd=directory_fd)
        except FileNotFoundError:
            pass


def open_lock(directory_fd: int, deployment_id: str) -> int:
    lock_name = f".{deployment_id}.lock"
    flags = os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(lock_name, flags | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=directory_fd)
        os.fchmod(fd, 0o600)
    except FileExistsError:
        try:
            fd = os.open(lock_name, flags, dir_fd=directory_fd)
        except OSError as error:
            if error.errno == errno.ELOOP:
                fail("platform install state lock must not be a symbolic link")
            fail(f"unable to open platform install state lock safely: {error.strerror}")
    except OSError as error:
        fail(f"unable to create platform install state lock safely: {error.strerror}")
    validate_fd(fd, "platform install state lock", 0o600)
    return fd


def update(root_path: str, deployment_id: str, platform: str, mark_prepared: bool) -> str:
    validate_id(deployment_id)
    validate_platform(platform)
    root_fd = open_root(root_path)
    try:
        directory_fd = open_state_directory(root_fd)
        try:
            lock_fd = open_lock(directory_fd, deployment_id)
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_EX)
                current = read_state(directory_fd, deployment_id)
                if current is None:
                    replace_state(directory_fd, deployment_id, platform, mark_prepared)
                    return "created"
                recorded_platform, host_prepared = current
                if recorded_platform != platform:
                    fail(
                        f"recorded platform {recorded_platform} conflicts with requested platform {platform}"
                    )
                if mark_prepared and not host_prepared:
                    replace_state(directory_fd, deployment_id, platform, True)
                    return "updated"
                return "retained"
            finally:
                os.close(lock_fd)
        finally:
            os.close(directory_fd)
    finally:
        os.close(root_fd)


def main(argv: list[str]) -> None:
    if len(argv) != 5:
        fail("internal platform install state helper usage error")
    command, root_path, deployment_id, platform = argv[1:]
    if command == "ensure":
        result = update(root_path, deployment_id, platform, mark_prepared=False)
        if result == "retained":
            print("Retaining matching LINE install intent.")
        elif result == "created":
            print("Recorded LINE install intent in restricted operator-local state.")
        else:
            fail("platform install state changed unexpectedly")
    elif command == "mark-host-prepared":
        update(root_path, deployment_id, platform, mark_prepared=True)
    else:
        fail("internal platform install state helper usage error")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except StateError as error:
        print(f"Error: {error}", file=sys.stderr)
        raise SystemExit(1)
