#!/usr/bin/env python3
"""Retain only the latest Debug and latest Release development apps."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

from lib.retained_build_products import (  # noqa: E402
    RetentionError,
    retain_latest_debug_and_release,
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "After a development compile, keep only the latest JTS Terminal "
            "Debug app and the latest Release app. Older development copies "
            "are unregistered and removed. Test hosts, App Store archives, "
            "and release-evidence are not search roots."
        )
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        required=True,
        help="Absolute JTS Terminal 2.0 worktree root.",
    )
    parser.add_argument(
        "--keep-app",
        type=Path,
        help="Absolute app just built; it becomes the retained product for its configuration.",
    )
    parser.add_argument(
        "--xcode-derived-data-root",
        type=Path,
        help="Override the Xcode DerivedData root used to find extra copies.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        result = retain_latest_debug_and_release(
            arguments.repo_root,
            keep_app=arguments.keep_app,
            xcode_derived_data_root=arguments.xcode_derived_data_root,
        )
    except (RetentionError, RuntimeError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1

    print("PASS: Retained only the latest Debug and latest Release development apps.")
    print(f"Kept Debug: {result.kept_debug or '(none)'}")
    print(f"Kept Release: {result.kept_release or '(none)'}")
    if result.removed:
        print("Removed:")
        for path in result.removed:
            print(f"  {path}")
    else:
        print("Removed: (none)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
