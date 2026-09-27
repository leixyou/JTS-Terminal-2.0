"""Static archive and same-source runtime binding for RDP recovery proof."""

from __future__ import annotations

import dataclasses
import hashlib
import os
import plistlib
import re
import stat
import subprocess
from collections.abc import Callable
from pathlib import Path


EXPECTED_APP_IDENTIFIER = "com.lljts.JTSTerminal"
EXPECTED_HELPER_IDENTIFIER = "com.lljts.JTSTerminal.FreeRDPService"
EXPECTED_MARKETING_VERSION = "2.0"
EXPECTED_BUILD_NUMBER = "11"
DEFAULT_TEAM_IDENTIFIER = "YOURTEAMID"
ARCHIVE_SOURCE_COMMIT_KEY = "JTSBuildSourceCommit"
ARCHIVE_SOURCE_SHA256_KEY = "JTSBuildSourceSHA256"
APP_RELATIVE_PATH = Path("Products/Applications/JTS Terminal.app")
APP_EXECUTABLE_RELATIVE_PATH = Path("Contents/MacOS/JTS Terminal")
HELPER_BUNDLE_RELATIVE_PATH = Path(
    "Contents/XPCServices/JTFreeRDPService.xpc"
)
HELPER_EXECUTABLE_RELATIVE_PATH = Path("Contents/MacOS/JTFreeRDPService")
APP_STORE_AUTHORITY_PREFIXES = (
    "Apple Distribution:",
    "3rd Party Mac Developer Application:",
    "Apple Mac OS Application Signing",
)
APPLE_DEVELOPMENT_AUTHORITY_PREFIX = "Apple Development:"
SIGNING_ONLY_ENTITLEMENT_KEYS = frozenset(
    {
        "com.apple.application-identifier",
        "com.apple.developer.team-identifier",
        "com.apple.security.get-task-allow",
    }
)

def _load_ui_test_support_markers() -> tuple[bytes, ...]:
    manifest_path = Path(__file__).with_name("ui_test_support_markers.txt")
    try:
        lines = manifest_path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeError) as error:
        raise RuntimeError(
            f"Could not read UI-test support marker manifest: {manifest_path}"
        ) from error

    markers = tuple(line.encode("ascii") for line in lines if line)
    if not markers:
        raise RuntimeError(
            f"UI-test support marker manifest is empty: {manifest_path}"
        )
    if len(markers) != len(set(markers)):
        raise RuntimeError(
            f"UI-test support marker manifest contains duplicates: {manifest_path}"
        )
    return markers


UI_TEST_SUPPORT_MARKERS = _load_ui_test_support_markers()
XPC_TEST_HOOK_MARKERS = (
    b"crashForTestingWithReply:",
    b"helperPID",
)


class VerificationError(RuntimeError):
    """A fail-closed candidate, process, or evidence verification failure."""


@dataclasses.dataclass(frozen=True)
class CandidatePaths:
    archive: Path
    app_bundle: Path
    app_executable: Path
    helper_bundle: Path
    helper_executable: Path


@dataclasses.dataclass(frozen=True)
class RuntimePaths:
    app_bundle: Path
    app_executable: Path
    helper_bundle: Path
    helper_executable: Path


@dataclasses.dataclass(frozen=True)
class SourceIdentity:
    commit: str
    snapshot_sha256: str


@dataclasses.dataclass(frozen=True)
class SignatureIdentity:
    identifier: str
    team_identifier: str
    authority: str
    cdhash: str
    hardened_runtime: bool


@dataclasses.dataclass(frozen=True)
class RunningSignatureBinding:
    pid: int
    identifier: str
    team_identifier: str
    cdhash: str
    requirement: str


@dataclasses.dataclass(frozen=True)
class EntitlementsParity:
    app_features: dict[str, object]
    helper_features: dict[str, object]
    archive_app_signing: dict[str, object]
    runtime_app_signing: dict[str, object]
    archive_helper_signing: dict[str, object]
    runtime_helper_signing: dict[str, object]


def resolve_candidate_paths(archive: Path) -> CandidatePaths:
    archive = require_canonical_existing_path(archive, directory=True)
    if archive.suffix != ".xcarchive":
        raise VerificationError("The candidate path must end in .xcarchive.")
    archive_plist = archive / "Info.plist"
    if not archive_plist.is_file():
        raise VerificationError("The candidate is not a recognizable xcarchive.")
    app_bundle = archive / APP_RELATIVE_PATH
    app_executable = app_bundle / APP_EXECUTABLE_RELATIVE_PATH
    helper_bundle = app_bundle / HELPER_BUNDLE_RELATIVE_PATH
    helper_executable = helper_bundle / HELPER_EXECUTABLE_RELATIVE_PATH
    require_canonical_existing_path(app_bundle, directory=True)
    require_canonical_existing_path(helper_bundle, directory=True)
    _require_regular_executable(app_executable)
    _require_regular_executable(helper_executable)
    _require_bundle_identity(
        app_bundle,
        expected_identifier=EXPECTED_APP_IDENTIFIER,
        expected_version=EXPECTED_MARKETING_VERSION,
        expected_build=EXPECTED_BUILD_NUMBER,
    )
    _require_bundle_identity(
        helper_bundle,
        expected_identifier=EXPECTED_HELPER_IDENTIFIER,
        expected_version=EXPECTED_MARKETING_VERSION,
        expected_build=EXPECTED_BUILD_NUMBER,
    )
    return CandidatePaths(
        archive=archive,
        app_bundle=app_bundle,
        app_executable=app_executable,
        helper_bundle=helper_bundle,
        helper_executable=helper_executable,
    )


def resolve_runtime_paths(app_bundle: Path) -> RuntimePaths:
    """Resolve the separately launchable Release-testing app.

    The App Store archive is immutable static evidence and is intentionally not
    launched. PID, path, and process-replacement checks bind only to these
    runtime paths.
    """

    app_bundle = require_canonical_existing_path(app_bundle, directory=True)
    if app_bundle.suffix != ".app":
        raise VerificationError("The runtime bundle path must end in .app.")
    app_executable = app_bundle / APP_EXECUTABLE_RELATIVE_PATH
    helper_bundle = app_bundle / HELPER_BUNDLE_RELATIVE_PATH
    helper_executable = helper_bundle / HELPER_EXECUTABLE_RELATIVE_PATH
    require_canonical_existing_path(helper_bundle, directory=True)
    _require_regular_executable(app_executable)
    _require_regular_executable(helper_executable)
    _require_bundle_identity(
        app_bundle,
        expected_identifier=EXPECTED_APP_IDENTIFIER,
        expected_version=EXPECTED_MARKETING_VERSION,
        expected_build=EXPECTED_BUILD_NUMBER,
    )
    _require_bundle_identity(
        helper_bundle,
        expected_identifier=EXPECTED_HELPER_IDENTIFIER,
        expected_version=EXPECTED_MARKETING_VERSION,
        expected_build=EXPECTED_BUILD_NUMBER,
    )
    return RuntimePaths(
        app_bundle=app_bundle,
        app_executable=app_executable,
        helper_bundle=helper_bundle,
        helper_executable=helper_executable,
    )


def require_runtime_outside_archive(
    archive_paths: CandidatePaths,
    runtime_paths: RuntimePaths,
) -> None:
    try:
        runtime_paths.app_bundle.relative_to(archive_paths.archive)
    except ValueError:
        return
    raise VerificationError(
        "The Release-testing runtime app must be separate from the immutable archive."
    )


def verify_candidate_source_identity(
    paths: CandidatePaths,
    *,
    expected_source_commit: str,
    expected_source_snapshot_sha256: str,
) -> SourceIdentity:
    """Bind signed app provenance and require the archive plist to mirror it.

    Callers must strictly verify the app code signature before invoking this
    function. The app Info.plist is part of the sealed bundle; the xcarchive
    Info.plist is only an unsigned index and is never accepted as authority.
    """

    if not re.fullmatch(r"[0-9a-f]{40}", expected_source_commit):
        raise VerificationError(
            "Expected source commit must be 40 lowercase hexadecimal characters."
        )
    normalized_snapshot = normalize_sha256(
        expected_source_snapshot_sha256,
        description="source snapshot SHA-256",
    )
    signed_identity = _read_source_identity(
        paths.app_bundle / "Contents/Info.plist",
        description="signed app Info.plist",
    )
    archive_identity = _read_source_identity(
        paths.archive / "Info.plist",
        description="archive Info.plist mirror",
    )
    expected = SourceIdentity(expected_source_commit, normalized_snapshot)
    if signed_identity != expected:
        raise VerificationError(
            "The signed app source identity does not match the expected final source."
        )
    if archive_identity != signed_identity:
        raise VerificationError(
            "The unsigned archive source mirror does not match the signed app source identity."
        )
    return signed_identity


def verify_runtime_source_identity(
    paths: RuntimePaths,
    *,
    expected_source_commit: str,
    expected_source_snapshot_sha256: str,
) -> SourceIdentity:
    """Verify provenance sealed into the signed Release-testing app."""

    if not re.fullmatch(r"[0-9a-f]{40}", expected_source_commit):
        raise VerificationError(
            "Expected source commit must be 40 lowercase hexadecimal characters."
        )
    expected = SourceIdentity(
        expected_source_commit,
        normalize_sha256(
            expected_source_snapshot_sha256,
            description="source snapshot SHA-256",
        ),
    )
    actual = _read_source_identity(
        paths.app_bundle / "Contents/Info.plist",
        description="signed runtime app Info.plist",
    )
    if actual != expected:
        raise VerificationError(
            "The signed runtime app source identity does not match the expected final source."
        )
    return actual


def verify_candidate_signatures(
    paths: CandidatePaths,
    expected_team_identifier: str,
    expected_app_cdhash: str,
) -> dict[str, SignatureIdentity]:
    app = _verify_bundle_signature(
        paths.app_bundle,
        EXPECTED_APP_IDENTIFIER,
        expected_team_identifier,
        deep=True,
    )
    helper = _verify_bundle_signature(
        paths.helper_bundle,
        EXPECTED_HELPER_IDENTIFIER,
        expected_team_identifier,
        deep=False,
    )
    if app.team_identifier != helper.team_identifier:
        raise VerificationError("App and helper TeamIdentifier values do not match.")
    if app.cdhash != normalize_cdhash(expected_app_cdhash):
        raise VerificationError(
            "The candidate app CDHash does not match the expected release identity."
        )
    return {"app": app, "helper": helper}


def verify_runtime_signatures(
    paths: RuntimePaths,
    expected_team_identifier: str,
    expected_app_cdhash: str,
) -> dict[str, SignatureIdentity]:
    app = _verify_bundle_signature(
        paths.app_bundle,
        EXPECTED_APP_IDENTIFIER,
        expected_team_identifier,
        deep=True,
        authority_prefixes=(APPLE_DEVELOPMENT_AUTHORITY_PREFIX,),
        artifact_description="Release-testing runtime app",
    )
    helper = _verify_bundle_signature(
        paths.helper_bundle,
        EXPECTED_HELPER_IDENTIFIER,
        expected_team_identifier,
        deep=False,
        authority_prefixes=(APPLE_DEVELOPMENT_AUTHORITY_PREFIX,),
        artifact_description="Release-testing runtime helper",
    )
    if app.team_identifier != helper.team_identifier:
        raise VerificationError(
            "Runtime app and helper TeamIdentifier values do not match."
        )
    if app.cdhash != normalize_cdhash(expected_app_cdhash):
        raise VerificationError(
            "The runtime app CDHash does not match the expected release-testing identity."
        )
    return {"app": app, "helper": helper}


def verify_running_process_signature(
    pid: int,
    *,
    expected_identifier: str,
    expected_team_identifier: str,
    expected_cdhash: str,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> RunningSignatureBinding:
    if pid <= 1:
        raise VerificationError("Dynamic code-signature verification requires a valid PID.")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", expected_identifier):
        raise VerificationError("Dynamic signing identifier is invalid.")
    if not re.fullmatch(r"[A-Z0-9]{10}", expected_team_identifier):
        raise VerificationError("Dynamic TeamIdentifier is invalid.")
    normalized_cdhash = normalize_cdhash(expected_cdhash)
    requirement = (
        f'anchor apple generic and identifier "{expected_identifier}" '
        f'and certificate leaf[subject.OU] = "{expected_team_identifier}" '
        f'and cdhash H"{normalized_cdhash}"'
    )
    result = runner(
        [
            "/usr/bin/codesign",
            "--verify",
            "--strict",
            f"--requirement={requirement}",
            f"+{pid}",
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise VerificationError(
            f"Running PID {pid} does not satisfy the designated code requirement: "
            f"{_bounded_text(result.stderr)}"
        )
    return RunningSignatureBinding(
        pid=pid,
        identifier=expected_identifier,
        team_identifier=expected_team_identifier,
        cdhash=normalized_cdhash,
        requirement=requirement,
    )


def verify_app_executable_sha256(paths: CandidatePaths, expected_sha256: str) -> str:
    normalized = normalize_sha256(expected_sha256, description="app executable SHA-256")
    actual = sha256_file(paths.app_executable)
    if actual != normalized:
        raise VerificationError(
            "The candidate app executable SHA-256 does not match the expected release identity."
        )
    return actual


def verify_runtime_app_executable_sha256(
    paths: RuntimePaths,
    expected_sha256: str,
) -> str:
    normalized = normalize_sha256(
        expected_sha256,
        description="runtime app executable SHA-256",
    )
    actual = sha256_file(paths.app_executable)
    if actual != normalized:
        raise VerificationError(
            "The runtime app executable SHA-256 does not match the expected release-testing identity."
        )
    return actual


def verify_release_runtime_binary_policy(paths: RuntimePaths) -> dict[str, object]:
    """Reject Debug/UI-test code even when Development signing allows attach."""

    debug_dylib = paths.app_bundle / "Contents/MacOS/JTS Terminal.debug.dylib"
    if debug_dylib.exists() or debug_dylib.is_symlink():
        raise VerificationError(
            "The runtime app contains a Debug configuration companion dylib."
        )
    executable_payloads: list[tuple[Path, bytes]] = []
    for candidate in sorted(paths.app_bundle.rglob("*")):
        metadata = os.lstat(candidate)
        if stat.S_ISREG(metadata.st_mode) and stat.S_IMODE(metadata.st_mode) & 0o111:
            executable_payloads.append((candidate, candidate.read_bytes()))
    found_ui_markers = sorted(
        {
            f"{path.relative_to(paths.app_bundle)}:{marker.decode('ascii')}"
            for path, payload in executable_payloads
            for marker in UI_TEST_SUPPORT_MARKERS
            if marker in payload
        }
    )
    if found_ui_markers:
        raise VerificationError(
            "The runtime app contains UI-test support markers: "
            + ", ".join(found_ui_markers)
        )
    found_hooks = sorted(
        {
            f"{path.relative_to(paths.app_bundle)}:{marker.decode('ascii')}"
            for path, payload in executable_payloads
            for marker in XPC_TEST_HOOK_MARKERS
            if marker in payload
        }
    )
    if found_hooks:
        raise VerificationError(
            "The runtime bundle contains Debug-only RDP XPC crash hooks: "
            + ", ".join(found_hooks)
        )
    return {
        "buildConfiguration": "Release",
        "debugDylibAbsent": True,
        "executableCountScanned": len(executable_payloads),
        "uiTestMarkersAbsent": True,
        "xpcCrashHooksAbsent": True,
    }


def verify_feature_entitlements_parity(
    archive_app_entitlements: dict[str, object],
    runtime_app_entitlements: dict[str, object],
    archive_helper_entitlements: dict[str, object],
    runtime_helper_entitlements: dict[str, object],
) -> EntitlementsParity:
    """Require identical product capabilities after removing signing metadata."""

    archive_app_features, archive_app_signing = _split_entitlements(
        archive_app_entitlements
    )
    runtime_app_features, runtime_app_signing = _split_entitlements(
        runtime_app_entitlements
    )
    archive_helper_features, archive_helper_signing = _split_entitlements(
        archive_helper_entitlements
    )
    runtime_helper_features, runtime_helper_signing = _split_entitlements(
        runtime_helper_entitlements
    )
    _validate_signing_entitlements(
        archive_app_signing,
        description="archive app",
        expected_bundle_identifier=EXPECTED_APP_IDENTIFIER,
        require_identity=True,
        expected_get_task_allow=False,
    )
    _validate_signing_entitlements(
        runtime_app_signing,
        description="runtime app",
        expected_bundle_identifier=EXPECTED_APP_IDENTIFIER,
        require_identity=True,
        expected_get_task_allow=True,
        require_get_task_allow=True,
    )
    _validate_signing_entitlements(
        archive_helper_signing,
        description="archive helper",
        expected_bundle_identifier=EXPECTED_HELPER_IDENTIFIER,
        require_identity=False,
        expected_get_task_allow=False,
    )
    _validate_signing_entitlements(
        runtime_helper_signing,
        description="runtime helper",
        expected_bundle_identifier=EXPECTED_HELPER_IDENTIFIER,
        require_identity=False,
        expected_get_task_allow=False,
    )
    if archive_app_features != runtime_app_features:
        raise VerificationError(
            "Runtime app feature entitlements differ from the App Store archive."
        )
    if archive_helper_features != runtime_helper_features:
        raise VerificationError(
            "Runtime helper feature entitlements differ from the App Store archive."
        )
    return EntitlementsParity(
        app_features=archive_app_features,
        helper_features=archive_helper_features,
        archive_app_signing=archive_app_signing,
        runtime_app_signing=runtime_app_signing,
        archive_helper_signing=archive_helper_signing,
        runtime_helper_signing=runtime_helper_signing,
    )


def read_bundle_entitlements(
    bundle: Path,
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> dict[str, object]:
    result = runner(
        [
            "/usr/bin/codesign",
            "-d",
            "--entitlements",
            "-",
            "--xml",
            str(bundle),
        ],
        text=False,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise VerificationError(f"Could not read signed entitlements for {bundle}.")
    try:
        value = plistlib.loads(result.stdout)
    except (plistlib.InvalidFileException, ValueError, TypeError) as error:
        raise VerificationError(
            f"Signed entitlements are not a valid plist for {bundle}."
        ) from error
    if not isinstance(value, dict) or not all(
        isinstance(key, str) for key in value
    ):
        raise VerificationError(f"Signed entitlements are invalid for {bundle}.")
    return value


def normalize_cdhash(value: str) -> str:
    normalized = value.lower()
    if not re.fullmatch(r"[0-9a-f]{40}", normalized):
        raise VerificationError("Expected CDHash must contain exactly 40 hexadecimal characters.")
    return normalized


def normalize_sha256(value: str, *, description: str = "SHA-256") -> str:
    normalized = value.lower()
    if not re.fullmatch(r"[0-9a-f]{64}", normalized):
        raise VerificationError(f"Expected {description} must contain 64 hexadecimal characters.")
    return normalized


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_signature_identity(
    details: str,
    *,
    expected_identifier: str,
    expected_team_identifier: str,
    authority_prefixes: tuple[str, ...] = APP_STORE_AUTHORITY_PREFIXES,
    artifact_description: str = "candidate",
) -> SignatureIdentity:
    fields: dict[str, list[str]] = {}
    for line in details.splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        fields.setdefault(key, []).append(value)

    identifier = _single_field(fields, "Identifier")
    team_identifier = _single_field(fields, "TeamIdentifier")
    authority = _single_field(fields, "Authority", allow_multiple=True)
    cdhash = _single_field(fields, "CDHash")
    if identifier != expected_identifier:
        raise VerificationError(
            f"Unexpected signing identifier {identifier!r}; "
            f"expected {expected_identifier!r}."
        )
    if team_identifier != expected_team_identifier:
        raise VerificationError(
            f"Unexpected TeamIdentifier {team_identifier!r}; "
            f"expected {expected_team_identifier!r}."
        )
    if not authority.startswith(authority_prefixes):
        raise VerificationError(
            f"The {artifact_description} has an unexpected signing authority: "
            f"{authority!r}."
        )
    if fields.get("Signature") == ["adhoc"]:
        raise VerificationError("Ad-hoc signatures are not release evidence.")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", cdhash):
        raise VerificationError("The code signature did not expose a valid CDHash.")
    hardened_runtime = bool(
        re.search(r"^CodeDirectory .*flags=.*runtime", details, re.M)
    )
    if not hardened_runtime:
        raise VerificationError("The candidate is not signed with hardened runtime.")
    return SignatureIdentity(
        identifier=identifier,
        team_identifier=team_identifier,
        authority=authority,
        cdhash=cdhash.lower(),
        hardened_runtime=True,
    )


def require_canonical_existing_path(path: Path, *, directory: bool) -> Path:
    if not path.is_absolute():
        raise VerificationError(f"Path must be absolute: {path}")
    reject_symlink_components(path)
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise VerificationError(f"Path is unavailable: {path}: {error}") from error
    if resolved != path:
        raise VerificationError(f"Path must be canonical and contain no aliases: {path}")
    if directory and not path.is_dir():
        raise VerificationError(f"Expected a directory: {path}")
    if not directory and not path.is_file():
        raise VerificationError(f"Expected a file: {path}")
    return path


def reject_symlink_components(path: Path) -> None:
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if current.exists() or current.is_symlink():
            if stat.S_ISLNK(os.lstat(current).st_mode):
                raise VerificationError(
                    f"Symlink path components are not allowed: {current}"
                )


def _verify_bundle_signature(
    bundle: Path,
    expected_identifier: str,
    expected_team_identifier: str,
    *,
    deep: bool,
    authority_prefixes: tuple[str, ...] = APP_STORE_AUTHORITY_PREFIXES,
    artifact_description: str = "candidate",
) -> SignatureIdentity:
    verify_command = ["/usr/bin/codesign", "--verify"]
    if deep:
        verify_command.append("--deep")
    verify_command.extend(["--strict", "--verbose=2", str(bundle)])
    verified = subprocess.run(
        verify_command,
        text=True,
        capture_output=True,
        check=False,
    )
    if verified.returncode != 0:
        raise VerificationError(
            f"Strict code-signature verification failed for {bundle}: "
            f"{_bounded_text(verified.stderr)}"
        )

    details_result = subprocess.run(
        ["/usr/bin/codesign", "-dv", "--verbose=4", str(bundle)],
        text=True,
        capture_output=True,
        check=False,
    )
    details = details_result.stdout + details_result.stderr
    if details_result.returncode != 0:
        raise VerificationError(
            f"Could not read the code-signature identity for {bundle}."
        )
    return parse_signature_identity(
        details,
        expected_identifier=expected_identifier,
        expected_team_identifier=expected_team_identifier,
        authority_prefixes=authority_prefixes,
        artifact_description=artifact_description,
    )


def _split_entitlements(
    entitlements: dict[str, object],
) -> tuple[dict[str, object], dict[str, object]]:
    feature = {
        key: value
        for key, value in entitlements.items()
        if key not in SIGNING_ONLY_ENTITLEMENT_KEYS
    }
    signing = {
        key: value
        for key, value in entitlements.items()
        if key in SIGNING_ONLY_ENTITLEMENT_KEYS
    }
    return feature, signing


def _validate_signing_entitlements(
    signing: dict[str, object],
    *,
    description: str,
    expected_bundle_identifier: str,
    require_identity: bool,
    expected_get_task_allow: bool,
    require_get_task_allow: bool = False,
) -> None:
    expected_application_identifier = (
        f"{DEFAULT_TEAM_IDENTIFIER}.{expected_bundle_identifier}"
    )
    expected_values = {
        "com.apple.application-identifier": expected_application_identifier,
        "com.apple.developer.team-identifier": DEFAULT_TEAM_IDENTIFIER,
    }
    for key, expected in expected_values.items():
        if key not in signing:
            if require_identity:
                raise VerificationError(
                    f"The {description} signing entitlement {key} is missing."
                )
            continue
        if signing[key] != expected:
            raise VerificationError(
                f"The {description} signing entitlement {key} is invalid."
            )
    task_key = "com.apple.security.get-task-allow"
    if task_key not in signing:
        if require_get_task_allow:
            raise VerificationError(
                f"The {description} signing entitlement {task_key} is missing."
            )
        return
    task_value = signing[task_key]
    if type(task_value) is not bool or task_value is not expected_get_task_allow:
        expected = "enabled" if expected_get_task_allow else "disabled"
        raise VerificationError(
            f"The {description} must have boolean get-task-allow {expected}."
        )


def _require_bundle_identity(
    bundle: Path,
    *,
    expected_identifier: str,
    expected_version: str | None = None,
    expected_build: str | None = None,
) -> None:
    plist_path = bundle / "Contents/Info.plist"
    if not plist_path.is_file() or plist_path.is_symlink():
        raise VerificationError(f"Missing regular bundle Info.plist: {plist_path}")
    try:
        with plist_path.open("rb") as stream:
            metadata = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise VerificationError(f"Could not parse {plist_path}: {error}") from error
    if metadata.get("CFBundleIdentifier") != expected_identifier:
        raise VerificationError(f"Unexpected CFBundleIdentifier in {plist_path}.")
    if (
        expected_version is not None
        and metadata.get("CFBundleShortVersionString") != expected_version
    ):
        raise VerificationError(f"Unexpected release version in {plist_path}.")
    if (
        expected_build is not None
        and metadata.get("CFBundleVersion") != expected_build
    ):
        raise VerificationError(f"Unexpected build number in {plist_path}.")


def _read_source_identity(plist_path: Path, *, description: str) -> SourceIdentity:
    if not plist_path.is_file() or plist_path.is_symlink():
        raise VerificationError(f"{description} must be a regular file: {plist_path}")
    try:
        with plist_path.open("rb") as stream:
            metadata = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise VerificationError(f"Could not parse {plist_path}: {error}") from error
    source_commit = metadata.get(ARCHIVE_SOURCE_COMMIT_KEY)
    source_snapshot = metadata.get(ARCHIVE_SOURCE_SHA256_KEY)
    if not isinstance(source_commit, str) or not re.fullmatch(
        r"[0-9a-f]{40}", source_commit
    ):
        raise VerificationError(
            f"{description} does not contain a valid source commit."
        )
    if not isinstance(source_snapshot, str):
        raise VerificationError(
            f"{description} does not contain a valid source snapshot."
        )
    try:
        normalized_snapshot = normalize_sha256(
            source_snapshot,
            description=f"{description} source snapshot SHA-256",
        )
    except VerificationError as error:
        raise VerificationError(
            f"{description} does not contain a valid source snapshot."
        ) from error
    return SourceIdentity(source_commit, normalized_snapshot)


def _require_regular_executable(path: Path) -> None:
    canonical = require_canonical_existing_path(path, directory=False)
    metadata = os.lstat(canonical)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise VerificationError(
            f"Candidate executable is not a single regular file: {path}"
        )
    if not os.access(canonical, os.X_OK):
        raise VerificationError(f"Candidate executable is not executable: {path}")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise VerificationError(
            f"Candidate executable is group/other writable: {path}"
        )


def _single_field(
    fields: dict[str, list[str]],
    key: str,
    *,
    allow_multiple: bool = False,
) -> str:
    values = fields.get(key, [])
    if not values or (not allow_multiple and len(values) != 1):
        raise VerificationError(
            f"Code-signature field {key} is missing or ambiguous."
        )
    return values[0]


def _bounded_text(value: str, limit: int = 600) -> str:
    normalized = " ".join(value.split())
    return normalized[:limit] if normalized else "no diagnostic"
