"""Exercise daily Debug signing without codesigning or launching an application."""

import copy
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lib.debug_runtime_signing import (
    APP_IDENTIFIER, APP_RELATIVE, ASKPASS_ENTITLEMENTS, XPC_ENTITLEMENTS,
    GET_TASK_ALLOW, TEST_ROOT_READ, TEST_MACH_LOOKUP,
    DEFAULT_FOLDER_ENTITLEMENTS,
    COMPANION_XPC_RELATIVE, COMPANION_XPC_IDENTIFIER,
    DebugRuntimeError, DebugRuntimeSigning,
)


class DebugRuntimeSigningTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="jts-debug-sign-test.")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        (self.root / "JTSTerminal.xcodeproj").mkdir()
        self.app = self.root / APP_RELATIVE
        self.app.mkdir(parents=True)
        self.write_plist(self.app / "Contents/Info.plist", {"CFBundleIdentifier": APP_IDENTIFIER})
        self.write_plist(self.root / "JTSTerminal/JTSTerminal.entitlements", {"com.apple.security.app-sandbox": True})
        self.write_plist(self.root / "JTSSHAskpass/JTSSHAskpass.entitlements", ASKPASS_ENTITLEMENTS)
        self.write_plist(self.root / "JTFreeRDPService/JTFreeRDPService.entitlements", XPC_ENTITLEMENTS)
        self.write_plist(self.root / "JTCompanionTransportService/JTCompanionTransportService.entitlements", XPC_ENTITLEMENTS)
        self.askpass = self.app / "Contents/MacOS/JTSSHAskpass"
        self.askpass.parent.mkdir(parents=True)
        self.askpass.touch()
        self.xpc = self.app / "Contents/XPCServices/JTFreeRDPService.xpc"
        self.xpc.mkdir(parents=True)
        self.companion = self.app / COMPANION_XPC_RELATIVE
        self.companion.mkdir(parents=True)
        self.identifiers = {
            self.askpass: "com.lljts.JTSTerminal.SSHAskpass",
            self.xpc: "com.lljts.JTSTerminal.FreeRDPService",
            self.companion: COMPANION_XPC_IDENTIFIER,
            self.app: APP_IDENTIFIER,
        }
        self.expected = {
            self.askpass: ASKPASS_ENTITLEMENTS,
            self.xpc: dict(XPC_ENTITLEMENTS),
            self.companion: dict(XPC_ENTITLEMENTS),
            self.app: {"com.apple.security.app-sandbox": True, "com.apple.security.get-task-allow": True},
        }
        self.actual = copy.deepcopy(self.expected)
        self.calls = []
        self.team = "YOURTEAMID"
        self.processes = b""
        self.ignore_sign = False
        self.verification_failure = None
        self.deep_verification_failure = False
        self.no_runtime = None
        self.runtime = DebugRuntimeSigning(self.root, runner=self.run_command)

    def write_plist(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(value))

    def run_command(self, args, **kwargs):
        self.calls.append(args)
        output = b""
        error = b""
        status = 0
        path = Path(args[-1])
        if args[0] == "/bin/ps":
            output = self.processes
        elif "-dv" in args:
            flags = "0x0(none)" if path == self.no_runtime else "0x10000(runtime)"
            error = (
                f"Identifier={self.identifiers[path]}\nTeamIdentifier={self.team}\n"
                f"Authority=Apple Development: Test\nCodeDirectory v=20500 flags={flags}\n"
            ).encode()
        elif "--entitlements" in args and "--force" not in args:
            output = plistlib.dumps(self.actual[path])
        elif "--force" in args:
            if not self.ignore_sign:
                with Path(args[args.index("--entitlements") + 1]).open("rb") as stream:
                    self.actual[path] = plistlib.load(stream)
        elif any(arg.startswith("--extract-certificates=") for arg in args):
            prefix = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--extract-certificates="))
            Path(prefix + "0").write_bytes(b"test-leaf-certificate")
        elif "--verify" in args and (
            path == self.verification_failure or ("--deep" in args and self.deep_verification_failure)
        ):
            status, error = 1, b"code has been modified"
        return subprocess.CompletedProcess(args, status, output, error)

    def signed_paths(self):
        return [Path(call[-1]) for call in self.calls if "--force" in call]

    def test_normal_product_is_verified_without_resigning(self):
        self.assertEqual(APP_IDENTIFIER, "com.lljts.JTSTerminal.UITesting")
        self.assertIsNone(self.runtime.prepare_build())
        self.assertEqual(self.runtime.finalize(), [])
        self.assertEqual(self.signed_paths(), [])
        self.assertIn(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(self.app)], self.calls)

    def test_pre_default_folder_app_can_be_rebuilt_but_not_delivered_as_current(self):
        source = {"com.apple.security.app-sandbox": True, **DEFAULT_FOLDER_ENTITLEMENTS}
        self.write_plist(self.root / "JTSTerminal/JTSTerminal.entitlements", source)
        self.expected[self.app].update(DEFAULT_FOLDER_ENTITLEMENTS)
        self.assertIsNone(self.runtime.prepare_build())
        with self.assertRaisesRegex(DebugRuntimeError, "missing core"):
            self.runtime.finalize()
        self.assertEqual(self.signed_paths(), [])
        self.actual[self.app].update(DEFAULT_FOLDER_ENTITLEMENTS)
        self.assertEqual(self.runtime.finalize(), [])

    def test_default_folder_migration_rejects_partial_or_unknown_permissions(self):
        source = {"com.apple.security.app-sandbox": True, **DEFAULT_FOLDER_ENTITLEMENTS}
        self.write_plist(self.root / "JTSTerminal/JTSTerminal.entitlements", source)
        for key in DEFAULT_FOLDER_ENTITLEMENTS:
            with self.subTest(key=key):
                self.actual[self.app] = {**source, GET_TASK_ALLOW: True}
                del self.actual[self.app][key]
                with self.assertRaisesRegex(DebugRuntimeError, "missing core"):
                    self.runtime.prepare_build()
        self.actual[self.app] = {"com.apple.security.app-sandbox": True, GET_TASK_ALLOW: True, "unexpected": True}
        with self.assertRaisesRegex(DebugRuntimeError, "missing core"):
            self.runtime.prepare_build()
        self.assertEqual(self.signed_paths(), [])

    def test_test_entitlements_are_removed_from_all_helpers_before_outer_seal(self):
        for path in self.actual:
            self.actual[path]["com.apple.security.temporary-exception.files.absolute-path.read-only"] = ["/"]
            self.actual[path]["com.apple.security.temporary-exception.mach-lookup.global-name"] = ["com.apple.testmanagerd"]
        self.runtime.finalize()
        self.assertEqual(self.signed_paths(), [self.askpass, self.xpc, self.companion, self.app])
        self.assertEqual(self.actual, self.expected)
        self.assertFalse(any("--deep" in call for call in self.calls if "--force" in call))

    def test_repair_of_one_helper_reseals_outer_app(self):
        self.actual[self.askpass]["com.apple.security.get-task-allow"] = True
        self.runtime.finalize()
        self.assertEqual(self.signed_paths(), [self.askpass, self.app])

    def test_pre_companion_build_may_be_rebuilt_but_cannot_be_finalized(self):
        self.companion.rmdir()
        self.assertIsNone(self.runtime.prepare_build())
        with self.assertRaisesRegex(DebugRuntimeError, "Missing Debug artifact"):
            self.runtime.finalize()
        self.assertEqual(self.signed_paths(), [])

    def test_companion_helper_is_resealed_before_outer_app(self):
        self.actual[self.companion][GET_TASK_ALLOW] = True
        self.runtime.finalize()
        self.assertEqual(self.signed_paths(), [self.companion, self.app])

    def test_base_injection_disabled_only_adds_main_debug_permission_once(self):
        del self.actual[self.app][GET_TASK_ALLOW]
        self.assertIsNone(self.runtime.prepare_build())
        self.runtime.finalize()
        self.assertEqual(self.signed_paths(), [self.app])
        self.calls.clear()
        self.assertIsNone(self.runtime.prepare_build())
        self.assertEqual(self.runtime.finalize(), [])
        self.assertEqual(self.signed_paths(), [])

    def test_unknown_or_missing_core_entitlements_fail_before_any_mutation(self):
        cases = (
            {"unexpected": True},
            {"com.apple.security.app-sandbox": False},
            {"com.apple.security.app-sandbox": 1},
            {TEST_ROOT_READ: ["/", "/tmp"]},
            {TEST_ROOT_READ: "/"},
            {TEST_MACH_LOOKUP: ["com.apple.testmanagerd", "unknown.service"]},
            {TEST_MACH_LOOKUP: []},
            {TEST_MACH_LOOKUP: "com.apple.testmanagerd"},
            {TEST_MACH_LOOKUP: [1]},
            {GET_TASK_ALLOW: False},
            {GET_TASK_ALLOW: 1},
        )
        for path in self.actual:
            for difference in cases:
                with self.subTest(path=path, difference=difference):
                    self.actual = copy.deepcopy(self.expected)
                    self.actual[path].update(difference)
                    for action in (self.runtime.prepare_build, self.runtime.finalize):
                        with self.assertRaisesRegex(DebugRuntimeError, "Unknown"):
                            action()
                    self.assertTrue(self.app.exists())
                    self.assertEqual(self.signed_paths(), [])
            for key in self.expected[path]:
                if path == self.app and key == GET_TASK_ALLOW:
                    continue
                with self.subTest(path=path, missing=key):
                    self.actual = copy.deepcopy(self.expected)
                    del self.actual[path][key]
                    for action in (self.runtime.prepare_build, self.runtime.finalize):
                        with self.assertRaisesRegex(DebugRuntimeError, "missing core"):
                            action()
                    self.assertTrue(self.app.exists())
                    self.assertEqual(self.signed_paths(), [])

    def test_known_mach_names_are_the_only_allowed_service_exceptions(self):
        self.actual[self.askpass][TEST_MACH_LOOKUP] = [
            "com.apple.testmanagerd", "com.apple.dt.testmanagerd.runner", "com.apple.coresymbolicationd",
        ]
        self.runtime.finalize()
        self.assertEqual(self.actual, self.expected)

    def test_instrumented_bundle_is_quarantined_before_normal_build(self):
        payload = self.app / "Contents/Frameworks/libXCTestBundleInject.dylib"
        payload.parent.mkdir()
        payload.write_bytes(b"test instrumentation")
        quarantined = self.runtime.prepare_build()
        self.assertFalse(self.app.exists())
        self.assertEqual(quarantined.name, "JTS Terminal.quarantine")
        self.assertEqual((quarantined / "Contents/Frameworks" / payload.name).read_bytes(), b"test instrumentation")
        self.assertEqual(self.signed_paths(), [])

    def test_formal_product_identity_is_not_rewritten_into_debug_container(self):
        self.write_plist(self.app / "Contents/Info.plist", {"CFBundleIdentifier": "com.lljts.JTSTerminal"})
        with self.assertRaisesRegex(DebugRuntimeError, "preserve its existing 2.0 data container"):
            self.runtime.prepare_build()
        self.assertTrue(self.app.exists())
        self.assertEqual(self.calls, [])

    def test_extra_app_entitlements_alone_trigger_quarantine(self):
        self.actual[self.app]["com.apple.security.temporary-exception.files.absolute-path.read-only"] = ["/"]
        self.assertTrue(self.runtime.prepare_build().exists())

    def test_test_payload_cannot_hide_invalid_identity_signature_or_unknown_entitlements(self):
        (self.app / "Contents/PlugIns/Tests.xctest").mkdir(parents=True)
        self.team = "OTHERTEAM1"
        with self.assertRaisesRegex(DebugRuntimeError, "signing identity"):
            self.runtime.prepare_build()
        self.team = "YOURTEAMID"
        for path in self.actual:
            with self.subTest(path=path):
                self.no_runtime = path
                with self.assertRaisesRegex(DebugRuntimeError, "runtime flags"):
                    self.runtime.prepare_build()
                self.no_runtime = None
                original = self.identifiers[path]
                self.identifiers[path] = "unexpected.identifier"
                with self.assertRaisesRegex(DebugRuntimeError, "signing identity"):
                    self.runtime.prepare_build()
                self.identifiers[path] = original
                self.verification_failure = path
                with self.assertRaisesRegex(DebugRuntimeError, "code has been modified"):
                    self.runtime.prepare_build()
                self.verification_failure = None
        self.deep_verification_failure = True
        with self.assertRaisesRegex(DebugRuntimeError, "code has been modified"):
            self.runtime.prepare_build()
        self.deep_verification_failure = False
        self.actual[self.app]["unexpected"] = True
        with self.assertRaisesRegex(DebugRuntimeError, "Unknown"):
            self.runtime.prepare_build()
        self.assertTrue(self.app.exists())
        self.assertFalse((self.root / "build/debug-quarantine").exists())
        self.assertEqual(self.signed_paths(), [])

    def test_instrumented_payload_cannot_be_relabelled_as_daily_app(self):
        (self.app / "Contents/PlugIns/Tests.xctest").mkdir(parents=True)
        with self.assertRaisesRegex(DebugRuntimeError, "Instrumented test host"):
            self.runtime.finalize()
        self.assertEqual(self.calls, [])

    def test_wrong_team_or_invalid_existing_signature_cannot_be_repaired(self):
        self.actual[self.askpass]["unexpected"] = True
        self.team = "OTHERTEAM1"
        with self.assertRaisesRegex(DebugRuntimeError, "signing identity"):
            self.runtime.finalize()
        self.team = "YOURTEAMID"
        self.verification_failure = self.askpass
        with self.assertRaisesRegex(DebugRuntimeError, "code has been modified"):
            self.runtime.finalize()
        self.assertEqual(self.signed_paths(), [])

    def test_running_product_is_not_mutated(self):
        self.actual[self.askpass][GET_TASK_ALLOW] = True
        self.processes = f"123 {self.app}/Contents/MacOS/JTS Terminal\n".encode()
        with self.assertRaisesRegex(DebugRuntimeError, "still running"):
            self.runtime.finalize()
        self.assertEqual(self.signed_paths(), [])

    def test_signer_success_without_exact_entitlements_does_not_pass(self):
        self.actual[self.askpass][GET_TASK_ALLOW] = True
        self.ignore_sign = True
        with self.assertRaisesRegex(DebugRuntimeError, "not exact after signing"):
            self.runtime.finalize()

    def test_symlink_product_path_fails_before_any_command(self):
        self.askpass.unlink()
        outside = self.root / "outside-helper"
        outside.touch()
        self.askpass.symlink_to(outside)
        with self.assertRaisesRegex(DebugRuntimeError, "symlink"):
            self.runtime.finalize()
        self.assertEqual(self.calls, [])

    def test_daily_builder_prepares_then_builds_then_verifies_before_retention(self):
        script = (Path(__file__).resolve().parents[2] / "script/build_and_run.sh").read_text()
        build = script.split("build_app() {", 1)[1].split("\nretain_latest_products()", 1)[0]
        self.assertLess(build.index("--prepare-build"), build.index("xcodebuild"))
        self.assertIn("CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO", build)
        self.assertEqual(build.count("scripts/prepare_debug_runtime.py"), 2)
        self.assertLess(build.rindex("scripts/prepare_debug_runtime.py"), build.index("retain_latest_products"))


if __name__ == "__main__":
    unittest.main()
