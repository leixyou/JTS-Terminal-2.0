#!/usr/bin/env python3
"""Run one command with a process-group hard timeout."""

from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time


TIMEOUT_EXIT_CODE = 124
TERMINATION_GRACE_SECONDS = 5.0


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    """Terminate the complete child process group, escalating to SIGKILL."""

    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return

    try:
        process.wait(timeout=TERMINATION_GRACE_SECONDS)
        return
    except subprocess.TimeoutExpired:
        pass

    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    process.wait()


def run(command: list[str], *, timeout_seconds: float) -> int:
    if not command or timeout_seconds <= 0:
        raise ValueError("A command and a positive timeout are required.")

    process = subprocess.Popen(command, start_new_session=True)
    deadline = time.monotonic() + timeout_seconds
    try:
        while True:
            return_code = process.poll()
            if return_code is not None:
                return return_code
            if time.monotonic() >= deadline:
                terminate_process_group(process)
                print("Command exceeded the formal smoke hard timeout.", file=sys.stderr)
                return TIMEOUT_EXIT_CODE
            time.sleep(min(0.1, max(deadline - time.monotonic(), 0.0)))
    except KeyboardInterrupt:
        terminate_process_group(process)
        return 130


def parse_arguments(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run a command and kill its full process group on timeout."
    )
    parser.add_argument("--seconds", required=True, type=float)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    parsed = parser.parse_args(arguments)
    if parsed.command[:1] == ["--"]:
        parsed.command = parsed.command[1:]
    if parsed.seconds <= 0 or not parsed.command:
        parser.error("--seconds must be positive and a command is required")
    return parsed


def main(arguments: list[str]) -> int:
    parsed = parse_arguments(arguments)
    return run(parsed.command, timeout_seconds=parsed.seconds)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
