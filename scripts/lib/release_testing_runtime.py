"""Install an immutable Release-testing candidate at one stable physical path."""

from __future__ import annotations

import ctypes
import dataclasses
import datetime as dt
import enum
import errno
import fcntl
import hashlib
import json
import os
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from collections.abc import Callable, Mapping
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator, Protocol

from .apple_development_profile import (
    DevelopmentProfileError,
    DevelopmentProfileIdentity,
    current_mac_provisioning_identifier,
    validate_development_profile,
)
from .private_evidence import build_bundle_manifest, sha256_file
from .rdp_candidate_binding import (
    APPLE_DEVELOPMENT_AUTHORITY_PREFIX,
    EXPECTED_APP_IDENTIFIER,
    EXPECTED_BUILD_NUMBER,
    EXPECTED_HELPER_IDENTIFIER,
    EXPECTED_MARKETING_VERSION,
    VerificationError,
    normalize_cdhash,
    normalize_sha256,
    parse_signature_identity,
    read_bundle_entitlements,
    reject_symlink_components,
    resolve_runtime_paths,
    verify_runtime_signatures,
    verify_runtime_source_identity,
)
from .rdp_process_recovery import (
    DarwinProcessInspector,
    ProcessIdentity,
    ProcessNameObservation,
)


EXPECTED_TEAM_IDENTIFIER = "YOURTEAMID"
EXPECTED_SCHEME = "JTSTerminalRDP2"
EXPECTED_CONFIGURATION = "Release"
EXPECTED_RECORD_VERSION = "jts-release-testing-candidate.v1"
RUNTIME_RECORD_VERSION = "jts-release-testing-runtime.v1"
APP_NAME = "JTS Terminal.app"
APP_EXECUTABLE_NAME = "JTS Terminal"
XPC_EXECUTABLE_NAME = "JTFreeRDPService"
RETIRED_APP_QUARANTINE_NAME = "Retired JTS Terminal.quarantine"
METADATA_NAME = "candidate-metadata.json"
MANIFEST_NAME = "runtime-manifest.json"
RUNTIME_METADATA_NAME = "current-runtime.json"
ASKPASS_IDENTIFIER = "com.lljts.JTSTerminal.SSHAskpass"
ASKPASS_RELATIVE_PATH = Path("Contents/MacOS/JTSSHAskpass")
ASKPASS_EXECUTABLE_NAME = ASKPASS_RELATIVE_PATH.name
LSREGISTER = Path(
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    "LaunchServices.framework/Support/lsregister"
)
MAX_METADATA_BYTES = 1024 * 1024
MAX_MANIFEST_BYTES = 32 * 1024 * 1024
LS_APPLICATION_NOT_FOUND_ERROR = -10814


class RuntimeInstallError(RuntimeError):
    """A fail-closed stable runtime installation error."""


@dataclasses.dataclass(frozen=True)
class ComponentBinding:
    cdhash: str
    executable_sha256: str
    leaf_certificate_sha1: str


class _IdentityContract(enum.Enum):
    CURRENT_PROFILED = "current-profiled"
    LEGACY_PROFILELESS_RETIREMENT = "legacy-profileless-retirement"


@dataclasses.dataclass(frozen=True)
class CandidateBinding:
    metadata_path: Path
    manifest_path: Path
    artifact_app: Path
    source_commit: str
    source_snapshot_sha256: str
    runtime_manifest_sha256: str
    signing_certificate_sha1: str
    identity_contract: _IdentityContract
    development_profile: DevelopmentProfileIdentity | None
    signatures: Mapping[str, ComponentBinding]
    metadata_sha256: str
    manifest: Mapping[str, object]


@dataclasses.dataclass(frozen=True)
class InstallResult:
    runtime_app: Path
    runtime_metadata: Path
    replaced_existing_runtime: bool
    launched: bool


class ProcessInspector(Protocol):
    def identity(self, pid: int) -> ProcessIdentity | None: ...

    def identities_for_executable(
        self, executable: Path
    ) -> list[ProcessIdentity]: ...

    def identities_named(
        self, executable_name: str
    ) -> list[ProcessIdentity]: ...

    def name_observations(
        self, executable_name: str
    ) -> list[ProcessNameObservation]: ...


CommandRunner = Callable[..., subprocess.CompletedProcess[Any]]
DirectoryExchange = Callable[[Path, Path], None]
RuntimeAction = Callable[[Path], None]
ProcessTerminator = Callable[[ProcessIdentity], None]


def default_runtime_root(home: Path | None = None) -> Path:
    base = Path.home() if home is None else home
    return (
        base
        / "Library"
        / "Application Support"
        / "JTS Terminal"
        / "ReleaseTestingRuntime"
    )


def validate_stable_runtime_root(runtime_root: Path, *, home: Path) -> Path:
    """Require the one stable, user-owned runtime location."""

    _require_absolute_normalized(home, "Home directory")
    _require_absolute_normalized(runtime_root, "Runtime root")
    try:
        canonical_home = home.resolve(strict=True)
    except OSError as error:
        raise RuntimeInstallError(f"Home directory is unavailable: {error}") from error
    if canonical_home != home:
        raise RuntimeInstallError("Home directory must be canonical and not an alias.")
    _require_owner_controlled_directory(home, exact_private=False)
    expected = default_runtime_root(home)
    if runtime_root != expected:
        raise RuntimeInstallError(
            f"Runtime root must be the stable Release-testing path: {expected}"
        )
    if _is_within(runtime_root, Path("/Applications")):
        raise RuntimeInstallError("Release-testing runtime must never use /Applications.")
    reject_symlink_components(runtime_root)
    return runtime_root


def prepare_runtime_parent(runtime_root: Path, *, home: Path) -> Path:
    """Create only missing owner-private components below the canonical home."""

    validate_stable_runtime_root(runtime_root, home=home)
    parent = runtime_root.parent
    current = home
    for part in parent.relative_to(home).parts:
        current /= part
        if current.exists() or current.is_symlink():
            reject_symlink_components(current)
            _require_owner_controlled_directory(current, exact_private=False)
            continue
        previous_umask = os.umask(0o077)
        try:
            current.mkdir(mode=0o700)
        finally:
            os.umask(previous_umask)
        _require_owner_controlled_directory(current, exact_private=True)
    if runtime_root.exists() or runtime_root.is_symlink():
        reject_symlink_components(runtime_root)
        _require_owner_controlled_directory(runtime_root, exact_private=True)
    return parent


def load_and_verify_candidate(
    metadata_path: Path,
    *,
    runner: CommandRunner = subprocess.run,
) -> CandidateBinding:
    """Strictly bind a current profiled candidate and all signed components."""

    return _load_and_verify_candidate(
        metadata_path,
        runner=runner,
        allow_legacy_profileless_retirement=False,
    )


def _load_and_verify_existing_runtime_artifact(
    metadata_path: Path,
    *,
    runner: CommandRunner,
) -> CandidateBinding:
    """Validate a bound artifact solely to retire an existing managed runtime."""

    return _load_and_verify_candidate(
        metadata_path,
        runner=runner,
        allow_legacy_profileless_retirement=True,
    )


def _load_and_verify_candidate(
    metadata_path: Path,
    *,
    runner: CommandRunner,
    allow_legacy_profileless_retirement: bool,
) -> CandidateBinding:
    """Bind metadata, manifest, provenance, binaries, and signatures."""

    metadata_path = _require_private_regular_json(
        metadata_path,
        description="Candidate metadata",
        maximum_size=MAX_METADATA_BYTES,
    )
    if metadata_path.name != METADATA_NAME:
        raise RuntimeInstallError(f"Candidate metadata must be named {METADATA_NAME}.")
    candidate_directory = metadata_path.parent
    _require_owner_controlled_directory(candidate_directory, exact_private=False)
    manifest_path = _require_private_regular_json(
        candidate_directory / MANIFEST_NAME,
        description="Runtime manifest",
        maximum_size=MAX_MANIFEST_BYTES,
    )
    metadata = _load_strict_json(metadata_path)
    manifest = _load_strict_json(manifest_path)
    if not isinstance(metadata, dict):
        raise RuntimeInstallError("Candidate metadata must be a JSON object.")
    if not isinstance(manifest, dict):
        raise RuntimeInstallError("Runtime manifest must be a JSON object.")

    binding = _parse_candidate_binding(
        metadata,
        metadata_path=metadata_path,
        manifest_path=manifest_path,
        manifest=manifest,
        allow_legacy_profileless_retirement=(
            allow_legacy_profileless_retirement
        ),
    )
    verify_candidate_bundle(binding, binding.artifact_app, runner=runner)
    return binding


def verify_candidate_bundle(
    binding: CandidateBinding,
    bundle: Path,
    *,
    runner: CommandRunner = subprocess.run,
) -> None:
    """Verify one physical copy against the immutable candidate binding."""

    paths = resolve_runtime_paths(bundle)
    askpass = bundle / ASKPASS_RELATIVE_PATH
    _require_regular_executable(askpass, description="SSH askpass executable")

    actual_manifest = build_bundle_manifest(bundle)
    _verify_manifest_entries(binding.manifest, actual_manifest)

    app_and_helper = verify_runtime_signatures(
        paths,
        EXPECTED_TEAM_IDENTIFIER,
        binding.signatures["app"].cdhash,
    )
    if app_and_helper["helper"].cdhash != binding.signatures["rdpXPC"].cdhash:
        raise RuntimeInstallError("RDP XPC helper CDHash does not match metadata.")
    askpass_signature = _verify_signed_component(
        askpass,
        expected_identifier=ASKPASS_IDENTIFIER,
        expected_team_identifier=EXPECTED_TEAM_IDENTIFIER,
        runner=runner,
    )
    if askpass_signature.cdhash != binding.signatures["sshAskpass"].cdhash:
        raise RuntimeInstallError("SSH askpass CDHash does not match metadata.")

    verify_runtime_source_identity(
        paths,
        expected_source_commit=binding.source_commit,
        expected_source_snapshot_sha256=binding.source_snapshot_sha256,
    )
    component_paths = {
        "app": paths.app_executable,
        "rdpXPC": paths.helper_executable,
        "sshAskpass": askpass,
    }
    for role, executable in component_paths.items():
        actual_sha256 = sha256_file(executable)
        if actual_sha256 != binding.signatures[role].executable_sha256:
            raise RuntimeInstallError(
                f"{role} executable SHA-256 does not match candidate metadata."
            )
        actual_leaf = _leaf_certificate_sha1(executable, runner=runner)
        expected = binding.signatures[role].leaf_certificate_sha1
        if actual_leaf != expected or actual_leaf != binding.signing_certificate_sha1:
            raise RuntimeInstallError(
                f"{role} signing leaf certificate does not match candidate metadata."
            )

    _verify_release_testing_identity(
        binding,
        bundle,
        paths.helper_bundle,
        askpass,
        runner=runner,
    )

    actual_architectures = _read_architectures(paths.app_executable, runner=runner)
    if actual_architectures != {"arm64", "x86_64"}:
        raise RuntimeInstallError(
            "Release-testing app is not an arm64/x86_64 Universal binary."
        )


def _verify_release_testing_identity(
    binding: CandidateBinding,
    app: Path,
    helper: Path,
    askpass: Path,
    *,
    runner: CommandRunner,
) -> None:
    if (
        binding.identity_contract
        is _IdentityContract.LEGACY_PROFILELESS_RETIREMENT
    ):
        if binding.development_profile is not None:
            raise RuntimeInstallError(
                "Legacy Release-testing identity has unexpected profile metadata."
            )
        expected_app_entitlements = {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.files.bookmarks.app-scope": True,
            "com.apple.security.files.user-selected.read-write": True,
            "com.apple.security.network.client": True,
            "com.apple.security.network.server": True,
        }
    else:
        if binding.development_profile is None:
            raise RuntimeInstallError(
                "Current Release-testing identity has no profile metadata."
            )
        expected_app_entitlements = {
            "com.apple.application-identifier": (
                f"{EXPECTED_TEAM_IDENTIFIER}.{EXPECTED_APP_IDENTIFIER}"
            ),
            "com.apple.developer.team-identifier": EXPECTED_TEAM_IDENTIFIER,
            "com.apple.security.app-sandbox": True,
            "com.apple.security.files.bookmarks.app-scope": True,
            "com.apple.security.files.user-selected.read-write": True,
            "com.apple.security.get-task-allow": True,
            "com.apple.security.files.downloads.read-write": True,
            "com.apple.security.assets.pictures.read-write": True,
            "com.apple.security.assets.music.read-write": True,
            "com.apple.security.assets.movies.read-write": True,
            "com.apple.security.network.client": True,
            "com.apple.security.network.server": True,
        }
    expected_entitlements = {
        "app": expected_app_entitlements,
        "rdpXPC": {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.network.client": True,
        },
        "sshAskpass": {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.inherit": True,
        },
    }
    try:
        actual_entitlements = {
            "app": read_bundle_entitlements(app, runner=runner),
            "rdpXPC": read_bundle_entitlements(helper, runner=runner),
            "sshAskpass": read_bundle_entitlements(askpass, runner=runner),
        }
    except VerificationError as error:
        raise RuntimeInstallError(str(error)) from error
    for role, expected in expected_entitlements.items():
        if actual_entitlements[role] != expected:
            raise RuntimeInstallError(
                f"{role} signed entitlements do not match the Release-testing identity contract."
            )

    profile = app / "Contents/embedded.provisionprofile"
    if (
        binding.identity_contract
        is _IdentityContract.LEGACY_PROFILELESS_RETIREMENT
    ):
        if profile.exists() or profile.is_symlink():
            raise RuntimeInstallError(
                "Legacy Release-testing identity unexpectedly embeds a profile."
            )
        return
    if not profile.is_file() or profile.is_symlink():
        raise RuntimeInstallError(
            "Release-testing app has no regular embedded Apple Development profile."
        )
    decoded = runner(
        ["/usr/bin/security", "cms", "-D", "-i", str(profile)],
        text=False,
        capture_output=True,
        check=False,
    )
    if decoded.returncode != 0:
        raise RuntimeInstallError(
            "Embedded Apple Development profile could not be decoded."
        )
    try:
        current_device = current_mac_provisioning_identifier(runner=runner)
        actual_profile = validate_development_profile(
            decoded.stdout,
            expected_team_identifier=EXPECTED_TEAM_IDENTIFIER,
            expected_bundle_identifier=EXPECTED_APP_IDENTIFIER,
            expected_certificate_sha1=binding.signing_certificate_sha1,
            current_device_identifier=current_device,
        )
    except DevelopmentProfileError as error:
        raise RuntimeInstallError(
            f"Embedded Apple Development profile is invalid: {error}"
        ) from error
    if actual_profile != binding.development_profile:
        raise RuntimeInstallError(
            "Embedded Apple Development profile does not match candidate metadata."
        )


def assert_runtime_not_running(
    runtime_app: Path,
    *,
    inspector: ProcessInspector | None = None,
) -> None:
    """Reject replacement while a bound app, XPC, or askpass process is running."""

    active_inspector = DarwinProcessInspector() if inspector is None else inspector
    executable_paths = _runtime_executable_paths(runtime_app)
    running = [
        identity
        for executable in executable_paths
        for identity in active_inspector.identities_for_executable(executable)
    ]
    if running:
        details = ", ".join(
            f"PID {identity.pid} ({identity.executable_path})"
            for identity in sorted(running, key=lambda item: item.pid)
        )
        raise RuntimeInstallError(
            "Stable Release-testing runtime is still running; quit its main app "
            f"plus XPC/askpass helpers before replacing it: {details}"
        )


def assert_no_conflicting_bundle_instances(
    stable_app: Path,
    *,
    inspector: ProcessInspector | None = None,
) -> None:
    """Reject another current-user JTS main process outside the stable identity.

    Raw BSD process names keep unlinked/pathless executables visible. When a
    path is available, the outer app's bundle identifier distinguishes JTS from
    an unrelated executable with the same name. Stable-path cardinality is left
    to the exact post-activation state validator.
    """

    active_inspector = DarwinProcessInspector() if inspector is None else inspector
    conflicts: list[tuple[ProcessNameObservation, Path | None]] = []
    for observation in active_inspector.name_observations(APP_EXECUTABLE_NAME):
        if observation.uid != os.getuid():
            continue
        if observation.executable_path is None:
            conflicts.append((observation, None))
            continue
        identity = ProcessIdentity(
            pid=observation.pid,
            executable_path=observation.executable_path,
            uid=observation.uid,
            start_seconds=observation.start_seconds,
            start_microseconds=observation.start_microseconds,
        )
        app = _main_app_bundle_for_process(identity)
        if app is None or _same_physical_or_lexical_path(app, stable_app):
            continue
        if _read_running_app_bundle_identifier(app) != EXPECTED_APP_IDENTIFIER:
            continue
        conflicts.append((observation, app))

    if not conflicts:
        return

    details = ", ".join(
        (
            f"PID {observation.pid} ({app})"
            if app is not None
            else f"PID {observation.pid} (executable path unavailable)"
        )
        for observation, app in sorted(conflicts, key=lambda item: item[0].pid)
    )
    raise RuntimeInstallError(
        "Another current-user JTS Terminal main process is running outside the "
        "verified stable identity, or its executable path is unavailable. Quit "
        "it manually before installing or launching; no process was terminated: "
        f"{details}"
    )


def assert_no_conflicting_xpc_instances(
    stable_app: Path,
    *,
    inspector: ProcessInspector | None = None,
) -> None:
    """Reject a current-user RDP helper running outside the stable app."""

    active_inspector = DarwinProcessInspector() if inspector is None else inspector
    stable_helper = _runtime_executable_paths(stable_app)[1]
    conflicts = [
        observation
        for observation in active_inspector.name_observations(
            XPC_EXECUTABLE_NAME
        )
        if observation.uid == os.getuid()
        and (
            observation.executable_path is None
            or not _same_physical_or_lexical_path(
                Path(observation.executable_path),
                stable_helper,
            )
        )
    ]
    if not conflicts:
        return
    details = ", ".join(
        (
            f"PID {observation.pid} ({observation.executable_path})"
            if observation.executable_path is not None
            else f"PID {observation.pid} (executable path unavailable)"
        )
        for observation in sorted(conflicts, key=lambda item: item.pid)
    )
    raise RuntimeInstallError(
        f"Another current-user {XPC_EXECUTABLE_NAME} process is running outside "
        "the stable Release-testing path. Quit the owning JTS Terminal instance "
        f"before installing or launching; no process was terminated: {details}"
    )


def assert_no_conflicting_askpass_instances(
    stable_app: Path,
    *,
    inspector: ProcessInspector | None = None,
) -> None:
    """Reject a current-user askpass helper outside the stable app."""

    active_inspector = DarwinProcessInspector() if inspector is None else inspector
    stable_askpass = _runtime_executable_paths(stable_app)[2]
    conflicts = [
        observation
        for observation in active_inspector.name_observations(
            ASKPASS_EXECUTABLE_NAME
        )
        if observation.uid == os.getuid()
        and (
            observation.executable_path is None
            or not _same_physical_or_lexical_path(
                Path(observation.executable_path),
                stable_askpass,
            )
        )
    ]
    if not conflicts:
        return
    details = ", ".join(
        (
            f"PID {observation.pid} ({observation.executable_path})"
            if observation.executable_path is not None
            else f"PID {observation.pid} (executable path unavailable)"
        )
        for observation in sorted(conflicts, key=lambda item: item.pid)
    )
    raise RuntimeInstallError(
        f"Another current-user {ASKPASS_EXECUTABLE_NAME} process is running "
        "outside the stable Release-testing path. Wait for it to exit or quit "
        "the owning JTS Terminal instance before installing or launching; no "
        f"process was terminated: {details}"
    )


def _assert_no_conflicting_runtime_instances(
    stable_app: Path,
    *,
    inspector: ProcessInspector | None,
) -> None:
    assert_no_conflicting_bundle_instances(stable_app, inspector=inspector)
    assert_no_conflicting_xpc_instances(stable_app, inspector=inspector)
    assert_no_conflicting_askpass_instances(stable_app, inspector=inspector)


def _assert_post_activation_runtime_state(
    stable_app: Path,
    *,
    launch_expected: bool,
    inspector: ProcessInspector | None,
) -> None:
    """Prove the exact stable-path process cardinality before reporting success."""

    active_inspector = DarwinProcessInspector() if inspector is None else inspector
    main, xpc, askpass = _runtime_executable_paths(stable_app)
    main_identities = active_inspector.identities_for_executable(main)
    if launch_expected:
        if (
            len(main_identities) != 1
            or not _is_exact_current_user_process(main_identities[0], main)
        ):
            raise RuntimeInstallError(
                "Launched stable runtime must have exactly one verified "
                f"current-user main process; observed {len(main_identities)}."
            )
    elif main_identities:
        raise RuntimeInstallError(
            "Non-launched stable runtime unexpectedly has "
            f"{len(main_identities)} main process(es)."
        )

    xpc_identities = active_inspector.identities_for_executable(xpc)
    if (
        (not launch_expected and xpc_identities)
        or len(xpc_identities) > 1
        or any(
            not _is_exact_current_user_process(identity, xpc)
            for identity in xpc_identities
        )
    ):
        raise RuntimeInstallError(
            "Stable runtime has an invalid RDP XPC process cardinality: "
            f"{len(xpc_identities)}."
        )

    askpass_identities = active_inspector.identities_for_executable(askpass)
    if askpass_identities:
        raise RuntimeInstallError(
            "Stable runtime unexpectedly has an active SSH askpass process: "
            f"{len(askpass_identities)}."
        )
    _assert_no_conflicting_runtime_instances(
        stable_app,
        inspector=active_inspector,
    )


def _assert_runtime_ready_for_activation(
    runtime_app: Path,
    *,
    inspector: ProcessInspector | None,
) -> None:
    _assert_no_conflicting_runtime_instances(runtime_app, inspector=inspector)
    assert_runtime_not_running(runtime_app, inspector=inspector)


def _assert_idle_and_unregister_candidate(
    candidate_app: Path,
    *,
    inspector: ProcessInspector | None,
    unregistrar: RuntimeAction,
) -> None:
    """Never unregister or copy a candidate whose exact processes are active."""

    assert_runtime_not_running(candidate_app, inspector=inspector)
    unregistrar(candidate_app)


def _assert_idle_and_unregister_bound_artifacts(
    bindings: tuple[CandidateBinding, ...],
    *,
    inspector: ProcessInspector | None,
    unregistrar: RuntimeAction,
) -> None:
    """Retire every distinct immutable artifact bound to this upgrade."""

    seen: set[Path] = set()
    for binding in bindings:
        candidate_app = binding.artifact_app
        if candidate_app in seen:
            continue
        seen.add(candidate_app)
        _assert_idle_and_unregister_candidate(
            candidate_app,
            inspector=inspector,
            unregistrar=unregistrar,
        )


def install_release_testing_runtime(
    metadata_path: Path,
    *,
    launch: bool,
    home: Path | None = None,
    inspector: ProcessInspector | None = None,
    runner: CommandRunner = subprocess.run,
    exchange: DirectoryExchange | None = None,
    registrar: RuntimeAction | None = None,
    unregistrar: RuntimeAction | None = None,
    launcher: RuntimeAction | None = None,
) -> InstallResult:
    """Validate, physically copy, and atomically publish one stable runtime."""

    selected_home = Path.home() if home is None else home
    runtime_root = default_runtime_root(selected_home)
    prepare_runtime_parent(runtime_root, home=selected_home)
    with runtime_install_lock(runtime_root.parent):
        return _install_release_testing_runtime_locked(
            metadata_path,
            launch=launch,
            runtime_root=runtime_root,
            inspector=inspector,
            runner=runner,
            exchange=exchange,
            registrar=registrar,
            unregistrar=unregistrar,
            launcher=launcher,
        )


def _install_release_testing_runtime_locked(
    metadata_path: Path,
    *,
    launch: bool,
    runtime_root: Path,
    inspector: ProcessInspector | None,
    runner: CommandRunner,
    exchange: DirectoryExchange | None,
    registrar: RuntimeAction | None,
    unregistrar: RuntimeAction | None,
    launcher: RuntimeAction | None,
) -> InstallResult:
    _assert_no_staging_residue(runtime_root)
    stable_app = runtime_root / APP_NAME
    _assert_runtime_ready_for_activation(stable_app, inspector=inspector)
    existing_binding: CandidateBinding | None = None
    if runtime_root.exists():
        existing_binding = _validate_existing_managed_runtime(
            runtime_root,
            runner=runner,
        )

    binding = load_and_verify_candidate(metadata_path, runner=runner)
    if binding.artifact_app == stable_app:
        raise RuntimeInstallError(
            "Immutable candidate and stable runtime paths must be different."
        )
    selected_unregistrar = unregistrar or (
        lambda app: unregister_runtime(app, runner=runner)
    )
    bound_artifacts = tuple(
        item
        for item in (existing_binding, binding)
        if item is not None
    )
    _assert_idle_and_unregister_bound_artifacts(
        bound_artifacts,
        inspector=inspector,
        unregistrar=selected_unregistrar,
    )

    staging = runtime_root.parent / (
        f".{runtime_root.name}.staged-{uuid.uuid4().hex}"
    )
    if staging.exists() or staging.is_symlink():
        raise RuntimeInstallError("Private runtime staging path unexpectedly exists.")
    previous_umask = os.umask(0o077)
    try:
        staging.mkdir(mode=0o700)
    finally:
        os.umask(previous_umask)

    publication_started = False
    try:
        staged_app = staging / APP_NAME
        _copy_physical_app(binding.artifact_app, staged_app, runner=runner)
        verify_candidate_bundle(binding, staged_app, runner=runner)
        _write_runtime_record(
            staging / RUNTIME_METADATA_NAME,
            binding=binding,
            stable_app=stable_app,
        )
        _require_owner_controlled_directory(staging, exact_private=True)
        _fsync_directory(staging)

        # Re-read the immutable source immediately before publication so a
        # concurrent candidate change cannot be installed under stale metadata.
        rebound = load_and_verify_candidate(metadata_path, runner=runner)
        if rebound != binding:
            raise RuntimeInstallError(
                "Immutable candidate binding changed during runtime installation."
            )
        _assert_idle_and_unregister_bound_artifacts(
            bound_artifacts,
            inspector=inspector,
            unregistrar=selected_unregistrar,
        )
        _assert_runtime_ready_for_activation(stable_app, inspector=inspector)

        selected_registrar = registrar or (
            lambda app: register_stable_runtime(app, runner=runner)
        )
        selected_launcher = launcher or (
            lambda app: launch_stable_runtime(
                app,
                inspector=inspector,
                runner=runner,
            )
        )
        publication_started = True
        return _publish_staged_runtime(
            staging,
            runtime_root,
            launch=launch,
            exchange=exchange or exchange_directories,
            registrar=selected_registrar,
            unregistrar=selected_unregistrar,
            launcher=selected_launcher,
            pre_activation_validator=lambda app: _assert_runtime_ready_for_activation(
                app,
                inspector=inspector,
            ),
            pre_rollback_validator=lambda app: assert_runtime_not_running(
                app,
                inspector=inspector,
            ),
            staging_idle_validator=lambda app: assert_runtime_not_running(
                app,
                inspector=inspector,
            ),
            post_activation_validator=lambda app: (
                _assert_post_activation_runtime_state(
                    app,
                    launch_expected=launch,
                    inspector=inspector,
                )
            ),
        )
    except BaseException:
        if (
            not publication_started
            and staging.exists()
            and not staging.is_symlink()
        ):
            shutil.rmtree(staging, ignore_errors=True)
        raise


def _assert_no_staging_residue(runtime_root: Path) -> None:
    """Reject leftovers whose identity and process state need manual recovery."""

    prefix = f".{runtime_root.name}.staged-"
    residues = sorted(
        (
            entry
            for entry in runtime_root.parent.iterdir()
            if entry.name.startswith(prefix)
        ),
        key=lambda entry: entry.name,
    )
    if not residues:
        return
    details = ", ".join(str(entry) for entry in residues)
    raise RuntimeInstallError(
        "A previous Release-testing runtime installation left staging residue. "
        "Verify that its main app, XPC, and askpass helpers are stopped, then "
        "remove or preserve it for diagnosis before retrying; nothing was "
        f"deleted: {details}"
    )


@contextmanager
def runtime_install_lock(parent: Path) -> Iterator[None]:
    """Serialize publication without trusting or deleting a competing lock."""

    lock_path = parent / ".release-testing-runtime.install.lock"
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(lock_path, flags, 0o600)
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_nlink != 1
            or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise RuntimeInstallError(
                "Stable runtime installation lock is not owner-only."
            )
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeInstallError(
                "Another stable runtime installation is already in progress."
            ) from error
        yield
    finally:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        finally:
            os.close(descriptor)


def exchange_directories(first: Path, second: Path) -> None:
    """Atomically exchange two same-filesystem directories on macOS."""

    if sys.platform != "darwin":
        raise RuntimeInstallError("Atomic runtime replacement requires macOS.")
    libc = ctypes.CDLL(None, use_errno=True)
    renameatx_np = libc.renameatx_np
    renameatx_np.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameatx_np.restype = ctypes.c_int
    at_fdcwd = -2
    rename_swap = 0x00000002
    ctypes.set_errno(0)
    result = renameatx_np(
        at_fdcwd,
        os.fsencode(first),
        at_fdcwd,
        os.fsencode(second),
        rename_swap,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise RuntimeInstallError(
            f"Could not atomically exchange runtime directories: "
            f"{os.strerror(error or errno.EIO)}"
        )


def rename_directory_no_replace(source: Path, destination: Path) -> None:
    """Atomically publish one directory only when the destination is absent."""

    if sys.platform != "darwin":
        raise RuntimeInstallError("Atomic no-replace publication requires macOS.")
    libc = ctypes.CDLL(None, use_errno=True)
    renameatx_np = libc.renameatx_np
    renameatx_np.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameatx_np.restype = ctypes.c_int
    at_fdcwd = -2
    rename_excl = 0x00000004
    ctypes.set_errno(0)
    result = renameatx_np(
        at_fdcwd,
        os.fsencode(source),
        at_fdcwd,
        os.fsencode(destination),
        rename_excl,
    )
    if result != 0:
        error = ctypes.get_errno() or errno.EIO
        if error in (errno.EEXIST, errno.ENOTEMPTY):
            raise RuntimeInstallError(
                f"Refusing to replace an existing publication: {destination}"
            )
        raise RuntimeInstallError(
            "Could not atomically publish the directory without replacement: "
            f"{os.strerror(error)}"
        )


def register_stable_runtime(
    runtime_app: Path,
    *,
    runner: CommandRunner = subprocess.run,
) -> None:
    result = runner(
        [str(LSREGISTER), "-f", str(runtime_app)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeInstallError(
            "LaunchServices registration failed for the exact stable runtime: "
            f"{_bounded_output(result.stderr)}"
        )


def unregister_runtime(
    runtime_app: Path,
    *,
    runner: CommandRunner = subprocess.run,
) -> None:
    if (
        not runtime_app.is_absolute()
        or runtime_app.is_symlink()
        or not runtime_app.is_dir()
    ):
        raise RuntimeInstallError(
            "LaunchServices unregistration requires an existing absolute "
            "physical app bundle."
        )
    result = runner(
        [str(LSREGISTER), "-u", str(runtime_app)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0 and not _is_launch_services_not_registered(result):
        raise RuntimeInstallError(
            "LaunchServices unregistration failed for the exact runtime: "
            f"{_bounded_output(result.stderr)}"
        )


def _is_launch_services_not_registered(
    result: subprocess.CompletedProcess[Any],
) -> bool:
    """Treat only LaunchServices' stable not-found OSStatus as idempotent."""

    output = "\n".join(
        part
        for part in (
            result.stdout if isinstance(result.stdout, str) else "",
            result.stderr if isinstance(result.stderr, str) else "",
        )
        if part
    )
    return re.search(
        rf"(?<!\d){LS_APPLICATION_NOT_FOUND_ERROR}(?!\d)",
        output,
    ) is not None


def launch_stable_runtime(
    runtime_app: Path,
    *,
    inspector: ProcessInspector | None = None,
    runner: CommandRunner = subprocess.run,
    launch_timeout_seconds: float = 5.0,
    termination_timeout_seconds: float = 5.0,
    terminator: ProcessTerminator | None = None,
) -> None:
    active_inspector = DarwinProcessInspector() if inspector is None else inspector
    selected_terminator = terminator or (
        lambda identity: _terminate_bound_process(
            identity,
            inspector=active_inspector,
        )
    )
    _assert_no_conflicting_runtime_instances(
        runtime_app,
        inspector=active_inspector,
    )
    assert_runtime_not_running(runtime_app, inspector=active_inspector)
    result = runner(
        ["/usr/bin/open", "-n", str(runtime_app)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        _raise_after_failed_launch_cleanup(
            runtime_app,
            reason=(
                "Could not launch the exact stable runtime: "
                f"{_bounded_output(result.stderr)}"
            ),
            inspector=active_inspector,
            terminator=selected_terminator,
            termination_timeout_seconds=termination_timeout_seconds,
        )
    executable = _runtime_executable_paths(runtime_app)[0]
    deadline = time.monotonic() + max(0.25, launch_timeout_seconds)
    identities: list[ProcessIdentity] = []
    while time.monotonic() < deadline:
        identities = active_inspector.identities_for_executable(executable)
        if len(identities) == 1 and _is_exact_current_user_process(
            identities[0],
            executable,
        ):
            try:
                _assert_no_conflicting_runtime_instances(
                    runtime_app,
                    inspector=active_inspector,
                )
            except RuntimeInstallError as conflict_error:
                _raise_after_failed_launch_cleanup(
                    runtime_app,
                    reason=str(conflict_error),
                    inspector=active_inspector,
                    terminator=selected_terminator,
                    termination_timeout_seconds=termination_timeout_seconds,
                )
            return
        if identities:
            break
        time.sleep(0.05)
    details = ", ".join(
        f"PID {identity.pid}, UID {identity.uid} ({identity.executable_path})"
        for identity in identities
    ) or "no exact process"
    _raise_after_failed_launch_cleanup(
        runtime_app,
        reason=(
            "The exact stable runtime did not acquire one verified main process "
            f"after launch: {details}"
        ),
        inspector=active_inspector,
        terminator=selected_terminator,
        termination_timeout_seconds=termination_timeout_seconds,
    )


def _raise_after_failed_launch_cleanup(
    runtime_app: Path,
    *,
    reason: str,
    inspector: ProcessInspector,
    terminator: ProcessTerminator,
    termination_timeout_seconds: float,
) -> None:
    try:
        _stop_failed_runtime_launch(
            runtime_app,
            inspector=inspector,
            terminator=terminator,
            timeout_seconds=termination_timeout_seconds,
        )
    except RuntimeInstallError as cleanup_error:
        raise RuntimeInstallError(
            f"{reason}. Exact launch cleanup could not prove that the candidate "
            f"main app, XPC, and askpass helpers exited: {cleanup_error}"
        ) from cleanup_error
    raise RuntimeInstallError(
        f"{reason}. Any partial candidate main app, XPC, and askpass helpers "
        "were stopped."
    )


def _stop_failed_runtime_launch(
    runtime_app: Path,
    *,
    inspector: ProcessInspector,
    terminator: ProcessTerminator,
    timeout_seconds: float,
) -> None:
    """Stop only exact, current-user candidate processes after a failed launch."""

    executable_paths = _runtime_executable_paths(runtime_app)
    attempted: set[ProcessIdentity] = set()
    problems: list[str] = []
    deadline = time.monotonic() + max(0.25, timeout_seconds)
    while True:
        active: list[tuple[Path, ProcessIdentity]] = [
            (executable, identity)
            for executable in executable_paths
            for identity in inspector.identities_for_executable(executable)
        ]
        if not active:
            return
        for executable, identity in active:
            if identity in attempted:
                continue
            attempted.add(identity)
            if not _is_exact_current_user_process(identity, executable):
                problems.append(
                    f"unsafe PID {identity.pid}, UID {identity.uid} "
                    f"({identity.executable_path})"
                )
                continue
            try:
                terminator(identity)
            except BaseException as error:
                problems.append(f"PID {identity.pid} termination failed: {error}")
        if time.monotonic() >= deadline:
            remaining = ", ".join(
                f"PID {identity.pid}, UID {identity.uid} "
                f"({identity.executable_path})"
                for _, identity in active
            )
            diagnostics = "; ".join(problems)
            suffix = f"; {diagnostics}" if diagnostics else ""
            raise RuntimeInstallError(
                f"candidate processes remain after bounded termination: "
                f"{remaining}{suffix}"
            )
        time.sleep(0.05)


def _terminate_bound_process(
    identity: ProcessIdentity,
    *,
    inspector: ProcessInspector,
) -> None:
    """Signal only the same current-user PID/start/path identity."""

    current = inspector.identity(identity.pid)
    if current is None:
        return
    if current != identity:
        raise RuntimeInstallError(
            f"PID {identity.pid} changed identity before termination."
        )
    if (
        current.pid <= 1
        or current.uid != os.getuid()
        or current.executable_path != identity.executable_path
    ):
        raise RuntimeInstallError(
            f"PID {identity.pid} is not an exact current-user process."
        )
    try:
        os.kill(current.pid, signal.SIGTERM)
    except ProcessLookupError:
        return


def _runtime_executable_paths(runtime_app: Path) -> tuple[Path, Path, Path]:
    return (
        runtime_app / f"Contents/MacOS/{APP_EXECUTABLE_NAME}",
        runtime_app
        / f"Contents/XPCServices/{XPC_EXECUTABLE_NAME}.xpc/Contents/MacOS/"
        f"{XPC_EXECUTABLE_NAME}",
        runtime_app / ASKPASS_RELATIVE_PATH,
    )


def _runtime_entrypoint_paths(runtime_app: Path) -> tuple[Path, Path, Path]:
    return _runtime_executable_paths(runtime_app)


def _remove_execute_permissions(path: Path) -> None:
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_nlink != 1
        ):
            raise RuntimeInstallError(
                f"Retired runtime entrypoint is not an owner-controlled file: {path}"
            )
        os.fchmod(descriptor, stat.S_IMODE(metadata.st_mode) & ~0o111)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    final_metadata = os.lstat(path)
    if (
        not stat.S_ISREG(final_metadata.st_mode)
        or final_metadata.st_uid != os.getuid()
        or final_metadata.st_nlink != 1
        or stat.S_IMODE(final_metadata.st_mode) & 0o111
    ):
        raise RuntimeInstallError(
            f"Retired runtime entrypoint remained executable: {path}"
        )


def _remove_bundle_execute_permissions(bundle: Path) -> None:
    """Make every executable file in a retired physical bundle non-launchable."""

    pending = [bundle]
    executable_files: list[Path] = []
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                path = Path(entry.path)
                metadata = entry.stat(follow_symlinks=False)
                if stat.S_ISLNK(metadata.st_mode):
                    raise RuntimeInstallError(
                        f"Retired runtime quarantine contains a symlink: {path}"
                    )
                if stat.S_ISDIR(metadata.st_mode):
                    pending.append(path)
                    continue
                if not stat.S_ISREG(metadata.st_mode):
                    raise RuntimeInstallError(
                        "Retired runtime quarantine contains a non-file entry: "
                        f"{path}"
                    )
                if stat.S_IMODE(metadata.st_mode) & 0o111:
                    executable_files.append(path)
    for path in sorted(executable_files):
        _remove_execute_permissions(path)


def _quarantine_retired_runtime(staging: Path) -> Path:
    retired_app = staging / APP_NAME
    quarantine_app = staging / RETIRED_APP_QUARANTINE_NAME
    if quarantine_app.exists() or quarantine_app.is_symlink():
        raise RuntimeInstallError(
            f"Retired runtime quarantine path already exists: {quarantine_app}"
        )
    os.rename(retired_app, quarantine_app)
    _fsync_directory(staging)
    _remove_bundle_execute_permissions(quarantine_app)
    return quarantine_app


def _main_app_bundle_for_process(identity: ProcessIdentity) -> Path | None:
    executable = Path(identity.executable_path)
    if (
        not executable.is_absolute()
        or executable.name != APP_EXECUTABLE_NAME
        or executable.parent.name != "MacOS"
        or executable.parent.parent.name != "Contents"
    ):
        return None
    app = executable.parent.parent.parent
    if app.suffix != ".app":
        return None
    return app


def _read_running_app_bundle_identifier(app: Path) -> str | None:
    info_plist = app / "Contents/Info.plist"
    try:
        encoded = info_plist.read_bytes()
        if not encoded or len(encoded) > MAX_METADATA_BYTES:
            raise ValueError("Info.plist has an invalid size")
        metadata = plistlib.loads(encoded)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise RuntimeInstallError(
            f"Could not inspect the running application identity at {app}: {error}"
        ) from error
    if not isinstance(metadata, dict):
        raise RuntimeInstallError(
            f"Running application Info.plist is not a dictionary: {app}"
        )
    executable_name = metadata.get("CFBundleExecutable")
    if executable_name != APP_EXECUTABLE_NAME:
        raise RuntimeInstallError(
            "Running application executable does not match its bundle metadata: "
            f"{app}"
        )
    bundle_identifier = metadata.get("CFBundleIdentifier")
    return bundle_identifier if isinstance(bundle_identifier, str) else None


def _same_physical_or_lexical_path(first: Path, second: Path) -> bool:
    if not first.is_absolute() or not second.is_absolute():
        return first == second
    try:
        return os.path.samefile(first, second)
    except OSError:
        return os.path.normpath(str(first)) == os.path.normpath(str(second))


def _is_exact_current_user_process(
    identity: ProcessIdentity,
    executable: Path,
) -> bool:
    return (
        identity.pid > 1
        and identity.uid == os.getuid()
        and identity.executable_path == str(executable)
    )


def _parse_candidate_binding(
    metadata: Mapping[str, object],
    *,
    metadata_path: Path,
    manifest_path: Path,
    manifest: Mapping[str, object],
    allow_legacy_profileless_retirement: bool,
) -> CandidateBinding:
    expected_metadata_keys = {
        "artifactRole",
        "buildConfiguration",
        "buildNumber",
        "exactStoreRuntimeVerified",
        "marketingVersion",
        "profile",
        "recordVersion",
        "runtimeApp",
        "runtimeManifestSHA256",
        "scheme",
        "signatures",
        "signingIdentity",
        "sourceCommit",
        "sourceSnapshotMethod",
        "sourceSnapshotSHA256",
        "teamIdentifier",
        "timestamp",
        "universalArchitectures",
    }
    if set(metadata) != expected_metadata_keys:
        raise RuntimeInstallError("Candidate metadata schema is unexpected.")
    expected_values = {
        "artifactRole": "release-testing",
        "buildConfiguration": EXPECTED_CONFIGURATION,
        "buildNumber": EXPECTED_BUILD_NUMBER,
        "marketingVersion": EXPECTED_MARKETING_VERSION,
        "recordVersion": EXPECTED_RECORD_VERSION,
        "scheme": EXPECTED_SCHEME,
        "sourceSnapshotMethod": (
            "scripts/validate_release_archive.sh --print-source-binding"
        ),
        "teamIdentifier": EXPECTED_TEAM_IDENTIFIER,
    }
    for key, expected in expected_values.items():
        if metadata.get(key) != expected:
            raise RuntimeInstallError(f"Candidate metadata field {key} is unexpected.")
    if metadata.get("exactStoreRuntimeVerified") is not False:
        raise RuntimeInstallError(
            "Release-testing metadata must not claim exact Store runtime verification."
        )
    if metadata.get("universalArchitectures") != ["arm64", "x86_64"]:
        raise RuntimeInstallError("Candidate metadata architecture set is unexpected.")
    _parse_timestamp(metadata.get("timestamp"))

    source_commit = _require_regex(
        metadata.get("sourceCommit"),
        r"[0-9a-f]{40}",
        "source commit",
    )
    source_snapshot = normalize_sha256(
        _require_string(metadata.get("sourceSnapshotSHA256"), "source snapshot"),
        description="source snapshot SHA-256",
    )
    manifest_sha256 = normalize_sha256(
        _require_string(
            metadata.get("runtimeManifestSHA256"),
            "runtime manifest SHA-256",
        ),
        description="runtime manifest SHA-256",
    )

    runtime_value = _require_string(metadata.get("runtimeApp"), "runtime app")
    artifact_app = Path(runtime_value)
    _require_absolute_normalized(artifact_app, "Immutable candidate app")
    expected_artifact = metadata_path.parent / APP_NAME
    if artifact_app != expected_artifact:
        raise RuntimeInstallError(
            "Candidate runtimeApp must be the physical app beside its metadata."
        )
    if _is_within(artifact_app, Path("/Applications")):
        raise RuntimeInstallError(
            "The production /Applications app cannot be a Release-testing candidate."
        )
    reject_symlink_components(artifact_app)
    if (
        not artifact_app.is_dir()
        or artifact_app.is_symlink()
        or artifact_app.resolve(strict=True) != artifact_app
    ):
        raise RuntimeInstallError("Immutable candidate app is not a physical bundle.")

    identity = metadata.get("signingIdentity")
    if not isinstance(identity, dict) or set(identity) != {
        "certificateSHA1",
        "commonName",
        "teamIdentifier",
    }:
        raise RuntimeInstallError("Candidate signing identity is malformed.")
    if identity.get("teamIdentifier") != EXPECTED_TEAM_IDENTIFIER:
        raise RuntimeInstallError("Candidate signing TeamIdentifier is unexpected.")
    common_name = _require_string(identity.get("commonName"), "signing common name")
    if not common_name.startswith("Apple Development:"):
        raise RuntimeInstallError("Candidate is not Apple Development signed.")
    certificate_sha1 = _normalize_sha1(identity.get("certificateSHA1"))
    profile_value = metadata.get("profile")
    if profile_value is None:
        if not allow_legacy_profileless_retirement:
            raise RuntimeInstallError(
                "Candidate Apple Development profile metadata is malformed."
            )
        identity_contract = _IdentityContract.LEGACY_PROFILELESS_RETIREMENT
        development_profile = None
    else:
        identity_contract = _IdentityContract.CURRENT_PROFILED
        development_profile = _parse_development_profile_binding(
            profile_value,
            expected_certificate_sha1=certificate_sha1,
        )

    signatures_value = metadata.get("signatures")
    if not isinstance(signatures_value, dict) or set(signatures_value) != {
        "app",
        "rdpXPC",
        "sshAskpass",
    }:
        raise RuntimeInstallError("Candidate signature bindings are malformed.")
    signatures = {
        role: _parse_component_binding(value, role=role)
        for role, value in signatures_value.items()
    }
    if any(
        component.leaf_certificate_sha1 != certificate_sha1
        for component in signatures.values()
    ):
        raise RuntimeInstallError(
            "Component leaf certificate bindings do not match signing identity."
        )

    _validate_manifest_schema(
        manifest,
        artifact_app=artifact_app,
        expected_manifest_sha256=manifest_sha256,
    )
    return CandidateBinding(
        metadata_path=metadata_path,
        manifest_path=manifest_path,
        artifact_app=artifact_app,
        source_commit=source_commit,
        source_snapshot_sha256=source_snapshot,
        runtime_manifest_sha256=manifest_sha256,
        signing_certificate_sha1=certificate_sha1,
        identity_contract=identity_contract,
        development_profile=development_profile,
        signatures=signatures,
        metadata_sha256=sha256_file(metadata_path),
        manifest=manifest,
    )


def _parse_development_profile_binding(
    value: object,
    *,
    expected_certificate_sha1: str,
) -> DevelopmentProfileIdentity:
    expected_keys = {
        "expiration",
        "matched_certificate_sha1",
        "matched_device_identifier",
        "name",
        "uuid",
    }
    if not isinstance(value, dict) or set(value) != expected_keys:
        raise RuntimeInstallError(
            "Candidate Apple Development profile metadata is malformed."
        )
    certificate_sha1 = _normalize_sha1(value.get("matched_certificate_sha1"))
    if certificate_sha1 != expected_certificate_sha1:
        raise RuntimeInstallError(
            "Candidate profile certificate does not match the signing identity."
        )
    uuid_value = _require_regex(
        value.get("uuid"),
        r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
        r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        "development profile UUID",
    )
    name = _require_string(value.get("name"), "development profile name")
    expiration = _require_string(
        value.get("expiration"),
        "development profile expiration",
    )
    _parse_timestamp(expiration)
    device = _require_regex(
        value.get("matched_device_identifier"),
        r"[A-Za-z0-9-]{8,64}",
        "development profile device identifier",
    )
    return DevelopmentProfileIdentity(
        uuid=uuid_value,
        name=name,
        expiration=expiration,
        matched_device_identifier=device,
        matched_certificate_sha1=certificate_sha1,
    )


def _parse_component_binding(value: object, *, role: str) -> ComponentBinding:
    if not isinstance(value, dict) or set(value) != {
        "cdhash",
        "executableSHA256",
        "leafCertificateSHA1",
    }:
        raise RuntimeInstallError(f"{role} signature binding is malformed.")
    return ComponentBinding(
        cdhash=normalize_cdhash(
            _require_string(value.get("cdhash"), f"{role} CDHash")
        ),
        executable_sha256=normalize_sha256(
            _require_string(
                value.get("executableSHA256"),
                f"{role} executable SHA-256",
            ),
            description=f"{role} executable SHA-256",
        ),
        leaf_certificate_sha1=_normalize_sha1(
            value.get("leafCertificateSHA1")
        ),
    )


def _validate_manifest_schema(
    manifest: Mapping[str, object],
    *,
    artifact_app: Path,
    expected_manifest_sha256: str,
) -> None:
    if set(manifest) != {"bundle", "entries", "entryCount", "manifestSHA256"}:
        raise RuntimeInstallError("Runtime manifest schema is unexpected.")
    if manifest.get("bundle") != str(artifact_app):
        raise RuntimeInstallError("Runtime manifest is bound to another app path.")
    entries = manifest.get("entries")
    entry_count = manifest.get("entryCount")
    if (
        not isinstance(entries, list)
        or type(entry_count) is not int
        or entry_count != len(entries)
        or entry_count <= 0
    ):
        raise RuntimeInstallError("Runtime manifest entry inventory is malformed.")
    actual_digest = _manifest_entries_sha256(entries)
    recorded_digest = normalize_sha256(
        _require_string(manifest.get("manifestSHA256"), "manifest digest"),
        description="runtime manifest digest",
    )
    if recorded_digest != actual_digest or recorded_digest != expected_manifest_sha256:
        raise RuntimeInstallError("Runtime manifest digest does not match its entries.")


def _verify_manifest_entries(
    expected: Mapping[str, object],
    actual: Mapping[str, object],
) -> None:
    if (
        expected.get("entries") != actual.get("entries")
        or expected.get("entryCount") != actual.get("entryCount")
        or expected.get("manifestSHA256") != actual.get("manifestSHA256")
    ):
        raise RuntimeInstallError(
            "Candidate bundle contents do not match the immutable runtime manifest."
        )


def _verify_signed_component(
    component: Path,
    *,
    expected_identifier: str,
    expected_team_identifier: str,
    runner: CommandRunner,
):
    verified = runner(
        ["/usr/bin/codesign", "--verify", "--strict", "--verbose=2", str(component)],
        text=True,
        capture_output=True,
        check=False,
    )
    if verified.returncode != 0:
        raise RuntimeInstallError(
            f"Strict code-signature verification failed for {component}: "
            f"{_bounded_output(verified.stderr)}"
        )
    details_result = runner(
        ["/usr/bin/codesign", "-dv", "--verbose=4", str(component)],
        text=True,
        capture_output=True,
        check=False,
    )
    if details_result.returncode != 0:
        raise RuntimeInstallError(f"Could not read code signature for {component}.")
    return parse_signature_identity(
        details_result.stdout + details_result.stderr,
        expected_identifier=expected_identifier,
        expected_team_identifier=expected_team_identifier,
        authority_prefixes=(APPLE_DEVELOPMENT_AUTHORITY_PREFIX,),
        artifact_description="Release-testing component",
    )


def _leaf_certificate_sha1(
    component: Path,
    *,
    runner: CommandRunner,
) -> str:
    with tempfile.TemporaryDirectory(prefix="jts-runtime-certificate-") as temporary:
        prefix = Path(temporary) / "leaf-"
        result = runner(
            [
                "/usr/bin/codesign",
                "-d",
                f"--extract-certificates={prefix}",
                str(component),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        leaf = Path(f"{prefix}0")
        if result.returncode != 0 or not leaf.is_file() or leaf.is_symlink():
            raise RuntimeInstallError(
                f"Could not extract signing leaf certificate from {component}."
            )
        return hashlib.sha1(leaf.read_bytes()).hexdigest().upper()


def _read_architectures(
    executable: Path,
    *,
    runner: CommandRunner,
) -> set[str]:
    result = runner(
        ["/usr/bin/lipo", "-archs", str(executable)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeInstallError(
            f"Could not inspect runtime architectures: "
            f"{_bounded_output(result.stderr)}"
        )
    return set(result.stdout.split())


def _copy_physical_app(
    source: Path,
    destination: Path,
    *,
    runner: CommandRunner,
) -> None:
    result = runner(
        [
            "/usr/bin/ditto",
            "--rsrc",
            "--extattr",
            "--acl",
            str(source),
            str(destination),
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeInstallError(
            f"Could not stage physical runtime copy: {_bounded_output(result.stderr)}"
        )
    if (
        not destination.is_dir()
        or destination.is_symlink()
        or destination.resolve(strict=True) != destination
    ):
        raise RuntimeInstallError("Staged runtime app is not a physical bundle.")


def _write_runtime_record(
    path: Path,
    *,
    binding: CandidateBinding,
    stable_app: Path,
) -> None:
    payload = {
        "artifactMetadata": str(binding.metadata_path),
        "artifactMetadataSHA256": binding.metadata_sha256,
        "artifactRuntimeApp": str(binding.artifact_app),
        "installedAt": dt.datetime.now(dt.timezone.utc)
        .isoformat()
        .replace("+00:00", "Z"),
        "recordVersion": RUNTIME_RECORD_VERSION,
        "runtimeApp": str(stable_app),
        "runtimeManifestSHA256": binding.runtime_manifest_sha256,
        "signatures": {
            role: {
                "cdhash": component.cdhash,
                "executableSHA256": component.executable_sha256,
                "leafCertificateSHA1": component.leaf_certificate_sha1,
            }
            for role, component in binding.signatures.items()
        },
        "sourceCommit": binding.source_commit,
        "sourceSnapshotSHA256": binding.source_snapshot_sha256,
    }
    encoded = (
        json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        view = memoryview(encoded)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise RuntimeInstallError("Could not write stable runtime metadata.")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    metadata = os.lstat(path)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) != 0o600
    ):
        raise RuntimeInstallError("Stable runtime metadata is not owner-only.")


def _publish_staged_runtime(
    staging: Path,
    runtime_root: Path,
    *,
    launch: bool,
    exchange: DirectoryExchange,
    registrar: RuntimeAction,
    unregistrar: RuntimeAction,
    launcher: RuntimeAction,
    pre_activation_validator: RuntimeAction = lambda _: None,
    pre_rollback_validator: RuntimeAction = lambda _: None,
    staging_idle_validator: RuntimeAction = lambda _: None,
    post_activation_validator: RuntimeAction = lambda _: None,
) -> InstallResult:
    replaced = runtime_root.exists()
    published = False
    previous_unregistration_attempted = False
    try:
        if replaced:
            # Unregistration can update LaunchServices and still report a
            # failure. Conservatively restore the old registration whenever
            # publication has not exchanged the directories yet.
            previous_unregistration_attempted = True
            unregistrar(runtime_root / APP_NAME)
            exchange(runtime_root, staging)
        else:
            rename_directory_no_replace(staging, runtime_root)
        published = True
        _fsync_directory(runtime_root.parent)

        stable_app = runtime_root / APP_NAME
        pre_activation_validator(stable_app)
        if replaced:
            staging_idle_validator(staging / APP_NAME)
        registrar(stable_app)
        if launch:
            launcher(stable_app)
        post_activation_validator(stable_app)
    except BaseException as action_error:
        if not published:
            registration_error: BaseException | None = None
            if (
                previous_unregistration_attempted
                and runtime_root.exists()
                and not runtime_root.is_symlink()
            ):
                try:
                    registrar(runtime_root / APP_NAME)
                except BaseException as error:
                    registration_error = error
            if staging.exists() and not staging.is_symlink():
                shutil.rmtree(staging, ignore_errors=True)
            suffix = (
                " Previous runtime re-registration failed: "
                f"{registration_error}."
                if registration_error is not None
                else ""
            )
            raise RuntimeInstallError(
                "Stable runtime publication failed before activation: "
                f"{action_error}.{suffix}"
            ) from action_error

        stable_app = runtime_root / APP_NAME
        try:
            pre_rollback_validator(stable_app)
        except BaseException as rollback_guard_error:
            retained = (
                f" The previous runtime is retained at {staging}."
                if replaced and staging.exists()
                else ""
            )
            raise RuntimeInstallError(
                "Stable runtime activation failed and disk rollback was refused "
                "because the exact candidate main app, XPC, and askpass helpers "
                f"were not confirmed stopped: {rollback_guard_error}.{retained}"
            ) from action_error

        rollback_errors: list[str] = []
        try:
            unregistrar(stable_app)
        except BaseException as unregistration_error:
            rollback_errors.append(
                f"new runtime unregistration failed: {unregistration_error}"
            )
        physically_restored = False
        rollback_synced = False
        try:
            if replaced:
                exchange(runtime_root, staging)
            else:
                rename_directory_no_replace(runtime_root, staging)
            physically_restored = True
        except BaseException as rollback_error:
            rollback_errors.append(str(rollback_error))
        if physically_restored:
            try:
                _fsync_directory(runtime_root.parent)
                rollback_synced = True
            except BaseException as rollback_sync_error:
                rollback_errors.append(
                    f"rollback directory sync failed: {rollback_sync_error}"
                )
        if physically_restored and replaced and runtime_root.exists():
            try:
                registrar(runtime_root / APP_NAME)
            except BaseException as registration_error:
                rollback_errors.append(
                    f"old runtime re-registration failed: {registration_error}"
                )
        if (
            physically_restored
            and rollback_synced
            and staging.exists()
            and not staging.is_symlink()
        ):
            try:
                staging_idle_validator(staging / APP_NAME)
            except BaseException as staging_guard_error:
                rollback_errors.append(
                    "retired runtime cleanup was blocked because its exact "
                    f"processes were not confirmed stopped: {staging_guard_error}"
                )
            else:
                try:
                    shutil.rmtree(staging)
                except OSError as cleanup_error:
                    rollback_errors.append(
                        f"retired runtime cleanup failed: {cleanup_error}"
                    )
        if physically_restored and staging.exists():
            retained_kind = (
                "candidate runtime"
                if replaced
                else "failed candidate runtime"
            )
            rollback_errors.append(f"{retained_kind} retained at {staging}")
        if physically_restored:
            suffix = (
                f" Rollback diagnostics: {'; '.join(rollback_errors)}"
                if rollback_errors
                else ""
            )
            outcome = (
                "previous runtime was restored"
                if replaced
                else "failed first installation was removed"
            )
            raise RuntimeInstallError(
                f"Stable runtime activation failed; {outcome}: "
                f"{action_error}.{suffix}"
            ) from action_error

        retained = (
            f" Previous runtime is retained at {staging}."
            if replaced and staging.exists()
            else ""
        )
        raise RuntimeInstallError(
            "Stable runtime activation failed and automatic rollback did not "
            f"complete: {action_error}. {'; '.join(rollback_errors)}.{retained}"
        ) from action_error

    if replaced and staging.exists():
        quarantine_app: Path | None = None
        try:
            staging_idle_validator(staging / APP_NAME)
            quarantine_app = _quarantine_retired_runtime(staging)
            staging_idle_validator(quarantine_app)
            post_activation_validator(runtime_root / APP_NAME)
            shutil.rmtree(staging)
            if staging.exists() or staging.is_symlink():
                raise RuntimeInstallError(
                    f"Retired runtime staging path still exists after cleanup: {staging}"
                )
            _fsync_directory(staging.parent)
        except BaseException as cleanup_error:
            residue = (
                f"retired runtime residue remains at {staging}"
                if staging.exists() or staging.is_symlink()
                else "retired runtime files were removed before durability failed"
            )
            raise RuntimeInstallError(
                "Stable runtime activation is incomplete because retired-runtime "
                f"quarantine and cleanup did not complete; {residue}: "
                f"{cleanup_error}."
            ) from cleanup_error
        try:
            post_activation_validator(runtime_root / APP_NAME)
        except BaseException as conflict_error:
            raise RuntimeInstallError(
                "Stable runtime activation is incomplete because another JTS "
                f"Terminal process appeared during finalization: {conflict_error}."
            ) from conflict_error
    _assert_no_staging_residue(runtime_root)
    return InstallResult(
        runtime_app=runtime_root / APP_NAME,
        runtime_metadata=runtime_root / RUNTIME_METADATA_NAME,
        replaced_existing_runtime=replaced,
        launched=launch,
    )


def _validate_existing_managed_runtime(
    runtime_root: Path,
    *,
    runner: CommandRunner = subprocess.run,
) -> CandidateBinding:
    _require_owner_controlled_directory(runtime_root, exact_private=True)
    entries = {entry.name for entry in runtime_root.iterdir()}
    if entries != {APP_NAME, RUNTIME_METADATA_NAME}:
        raise RuntimeInstallError(
            "Existing stable runtime is not a complete managed installation."
        )
    app = runtime_root / APP_NAME
    if (
        not app.is_dir()
        or app.is_symlink()
        or app.resolve(strict=True) != app
    ):
        raise RuntimeInstallError("Existing stable runtime app is not physical.")
    metadata_path = _require_private_regular_json(
        runtime_root / RUNTIME_METADATA_NAME,
        description="Stable runtime metadata",
        maximum_size=MAX_METADATA_BYTES,
    )
    value = _load_strict_json(metadata_path)
    expected_keys = {
        "artifactMetadata",
        "artifactMetadataSHA256",
        "artifactRuntimeApp",
        "installedAt",
        "recordVersion",
        "runtimeApp",
        "runtimeManifestSHA256",
        "signatures",
        "sourceCommit",
        "sourceSnapshotSHA256",
    }
    if not isinstance(value, dict) or set(value) != expected_keys:
        raise RuntimeInstallError("Existing stable runtime metadata schema is invalid.")
    if (
        value.get("recordVersion") != RUNTIME_RECORD_VERSION
        or value.get("runtimeApp") != str(app)
    ):
        raise RuntimeInstallError("Existing stable runtime metadata is invalid.")
    _parse_timestamp(value.get("installedAt"))
    artifact_metadata = Path(
        _require_string(value.get("artifactMetadata"), "artifact metadata")
    )
    _require_absolute_normalized(artifact_metadata, "Artifact metadata")
    expected_metadata_sha256 = normalize_sha256(
        _require_string(
            value.get("artifactMetadataSHA256"),
            "artifact metadata SHA-256",
        ),
        description="artifact metadata SHA-256",
    )
    if sha256_file(artifact_metadata) != expected_metadata_sha256:
        raise RuntimeInstallError(
            "Existing runtime artifact metadata no longer matches its binding."
        )
    binding = _load_and_verify_existing_runtime_artifact(
        artifact_metadata,
        runner=runner,
    )
    expected_signatures = {
        role: {
            "cdhash": component.cdhash,
            "executableSHA256": component.executable_sha256,
            "leafCertificateSHA1": component.leaf_certificate_sha1,
        }
        for role, component in binding.signatures.items()
    }
    if (
        value.get("artifactRuntimeApp") != str(binding.artifact_app)
        or value.get("runtimeManifestSHA256") != binding.runtime_manifest_sha256
        or value.get("sourceCommit") != binding.source_commit
        or value.get("sourceSnapshotSHA256") != binding.source_snapshot_sha256
        or value.get("signatures") != expected_signatures
    ):
        raise RuntimeInstallError(
            "Existing stable runtime record does not match its immutable artifact."
        )
    verify_candidate_bundle(binding, app, runner=runner)
    return binding


def _require_private_regular_json(
    path: Path,
    *,
    description: str,
    maximum_size: int,
) -> Path:
    _require_absolute_normalized(path, description)
    reject_symlink_components(path)
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise RuntimeInstallError(f"{description} is unavailable: {error}") from error
    metadata = os.lstat(path)
    if (
        resolved != path
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) & 0o077
        or metadata.st_size <= 0
        or metadata.st_size > maximum_size
    ):
        raise RuntimeInstallError(
            f"{description} must be a private, canonical regular file."
        )
    return path


def _require_owner_controlled_directory(
    path: Path,
    *,
    exact_private: bool,
) -> None:
    metadata = os.lstat(path)
    mode = stat.S_IMODE(metadata.st_mode)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or mode & 0o022
        or (exact_private and mode != 0o700)
    ):
        requirement = "owner-only" if exact_private else "owner-controlled"
        raise RuntimeInstallError(f"Directory must be {requirement}: {path}")


def _require_regular_executable(path: Path, *, description: str) -> None:
    reject_symlink_components(path)
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise RuntimeInstallError(f"{description} is unavailable: {error}") from error
    metadata = os.lstat(path)
    if (
        resolved != path
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or not os.access(path, os.X_OK)
        or stat.S_IMODE(metadata.st_mode) & 0o022
    ):
        raise RuntimeInstallError(f"{description} is not a safe regular executable.")


def _load_strict_json(path: Path) -> object:
    def reject_duplicate_pairs(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise RuntimeInstallError(f"Duplicate JSON key in {path}: {key}")
            result[key] = value
        return result

    try:
        payload = path.read_bytes()
        return json.loads(
            payload.decode("utf-8", errors="strict"),
            object_pairs_hook=reject_duplicate_pairs,
            parse_constant=lambda value: (_ for _ in ()).throw(
                RuntimeInstallError(f"Non-finite JSON value in {path}: {value}")
            ),
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise RuntimeInstallError(f"Could not parse strict JSON: {path}") from error


def _manifest_entries_sha256(entries: object) -> str:
    encoded = json.dumps(
        entries,
        ensure_ascii=True,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _normalize_sha1(value: object) -> str:
    normalized = _require_string(value, "certificate SHA-1").upper()
    if not re.fullmatch(r"[0-9A-F]{40}", normalized):
        raise RuntimeInstallError(
            "Certificate SHA-1 must contain 40 hexadecimal characters."
        )
    return normalized


def _require_string(value: object, description: str) -> str:
    if not isinstance(value, str) or not value:
        raise RuntimeInstallError(f"Candidate {description} is missing or malformed.")
    return value


def _require_regex(value: object, pattern: str, description: str) -> str:
    normalized = _require_string(value, description)
    if not re.fullmatch(pattern, normalized):
        raise RuntimeInstallError(f"Candidate {description} is malformed.")
    return normalized


def _parse_timestamp(value: object) -> None:
    timestamp = _require_string(value, "timestamp")
    try:
        parsed = dt.datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError as error:
        raise RuntimeInstallError("Candidate timestamp is malformed.") from error
    if parsed.tzinfo is None:
        raise RuntimeInstallError("Candidate timestamp must be timezone-aware.")


def _require_absolute_normalized(path: Path, description: str) -> None:
    if not path.is_absolute() or Path(os.path.normpath(path)) != path:
        raise RuntimeInstallError(f"{description} must be an absolute normalized path.")


def _is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _bounded_output(value: object, limit: int = 600) -> str:
    normalized = " ".join(str(value or "").split())
    return normalized[:limit] if normalized else "no diagnostic"
