#!/usr/bin/env python3
"""Decode and validate an embedded macOS Apple Development profile."""

from __future__ import annotations

import argparse
import dataclasses
import json
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path

from lib.apple_development_profile import (
    DevelopmentProfileError,
    current_mac_provisioning_identifier,
    validate_development_profile,
)


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--certificate-sha1", required=True)
    parser.add_argument(
        "--device-id",
        help="Current Mac provisioning UDID; read from system_profiler when omitted.",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_argument_parser().parse_args(argv)
    try:
        decoded = subprocess.run(
            ["/usr/bin/security", "cms", "-D", "-i", str(args.profile)],
            text=False,
            capture_output=True,
            check=False,
        )
        if decoded.returncode != 0:
            raise DevelopmentProfileError(
                "security could not decode the embedded development profile."
            )
        device_identifier = args.device_id or current_mac_provisioning_identifier()
        identity = validate_development_profile(
            decoded.stdout,
            expected_team_identifier=args.team_id,
            expected_bundle_identifier=args.bundle_id,
            expected_certificate_sha1=args.certificate_sha1,
            current_device_identifier=device_identifier,
        )
    except (DevelopmentProfileError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(json.dumps(dataclasses.asdict(identity), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
