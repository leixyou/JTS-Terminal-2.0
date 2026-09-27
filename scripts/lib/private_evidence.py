"""Private evidence directory and immutable candidate manifest support."""

from __future__ import annotations

import dataclasses
import datetime as dt
import hashlib
import json
import os
import stat
import uuid
from pathlib import Path

from .rdp_candidate_binding import VerificationError, reject_symlink_components


class EvidenceWriter:
    def __init__(self, root: Path, directory: Path | None) -> None:
        self.root = prepare_evidence_root(root)
        self.directory = create_private_evidence_directory(self.root, directory)
        metadata = os.lstat(self.directory)
        self._directory_identity = (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_uid,
        )

    def write_json(self, name: str, value: object) -> None:
        if (
            "/" in name
            or "\\" in name
            or not name.endswith(".json")
            or name.startswith(".")
        ):
            raise VerificationError(f"Unsafe evidence filename: {name!r}")
        payload = json.dumps(
            value,
            ensure_ascii=True,
            indent=2,
            sort_keys=True,
        ).encode("utf-8") + b"\n"
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        directory_descriptor = self._open_directory()
        try:
            descriptor = os.open(
                name,
                flags,
                0o600,
                dir_fd=directory_descriptor,
            )
            try:
                view = memoryview(payload)
                while view:
                    written = os.write(descriptor, view)
                    if written <= 0:
                        raise VerificationError(f"Could not write evidence file: {name}")
                    view = view[written:]
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        finally:
            os.close(directory_descriptor)

    def verify_private_contents(self) -> None:
        directory_descriptor = self._open_directory()
        try:
            for name in os.listdir(directory_descriptor):
                metadata = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
                if (
                    not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_uid != os.getuid()
                    or metadata.st_nlink != 1
                    or stat.S_IMODE(metadata.st_mode) != 0o600
                ):
                    raise VerificationError(
                        f"Evidence entry is not a private regular file: {name}"
                    )
        finally:
            os.close(directory_descriptor)

    def _open_directory(self) -> int:
        flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            flags |= os.O_DIRECTORY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(self.directory, flags)
        metadata = os.fstat(descriptor)
        identity = (metadata.st_dev, metadata.st_ino, metadata.st_uid)
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or identity != self._directory_identity
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o700
        ):
            os.close(descriptor)
            raise VerificationError("Evidence directory ownership, mode, or identity changed.")
        return descriptor


def build_bundle_manifest(bundle: Path) -> dict[str, object]:
    entries: list[dict[str, object]] = []
    for path in sorted(bundle.rglob("*"), key=lambda item: os.fsencode(str(item))):
        metadata = os.lstat(path)
        relative = str(path.relative_to(bundle))
        entry: dict[str, object] = {
            "mode": f"{stat.S_IMODE(metadata.st_mode):04o}",
            "path": relative,
        }
        if stat.S_ISDIR(metadata.st_mode):
            entry["kind"] = "directory"
        elif stat.S_ISREG(metadata.st_mode):
            entry.update(
                {
                    "kind": "file",
                    "sha256": sha256_file(path),
                    "size": metadata.st_size,
                }
            )
        elif stat.S_ISLNK(metadata.st_mode):
            entry.update({"kind": "symlink", "target": os.readlink(path)})
        else:
            raise VerificationError(
                f"Unsupported filesystem object in candidate: {relative}"
            )
        entries.append(entry)
    encoded_entries = json.dumps(
        entries,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return {
        "bundle": str(bundle),
        "entryCount": len(entries),
        "entries": entries,
        "manifestSHA256": hashlib.sha256(encoded_entries).hexdigest(),
    }


def prepare_evidence_root(root: Path) -> Path:
    if not root.is_absolute():
        raise VerificationError("Evidence root must be absolute.")
    if root.exists():
        reject_symlink_components(root)
        resolved = root.resolve(strict=True)
        if resolved != root or not root.is_dir():
            raise VerificationError("Evidence root is not a canonical directory.")
        metadata = os.lstat(root)
        if (
            metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) & 0o022
        ):
            raise VerificationError(
                "Evidence root must be owner-controlled and not group/other writable."
            )
        return root
    parent = root.parent.resolve(strict=True)
    reject_symlink_components(parent)
    previous_umask = os.umask(0o077)
    try:
        root.mkdir(mode=0o700)
    finally:
        os.umask(previous_umask)
    if root.parent.resolve(strict=True) != parent:
        raise VerificationError("Evidence root parent changed during creation.")
    metadata = os.lstat(root)
    if metadata.st_uid != os.getuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
        raise VerificationError("Evidence root was not created as an owner-only directory.")
    return root


def create_private_evidence_directory(
    root: Path,
    requested: Path | None,
) -> Path:
    if requested is None:
        name = (
            f"{dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
            f"-distribution-rdp-xpc-recovery-{uuid.uuid4().hex[:8]}"
        )
        directory = root / name
    else:
        if not requested.is_absolute():
            raise VerificationError("Evidence directory must be absolute.")
        if requested.parent != root:
            raise VerificationError(
                "Evidence directory must be a direct child of the configured evidence root."
            )
        directory = requested
    if directory.exists() or directory.is_symlink():
        raise VerificationError("Evidence directory must not already exist.")
    previous_umask = os.umask(0o077)
    try:
        directory.mkdir(mode=0o700)
    finally:
        os.umask(previous_umask)
    metadata = os.lstat(directory)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        raise VerificationError("Could not create a private evidence directory.")
    return directory


def json_value(value: object) -> object:
    if dataclasses.is_dataclass(value):
        return {
            field.name: json_value(getattr(value, field.name))
            for field in dataclasses.fields(value)
        }
    if isinstance(value, dict):
        return {str(key): json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_value(item) for item in value]
    if isinstance(value, Path):
        return str(value)
    return value


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
