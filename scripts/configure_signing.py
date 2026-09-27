#!/usr/bin/env python3
"""Configure one local development team without relaxing signed IPC identity checks."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import tempfile

PLACEHOLDER = "YOURTEAMID"
STATE_FILE = ".jts-signing.json"
SIGNING_FILES = (
    "JTCompanionTransportService/CompanionListener.swift",
    "JTCompanionTransportService/README.md",
    "JTFreeRDPService/main.m",
    "JTSTerminal/JTSTerminalReleaseTesting.entitlements",
    "JTSTerminal/RemoteDesktop/FreeRDPXPCClient.swift",
    "JTSTerminal.xcodeproj/project.pbxproj",
    "JTSTerminalTests/CompanionTransportXPCTests.swift",
    "Packages/JTSCompanionTransport/Sources/JTSCompanionClient/CompanionIPCTransport.swift",
    "Packages/JTSCompanionTransport/Tests/JTSCompanionClientTests/ClientLifecycleTests.swift",
    "Protocols/JTSCompanion/mac-ipc-v1.md",
    "scripts/lib/debug_runtime_signing.py",
    "scripts/lib/rdp_candidate_binding.py",
    "scripts/lib/release_testing_runtime.py",
    "scripts/tests/test_debug_runtime_signing.py",
)


def validate_team(value: str) -> str:
    if not re.fullmatch(r"[A-Z0-9]{10}", value) or value == PLACEHOLDER:
        raise ValueError("Team ID must contain exactly 10 uppercase letters/digits and cannot be the placeholder.")
    return value


def atomic_write(path: Path, text: str, mode: int) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def configure(root: Path, team: str) -> int:
    team = validate_team(team)
    root = root.resolve(strict=True)
    state = root / STATE_FILE
    if state.is_symlink():
        raise ValueError("Signing state must not be a symlink.")
    previous = PLACEHOLDER
    if state.exists():
        value = json.loads(state.read_text(encoding="utf-8"))
        if set(value) != {"version", "teamID"} or value["version"] != 1:
            raise ValueError("Unexpected local signing state.")
        previous = validate_team(value["teamID"])
    changes = []
    for relative in SIGNING_FILES:
        path = root / relative
        if path.resolve(strict=True) != path or not path.is_file():
            raise ValueError(f"Signing source must be a regular file without symlinks: {relative}")
        source = path.read_text(encoding="utf-8")
        if previous not in source:
            raise ValueError(f"Expected signing marker is missing; no files changed: {relative}")
        changes.append((path, source.replace(previous, team), path.stat().st_mode & 0o777))
    # Validate the entire fixed source set before the first write. This changes a
    # build-time identity only; no peer-provided or runtime environment override exists.
    if previous != team:
        for path, text, mode in changes:
            atomic_write(path, text, mode)
    atomic_write(state, json.dumps({"version": 1, "teamID": team}, indent=2) + "\n", 0o600)
    return len(changes)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        count = configure(args.repo_root, args.team_id)
    except (ValueError, OSError, TypeError, KeyError) as error:
        parser.exit(2, f"Signing configuration failed: {error}\n")
    print(f"Configured {count} signing sources. Exact Apple anchor, bundle identity and team checks remain enabled.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
