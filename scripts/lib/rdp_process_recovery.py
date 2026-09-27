"""Darwin PID identity binding and external RDP XPC process recovery."""

from __future__ import annotations

import ctypes
import dataclasses
import errno
import os
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import Protocol

from .rdp_candidate_binding import VerificationError


@dataclasses.dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    executable_path: str
    uid: int
    start_seconds: int
    start_microseconds: int


@dataclasses.dataclass(frozen=True)
class ProcessNameObservation:
    """Read-only BSD process identity with an optional executable path."""

    pid: int
    uid: int
    start_seconds: int
    start_microseconds: int
    name: str
    executable_path: str | None


@dataclasses.dataclass(frozen=True)
class RecoveryObservation:
    app_before: ProcessIdentity
    helper_before: ProcessIdentity
    app_after: ProcessIdentity
    helper_after: ProcessIdentity


class ProcessInspector(Protocol):
    def identity(self, pid: int) -> ProcessIdentity | None: ...

    def identities_for_executable(
        self, executable: Path
    ) -> list[ProcessIdentity]: ...

    def identities_named(self, executable_name: str) -> list[ProcessIdentity]: ...

    def name_observations(
        self, executable_name: str
    ) -> list[ProcessNameObservation]: ...


class _ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


class DarwinProcessInspector:
    """Resolve executable and start identity through libproc, not name matching."""

    _PROC_PIDTBSDINFO = 3
    _PROC_PIDPATHINFO_MAXSIZE = 4096

    def __init__(self) -> None:
        if sys.platform != "darwin":
            raise VerificationError("Process verification requires macOS libproc.")
        self._libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self._libproc.proc_pidpath.argtypes = [
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_uint32,
        ]
        self._libproc.proc_pidpath.restype = ctypes.c_int
        self._libproc.proc_pidinfo.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        self._libproc.proc_pidinfo.restype = ctypes.c_int
        self._libproc.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
        self._libproc.proc_listallpids.restype = ctypes.c_int

    def identity(self, pid: int) -> ProcessIdentity | None:
        if pid <= 1:
            return None
        first_path = self._pid_path(pid)
        if first_path is None:
            return None

        info = self._bsd_info(pid)
        if info is None:
            return None

        second_path = self._pid_path(pid)
        if second_path is None:
            return None
        if first_path != second_path:
            raise VerificationError(
                f"PID {pid} changed executable identity during inspection."
            )
        return ProcessIdentity(
            pid=pid,
            executable_path=first_path,
            uid=int(info.pbi_uid),
            start_seconds=int(info.pbi_start_tvsec),
            start_microseconds=int(info.pbi_start_tvusec),
        )

    def identities_for_executable(
        self, executable: Path
    ) -> list[ProcessIdentity]:
        expected = str(executable)
        return [
            identity
            for identity in self._all_identities()
            if identity.executable_path == expected
        ]

    def identities_named(self, executable_name: str) -> list[ProcessIdentity]:
        return [
            identity
            for identity in self._all_identities()
            if Path(identity.executable_path).name == executable_name
        ]

    def name_observations(
        self, executable_name: str
    ) -> list[ProcessNameObservation]:
        """Return a stable raw-BSD-name snapshot, even when path lookup fails."""

        observations: list[ProcessNameObservation] = []
        for pid in self._all_pids():
            try:
                observation = self._name_observation(pid)
            except VerificationError:
                # A process may exit, exec, or become inaccessible while the
                # system-wide snapshot is assembled. An unstable observation
                # must never be returned as a bound process identity.
                continue
            if observation is not None and observation.name == executable_name:
                observations.append(observation)
        return sorted(observations, key=lambda item: item.pid)

    def _all_identities(self) -> list[ProcessIdentity]:
        identities: list[ProcessIdentity] = []
        for pid in self._all_pids():
            try:
                identity = self.identity(pid)
            except VerificationError:
                # Other users' and exiting processes are irrelevant here. The
                # two explicit candidate PIDs are checked without suppression.
                continue
            if identity is not None:
                identities.append(identity)
        return sorted(identities, key=lambda item: item.pid)

    def _name_observation(self, pid: int) -> ProcessNameObservation | None:
        if pid <= 1:
            return None
        before = self._bsd_info(pid)
        if before is None:
            return None

        first_path = self._pid_path(pid)
        after = self._bsd_info(pid)
        if after is None:
            return None
        before_identity = (
            int(before.pbi_pid),
            int(before.pbi_start_tvsec),
            int(before.pbi_start_tvusec),
        )
        after_identity = (
            int(after.pbi_pid),
            int(after.pbi_start_tvsec),
            int(after.pbi_start_tvusec),
        )
        if before_identity != after_identity:
            raise VerificationError(
                f"PID {pid} changed start identity during name inspection."
            )

        before_name = self._bsd_name(before)
        after_name = self._bsd_name(after)
        if before.pbi_uid != after.pbi_uid or before_name != after_name:
            raise VerificationError(
                f"PID {pid} changed BSD process metadata during name inspection."
            )
        second_path = self._pid_path(pid)
        executable_path = (
            first_path
            if first_path is not None
            and first_path != ""
            and first_path == second_path
            else None
        )
        return ProcessNameObservation(
            pid=pid,
            uid=int(after.pbi_uid),
            start_seconds=int(after.pbi_start_tvsec),
            start_microseconds=int(after.pbi_start_tvusec),
            name=after_name,
            executable_path=executable_path,
        )

    def _bsd_info(self, pid: int) -> _ProcBSDInfo | None:
        info = _ProcBSDInfo()
        size = ctypes.sizeof(info)
        ctypes.set_errno(0)
        result = self._libproc.proc_pidinfo(
            pid,
            self._PROC_PIDTBSDINFO,
            0,
            ctypes.byref(info),
            size,
        )
        if result == 0 and ctypes.get_errno() in (errno.ESRCH, errno.ENOENT):
            return None
        if result != size or info.pbi_pid != pid:
            raise VerificationError(
                f"Could not read a complete process identity for PID {pid}."
            )
        return info

    @staticmethod
    def _bsd_name(info: _ProcBSDInfo) -> str:
        raw_name = bytes(info.pbi_name).split(b"\0", 1)[0]
        if not raw_name:
            raw_name = bytes(info.pbi_comm).split(b"\0", 1)[0]
        return os.fsdecode(raw_name)

    def _pid_path(self, pid: int) -> str | None:
        buffer = ctypes.create_string_buffer(self._PROC_PIDPATHINFO_MAXSIZE)
        ctypes.set_errno(0)
        result = self._libproc.proc_pidpath(
            pid,
            ctypes.byref(buffer),
            len(buffer),
        )
        if result <= 0:
            error = ctypes.get_errno()
            if error in (
                0,
                errno.ESRCH,
                errno.ENOENT,
                errno.EPERM,
                errno.EACCES,
            ):
                return None
            raise VerificationError(
                f"proc_pidpath failed for PID {pid} with errno {error}."
            )
        path = os.fsdecode(buffer.value)
        return path or None

    def _all_pids(self) -> list[int]:
        requested = self._libproc.proc_listallpids(None, 0)
        if requested <= 0:
            raise VerificationError("Could not enumerate running processes.")
        capacity = requested + 128
        array_type = ctypes.c_int * capacity
        buffer = array_type()
        count = self._libproc.proc_listallpids(buffer, ctypes.sizeof(buffer))
        if count <= 0 or count >= capacity:
            raise VerificationError("Process enumeration was incomplete.")
        return [int(buffer[index]) for index in range(count) if buffer[index] > 1]


def verify_process_recovery(
    *,
    inspector: ProcessInspector,
    app_pid: int,
    helper_pid: int,
    app_executable: Path,
    helper_executable: Path,
    timeout_seconds: float,
    stability_seconds: float,
    terminate: Callable[[ProcessIdentity], None],
    verify_before_termination: Callable[
        [ProcessIdentity, ProcessIdentity], None
    ] | None = None,
    monotonic: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
    poll_interval: float = 0.2,
) -> RecoveryObservation:
    if app_pid <= 1 or helper_pid <= 1 or app_pid == helper_pid:
        raise VerificationError("App and helper PIDs must be distinct values above 1.")
    if timeout_seconds <= 0 or stability_seconds <= 0 or poll_interval <= 0:
        raise VerificationError("Recovery timing values must be positive.")

    expected_uid = os.getuid()
    app_before = _require_bound_process(
        inspector,
        app_pid,
        app_executable,
        expected_uid,
        description="main app",
    )
    helper_before = _require_bound_process(
        inspector,
        helper_pid,
        helper_executable,
        expected_uid,
        description="RDP XPC helper",
    )
    _require_unique_process(inspector, app_executable, app_before, "main app")
    _require_unique_process(
        inspector,
        helper_executable,
        helper_before,
        "RDP XPC helper",
    )
    _require_unique_process_name(
        inspector,
        app_executable.name,
        app_before,
        "JTS Terminal instance",
    )
    _require_unique_process_name(
        inspector,
        helper_executable.name,
        helper_before,
        "RDP XPC helper instance",
    )

    if verify_before_termination is not None:
        verify_before_termination(app_before, helper_before)

    # Signature verification may launch subprocesses. Re-read both start-time
    # identities after it, immediately before the sole process mutation.
    _require_same_process(inspector, app_before, "main app")
    _require_same_process(inspector, helper_before, "RDP XPC helper")
    terminate(helper_before)

    exit_deadline = monotonic() + timeout_seconds
    while monotonic() < exit_deadline:
        if inspector.identity(helper_pid) != helper_before:
            break
        _require_same_named_process(inspector, app_before, "main app")
        sleep(poll_interval)
    else:
        raise VerificationError("The verified helper did not exit before the deadline.")

    recovery_deadline = monotonic() + timeout_seconds
    helper_after: ProcessIdentity | None = None
    while monotonic() < recovery_deadline:
        _require_same_named_process(inspector, app_before, "main app")
        helpers = inspector.identities_for_executable(helper_executable)
        if len(helpers) > 1:
            raise VerificationError(
                "Multiple candidate helper processes appeared during recovery."
            )
        if helpers:
            candidate = helpers[0]
            if candidate.uid != expected_uid:
                raise VerificationError(
                    "The recovered helper runs under an unexpected user."
                )
            if candidate.pid == helper_before.pid:
                raise VerificationError("Recovery reused the terminated helper PID.")
            _require_unique_process_name(
                inspector,
                helper_executable.name,
                candidate,
                "replacement helper instance",
            )
            helper_after = candidate
            break
        sleep(poll_interval)
    if helper_after is None:
        raise VerificationError(
            "A replacement helper did not appear before the deadline."
        )

    stability_deadline = monotonic() + stability_seconds
    while monotonic() < stability_deadline:
        _require_same_named_process(inspector, app_before, "main app")
        _require_same_named_process(inspector, helper_after, "replacement helper")
        helpers = inspector.identities_for_executable(helper_executable)
        if helpers != [helper_after]:
            raise VerificationError(
                "The replacement helper was not the sole stable helper process."
            )
        remaining = max(0.0, stability_deadline - monotonic())
        if remaining > 0:
            sleep(min(poll_interval, remaining))

    app_after = _require_same_named_process(inspector, app_before, "main app")
    helper_after = _require_same_named_process(
        inspector,
        helper_after,
        "replacement helper",
    )
    return RecoveryObservation(
        app_before=app_before,
        helper_before=helper_before,
        app_after=app_after,
        helper_after=helper_after,
    )


def signal_process_if_identity_matches(
    inspector: ProcessInspector,
    expected: ProcessIdentity,
    signaler: Callable[[int], None],
) -> None:
    """Signal only if PID, path, UID, and start time still match."""

    _require_same_process(inspector, expected, "process selected for termination")
    signaler(expected.pid)


def _require_bound_process(
    inspector: ProcessInspector,
    pid: int,
    expected_executable: Path,
    expected_uid: int,
    *,
    description: str,
) -> ProcessIdentity:
    identity = inspector.identity(pid)
    if identity is None:
        raise VerificationError(f"The explicit {description} PID {pid} is not running.")
    if identity.executable_path != str(expected_executable):
        raise VerificationError(
            f"The explicit {description} PID {pid} is not executing the candidate path."
        )
    if identity.uid != expected_uid:
        raise VerificationError(f"The explicit {description} runs under another user.")
    return identity


def _require_unique_process(
    inspector: ProcessInspector,
    executable: Path,
    expected: ProcessIdentity,
    description: str,
) -> None:
    identities = inspector.identities_for_executable(executable)
    if identities != [expected]:
        pids = [identity.pid for identity in identities]
        raise VerificationError(
            f"Expected exactly one bound {description} process; found PIDs {pids}."
        )


def _require_unique_process_name(
    inspector: ProcessInspector,
    executable_name: str,
    expected: ProcessIdentity,
    description: str,
) -> None:
    identities = inspector.identities_named(executable_name)
    if identities != [expected]:
        pids = [identity.pid for identity in identities]
        raise VerificationError(
            f"Expected exactly one {description}; found PIDs {pids}."
        )


def _require_same_process(
    inspector: ProcessInspector,
    expected: ProcessIdentity,
    description: str,
) -> ProcessIdentity:
    current = inspector.identity(expected.pid)
    if current != expected:
        raise VerificationError(f"The {description} process identity changed.")
    return current


def _require_same_named_process(
    inspector: ProcessInspector,
    expected: ProcessIdentity,
    description: str,
) -> ProcessIdentity:
    current = _require_same_process(inspector, expected, description)
    _require_unique_process_name(
        inspector,
        Path(expected.executable_path).name,
        expected,
        description,
    )
    return current
