#!/usr/bin/env python3
"""Race-safe local deployment alias registry operations."""

from __future__ import annotations

import errno
import fcntl
import os
import re
import secrets
import stat
import sys
from collections.abc import Callable

ALIAS_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
ID_RE = re.compile(r"^hms-[a-f0-9]{12}$")
REGISTRY = "aliases"
LOCK = "aliases.lock"


class RegistryError(Exception):
    """An operator-facing registry safety or validation failure."""


def fail(message: str) -> None:
    raise RegistryError(message)


def validate_alias(value: str) -> None:
    if not ALIAS_RE.fullmatch(value):
        fail("deployment alias must be 1-63 lowercase letters, digits, or interior hyphens")
    if ID_RE.fullmatch(value):
        fail("deployment aliases may not use the opaque deployment-ID namespace")


def validate_id(value: str) -> None:
    if not ID_RE.fullmatch(value):
        fail("deployment ID must match ^hms-[a-f0-9]{12}$")


def validate_fd(fd: int, description: str, expected_mode: int, directory: bool = False) -> None:
    metadata = os.fstat(fd)
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected_type(metadata.st_mode):
        fail(f"{description} must be a {'directory' if directory else 'regular file'}")
    if metadata.st_uid != os.geteuid():
        fail(f"{description} must be owned by the current user")
    if stat.S_IMODE(metadata.st_mode) != expected_mode:
        if directory:
            fail(
                "operator root permissions must be 0700; inspect it, then run: "
                f"chmod 700 -- {os.environ['HOME']}/hermes-operator"
            )
        fail(f"{description} permissions must be 0{expected_mode:o}")


def open_root(path: str, create: bool) -> int | None:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    fd: int
    try:
        fd = os.open(path, flags)
    except FileNotFoundError:
        if not create:
            return None
        try:
            os.mkdir(path, 0o700)
        except FileExistsError:
            pass
        except OSError as error:
            fail(f"unable to create operator root: {error.strerror}")
        try:
            fd = os.open(path, flags)
        except OSError as error:
            fail(f"unable to open operator root safely: {error.strerror}")
    except OSError as error:
        if error.errno == errno.ELOOP:
            fail("operator root must not be a symbolic link")
        fail(f"unable to open operator root safely: {error.strerror}")
    validate_fd(fd, "operator root", 0o700, directory=True)
    return fd


def open_relative_regular(root_fd: int, name: str, description: str, missing_ok: bool) -> int | None:
    fd: int
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=root_fd)
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
        chunk = os.read(fd, 65536)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def parse_registry(data: bytes) -> list[tuple[str, str]]:
    if not data:
        return []
    lines = data.split(b"\n")
    if lines[-1] == b"":
        lines.pop()
    records: list[tuple[str, str]] = []
    aliases: set[str] = set()
    ids: set[str] = set()
    for line in lines:
        fields = line.split(b"\t")
        if len(fields) != 2 or not fields[0] or not fields[1]:
            fail("alias registry contains a malformed record")
        try:
            alias = fields[0].decode("ascii")
            deployment_id = fields[1].decode("ascii")
        except UnicodeDecodeError:
            fail("alias registry contains a malformed record")
        validate_alias(alias)
        validate_id(deployment_id)
        if alias in aliases:
            fail("alias registry contains a duplicate alias")
        if deployment_id in ids:
            fail("alias registry contains a duplicate canonical deployment ID")
        aliases.add(alias)
        ids.add(deployment_id)
        records.append((alias, deployment_id))
    return records


def read_registry(root_fd: int) -> list[tuple[str, str]]:
    fd = open_relative_regular(root_fd, REGISTRY, "alias registry", missing_ok=True)
    if fd is None:
        return []
    try:
        return parse_registry(read_all(fd))
    finally:
        os.close(fd)


def open_lock(root_fd: int) -> int:
    flags = os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC
    fd: int
    try:
        fd = os.open(LOCK, flags | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=root_fd)
        os.fchmod(fd, 0o600)
    except FileExistsError:
        try:
            fd = os.open(LOCK, flags, dir_fd=root_fd)
        except OSError as error:
            if error.errno == errno.ELOOP:
                fail("alias registry lock must not be a symbolic link")
            fail(f"unable to open alias registry lock safely: {error.strerror}")
    except OSError as error:
        fail(f"unable to create alias registry lock safely: {error.strerror}")
    validate_fd(fd, "alias registry lock", 0o600)
    return fd


def serialize(records: list[tuple[str, str]]) -> bytes:
    return b"".join(f"{alias}\t{deployment_id}\n".encode("ascii") for alias, deployment_id in records)


def replace_registry(root_fd: int, records: list[tuple[str, str]]) -> None:
    temp_name = f".aliases.{os.getpid()}.{secrets.token_hex(8)}"
    fd: int | None = None
    try:
        fd = os.open(
            temp_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=root_fd,
        )
        os.fchmod(fd, 0o600)
        payload = serialize(records)
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            view = view[written:]
        os.fsync(fd)
        os.close(fd)
        fd = None
        os.replace(temp_name, REGISTRY, src_dir_fd=root_fd, dst_dir_fd=root_fd)
        os.fsync(root_fd)
    except OSError as error:
        fail(f"unable to replace alias registry safely: {error.strerror}")
    finally:
        if fd is not None:
            os.close(fd)
        try:
            os.unlink(temp_name, dir_fd=root_fd)
        except FileNotFoundError:
            pass


def update(root_path: str, transform: Callable[[list[tuple[str, str]]], list[tuple[str, str]]]) -> None:
    root_fd = open_root(root_path, create=True)
    assert root_fd is not None
    try:
        lock_fd = open_lock(root_fd)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            replace_registry(root_fd, transform(read_registry(root_fd)))
        finally:
            os.close(lock_fd)
    finally:
        os.close(root_fd)


def command_read(root_path: str) -> None:
    root_fd = open_root(root_path, create=False)
    if root_fd is None:
        return
    try:
        sys.stdout.buffer.write(serialize(read_registry(root_fd)))
    finally:
        os.close(root_fd)


def command_set(root_path: str, alias: str, deployment_id: str) -> None:
    validate_alias(alias)
    validate_id(deployment_id)

    def transform(records: list[tuple[str, str]]) -> list[tuple[str, str]]:
        if any(item_alias == alias for item_alias, _ in records):
            fail(f"deployment alias already exists: {alias}")
        if any(item_id == deployment_id for _, item_id in records):
            fail(f"canonical deployment ID already has an alias: {deployment_id}")
        return [*records, (alias, deployment_id)]

    update(root_path, transform)


def command_remove(root_path: str, alias: str) -> None:
    validate_alias(alias)

    def transform(records: list[tuple[str, str]]) -> list[tuple[str, str]]:
        kept = [record for record in records if record[0] != alias]
        if len(kept) == len(records):
            fail(f"unknown deployment alias: {alias}")
        return kept

    update(root_path, transform)


def command_rename(root_path: str, old_alias: str, new_alias: str) -> None:
    validate_alias(old_alias)
    validate_alias(new_alias)

    def transform(records: list[tuple[str, str]]) -> list[tuple[str, str]]:
        if any(alias == new_alias for alias, _ in records):
            fail(f"deployment alias already exists: {new_alias}")
        if not any(alias == old_alias for alias, _ in records):
            fail(f"unknown deployment alias: {old_alias}")
        return [(new_alias if alias == old_alias else alias, deployment_id) for alias, deployment_id in records]

    update(root_path, transform)


def main(argv: list[str]) -> None:
    if len(argv) < 3:
        fail("internal alias registry helper usage error")
    command, root_path = argv[1:3]
    args = argv[3:]
    if command == "read" and not args:
        command_read(root_path)
    elif command == "set" and len(args) == 2:
        command_set(root_path, args[0], args[1])
    elif command == "remove" and len(args) == 1:
        command_remove(root_path, args[0])
    elif command == "rename" and len(args) == 2:
        command_rename(root_path, args[0], args[1])
    else:
        fail("internal alias registry helper usage error")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except RegistryError as error:
        print(f"Error: {error}", file=sys.stderr)
        raise SystemExit(1)
