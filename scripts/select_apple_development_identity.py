#!/usr/bin/env python3
"""Select one usable Apple Development certificate by its subject Team OU."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from collections.abc import Sequence

from lib.apple_development_identity import (
    IdentitySelectionError,
    inspect_pem_certificates,
    parse_valid_code_signing_identities,
    select_apple_development_identity,
)


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--format", choices=("sha1", "json"), default="sha1")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_argument_parser().parse_args(argv)
    try:
        identity_result = subprocess.run(
            ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning"],
            text=True,
            capture_output=True,
            check=False,
        )
        if identity_result.returncode != 0:
            raise IdentitySelectionError(
                "security could not enumerate usable code-signing identities."
            )
        certificate_result = subprocess.run(
            ["/usr/bin/security", "find-certificate", "-a", "-p"],
            text=False,
            capture_output=True,
            check=False,
        )
        if certificate_result.returncode != 0:
            raise IdentitySelectionError(
                "security could not export keychain certificates."
            )
        identity = select_apple_development_identity(
            parse_valid_code_signing_identities(identity_result.stdout),
            inspect_pem_certificates(certificate_result.stdout),
            expected_team_identifier=args.team_id,
        )
    except (IdentitySelectionError, OSError, UnicodeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1

    if args.format == "json":
        print(
            json.dumps(
                {
                    "certificateSHA1": identity.sha1,
                    "commonName": identity.common_name,
                    "teamIdentifier": identity.team_identifier,
                },
                sort_keys=True,
            )
        )
    else:
        print(identity.sha1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
