#!/usr/bin/env python3
"""Prepare or verify only DerivedData/Run's daily Debug application."""

import argparse
from pathlib import Path
import sys

from lib.debug_runtime_signing import DebugRuntimeError, DebugRuntimeSigning


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--prepare-build", action="store_true")
    args = parser.parse_args()
    try:
        runtime = DebugRuntimeSigning(args.repo_root)
        if args.prepare_build:
            quarantined = runtime.prepare_build()
            if quarantined:
                print(f"Moved cached test host to recoverable quarantine: {quarantined}")
        else:
            changed = runtime.finalize()
            print(f"Daily Debug app and both helper signatures verified; repaired {len(changed)} signatures.")
    except (DebugRuntimeError, OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
