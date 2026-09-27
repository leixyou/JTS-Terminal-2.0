"""Keep the daily Debug application separate from Xcode's instrumented hosts."""

from __future__ import annotations

import hashlib
import plistlib
import re
import subprocess
import tempfile
import uuid
from pathlib import Path


APP_RELATIVE = Path("DerivedData/Run/Build/Products/Debug/JTS Terminal.app")
# The daily 2.0 Debug product deliberately has its own existing data container.
# Its historical suffix is not evidence that Xcode injected a test host.
APP_IDENTIFIER = "com.lljts.JTSTerminal.UITesting"
TEAM_IDENTIFIER = "YOURTEAMID"
ASKPASS_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.inherit": True,
}
XPC_ENTITLEMENTS = {
    "com.apple.security.app-sandbox": True,
    "com.apple.security.network.client": True,
}
COMPANION_XPC_RELATIVE = Path("Contents/XPCServices/JTCompanionTransportService.xpc")
COMPANION_XPC_IDENTIFIER = "com.lljts.JTSTerminal.CompanionTransportService"
TEST_FRAMEWORKS = {
    "Testing.framework", "XCTest.framework", "XCTestCore.framework",
    "XCTestSupport.framework", "XCUIAutomation.framework",
    "XCUnit.framework", "XCTAutomationSupport.framework", "libXCTestBundleInject.dylib",
    "libXCTestSwiftSupport.dylib",
}
GET_TASK_ALLOW = "com.apple.security.get-task-allow"
DEFAULT_FOLDER_ENTITLEMENTS = {
    "com.apple.security.files.downloads.read-write": True,
    "com.apple.security.assets.pictures.read-write": True,
    "com.apple.security.assets.music.read-write": True,
    "com.apple.security.assets.movies.read-write": True,
}
TEST_ROOT_READ = "com.apple.security.temporary-exception.files.absolute-path.read-only"
TEST_MACH_LOOKUP = "com.apple.security.temporary-exception.mach-lookup.global-name"
TEST_MACH_NAMES = {
    "com.apple.testmanagerd", "com.apple.dt.testmanagerd.runner",
    "com.apple.coresymbolicationd",
}


def exact_entitlements(actual: dict, expected: dict) -> bool:
    # plist booleans and integers are not interchangeable signing permissions.
    return plistlib.dumps(actual) == plistlib.dumps(expected)


class DebugRuntimeError(RuntimeError):
    pass


class DebugRuntimeSigning:
    def __init__(self, root: Path, *, runner=subprocess.run):
        self.root = root.resolve()
        self.app = self.root / APP_RELATIVE
        self.runner = runner
        if not (self.root / "JTSTerminal.xcodeproj").is_dir():
            raise DebugRuntimeError("Expected the JTS Terminal repository root.")
        for source, expected in (
            ("JTSSHAskpass/JTSSHAskpass.entitlements", ASKPASS_ENTITLEMENTS),
            ("JTFreeRDPService/JTFreeRDPService.entitlements", XPC_ENTITLEMENTS),
            ("JTCompanionTransportService/JTCompanionTransportService.entitlements", XPC_ENTITLEMENTS),
        ):
            with (self.root / source).open("rb") as stream:
                if not exact_entitlements(plistlib.load(stream), expected):
                    raise DebugRuntimeError(f"Helper source entitlements are not exact: {source}")

    def command(self, *arguments: str) -> bytes:
        result = self.runner(list(arguments), capture_output=True, check=False)
        if result.returncode:
            raise DebugRuntimeError(
                f"{Path(arguments[0]).name} failed: "
                + result.stderr.decode("utf-8", errors="replace").strip()
            )
        return result.stdout

    def safe_path(self, path: Path) -> None:
        if path.resolve() != path:
            raise DebugRuntimeError(f"Debug product path contains a symlink: {path}")

    def entitlements(self, path: Path) -> dict:
        data = self.command("/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(path))
        try:
            value = plistlib.loads(data)
        except (ValueError, plistlib.InvalidFileException) as error:
            raise DebugRuntimeError(f"Cannot read entitlements: {path}") from error
        if not isinstance(value, dict):
            raise DebugRuntimeError(f"Entitlements are not a dictionary: {path}")
        return value

    def app_entitlements(self) -> dict:
        with (self.root / "JTSTerminal/JTSTerminal.entitlements").open("rb") as stream:
            expected = plistlib.load(stream)
        # This is the sole extra entitlement for a normal, LLDB-debuggable app.
        # TestManager's root-read and Mach exceptions must never survive here.
        return {**expected, GET_TASK_ALLOW: True}

    def artifacts(self) -> list[tuple[Path, str, dict]]:
        return [
            (self.app / "Contents/MacOS/JTSSHAskpass", "com.lljts.JTSTerminal.SSHAskpass", ASKPASS_ENTITLEMENTS),
            (self.app / "Contents/XPCServices/JTFreeRDPService.xpc", "com.lljts.JTSTerminal.FreeRDPService", XPC_ENTITLEMENTS),
            (self.app / COMPANION_XPC_RELATIVE, COMPANION_XPC_IDENTIFIER, XPC_ENTITLEMENTS),
            (self.app, APP_IDENTIFIER, self.app_entitlements()),
        ]

    def require_known_entitlements(
        self, path: Path, actual: dict, expected: dict, *, allow_pre_default_folders: bool = False,
    ) -> bool:
        """Return test-injection evidence, rejecting every other signing drift."""
        normalized = actual.copy()
        injected = False
        if TEST_ROOT_READ in normalized:
            if normalized.pop(TEST_ROOT_READ) != ["/"]:
                raise DebugRuntimeError(f"Unknown root-read entitlement: {path}")
            injected = True
        if TEST_MACH_LOOKUP in normalized:
            names = normalized.pop(TEST_MACH_LOOKUP)
            if not isinstance(names, list) or not names or not all(
                isinstance(name, str) and name in TEST_MACH_NAMES for name in names
            ):
                raise DebugRuntimeError(f"Unknown Mach-lookup entitlement: {path}")
            injected = True
        if path == self.app:
            # Normal Xcode builds with base injection disabled omit this sole
            # Debug permission. Adding it does not change the app's container.
            if GET_TASK_ALLOW not in normalized:
                normalized[GET_TASK_ALLOW] = True
            # A cached app from before default-folder access is a valid input
            # to a new build. Only accept the exact prior permission set here;
            # finalization must still require every newly signed entitlement.
            if allow_pre_default_folders and all(
                expected.get(key) is True and key not in normalized
                for key in DEFAULT_FOLDER_ENTITLEMENTS
            ):
                normalized.update(DEFAULT_FOLDER_ENTITLEMENTS)
        elif GET_TASK_ALLOW in normalized:
            if normalized.pop(GET_TASK_ALLOW) is not True:
                raise DebugRuntimeError(f"Unknown helper debug entitlement: {path}")
            injected = True
        if not exact_entitlements(normalized, expected):
            raise DebugRuntimeError(f"Unknown or missing core Debug entitlements: {path}")
        return injected

    def verified_artifacts(
        self, *, allow_pre_default_folders: bool = False, allow_pre_companion_transport: bool = False,
    ) -> list[tuple[Path, str, dict, dict, bool]]:
        artifacts = self.artifacts()
        if allow_pre_companion_transport:
            # A still-valid pre-2.5 daily build may lack the new helper before rebuilding.
            # Finalization always requires it; a symlink or malformed existing helper is never skipped.
            companion = self.app / COMPANION_XPC_RELATIVE
            if not companion.exists() and not companion.is_symlink():
                artifacts = [item for item in artifacts if item[0] != companion]
        for path, identifier, _ in artifacts:
            self.safe_path(path)
            if not path.exists():
                raise DebugRuntimeError(f"Missing Debug artifact: {path}")
            self.signature(path, identifier)
            self.command("/usr/bin/codesign", "--verify", "--strict", str(path))
        # Check nested code/resource integrity before moving or signing anything.
        self.command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.app))
        verified = []
        for path, identifier, expected in artifacts:
            actual = self.entitlements(path)
            injected = self.require_known_entitlements(
                path, actual, expected, allow_pre_default_folders=allow_pre_default_folders,
            )
            verified.append((path, identifier, expected, actual, injected))
        return verified

    def test_payloads(self) -> list[Path]:
        contents = self.app / "Contents"
        payloads = list((contents / "PlugIns").glob("*.xctest"))
        frameworks = contents / "Frameworks"
        payloads.extend(frameworks / name for name in TEST_FRAMEWORKS if (frameworks / name).exists())
        return payloads

    def require_idle(self) -> None:
        output = self.command("/bin/ps", "-ww", "-axo", "pid=,comm=").decode("utf-8", errors="replace")
        for line in output.splitlines():
            fields = line.strip().split(None, 1)
            if len(fields) == 2 and fields[1].startswith(str(self.app) + "/"):
                raise DebugRuntimeError(f"Daily Debug product is still running (pid {fields[0]}).")

    def prepare_build(self) -> Path | None:
        """Quarantine a cached test host; normal build recreates just this app."""
        self.safe_path(self.app)
        if not self.app.exists():
            return None
        with (self.app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("CFBundleIdentifier") != APP_IDENTIFIER:
            raise DebugRuntimeError("Unexpected daily Debug identifier; preserve its existing 2.0 data container.")
        verified = self.verified_artifacts(allow_pre_default_folders=True, allow_pre_companion_transport=True)
        contaminated = bool(self.test_payloads()) or any(item[4] for item in verified)
        if not contaminated:
            return None
        self.require_idle()
        quarantine = self.root / "build/debug-quarantine" / uuid.uuid4().hex / "JTS Terminal.quarantine"
        self.safe_path(quarantine)
        quarantine.parent.mkdir(parents=True)
        self.app.rename(quarantine)
        return quarantine

    def signature(self, path: Path, identifier: str) -> None:
        result = self.runner(
            ["/usr/bin/codesign", "-dv", "--verbose=4", str(path)],
            capture_output=True, check=False,
        )
        details = (result.stdout + result.stderr).decode("utf-8", errors="replace")
        if result.returncode or not all((
            f"Identifier={identifier}\n" in details,
            f"TeamIdentifier={TEAM_IDENTIFIER}\n" in details,
            re.search(r"^Authority=Apple Development:", details, re.MULTILINE),
            re.search(r"^CodeDirectory .*flags=.*runtime", details, re.MULTILINE),
        )):
            raise DebugRuntimeError(f"Unexpected Debug signing identity or runtime flags: {path}")

    def finalize(self) -> list[str]:
        self.safe_path(self.app)
        with (self.app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if info.get("CFBundleIdentifier") != APP_IDENTIFIER or self.test_payloads():
            raise DebugRuntimeError("Instrumented test host cannot be used as the daily Debug app; run the normal build preparation first.")
        verified = self.verified_artifacts()
        artifacts = [(path, identifier, expected) for path, identifier, expected, _, _ in verified]
        changed = [(path, identifier, expected) for path, identifier, expected, actual, _ in verified
                   if not exact_entitlements(actual, expected)]
        if changed:
            self.require_idle()
            # Reuse the app's exact leaf certificate, not an ambiguous keychain label.
            with tempfile.TemporaryDirectory(prefix="jts-debug-signing.") as temporary:
                staging = Path(temporary)
                prefix = staging / "leaf-"
                self.command("/usr/bin/codesign", "-d", f"--extract-certificates={prefix}", str(self.app))
                identity = hashlib.sha1(Path(str(prefix) + "0").read_bytes()).hexdigest().upper()
                if not any(path == self.app for path, _, _ in changed):
                    changed.append(artifacts[-1])
                for index, (path, identifier, expected) in enumerate(changed):
                    entitlement_file = staging / f"entitlements-{index}.plist"
                    with entitlement_file.open("wb") as stream:
                        plistlib.dump(expected, stream)
                    self.command(
                        "/usr/bin/codesign", "--force", "--sign", identity,
                        "--identifier", identifier, "--entitlements", str(entitlement_file),
                        "--options", "runtime", "--timestamp=none", "--generate-entitlement-der", str(path),
                    )
        for path, identifier, expected in artifacts:
            if not exact_entitlements(self.entitlements(path), expected):
                raise DebugRuntimeError(f"Debug entitlements are not exact after signing: {path}")
            self.signature(path, identifier)
            self.command("/usr/bin/codesign", "--verify", "--strict", str(path))
        self.command("/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.app))
        return [str(path) for path, _, _ in changed]
