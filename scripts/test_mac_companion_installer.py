#!/usr/bin/env python3
"""Exercise an isolated installer copy with command mocks; never sudo or install globally."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''
import json, os, pathlib, shutil, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
fixture = pathlib.Path(os.environ["JTS_TEST_FIXTURE"])
with (fixture / "commands.jsonl").open("a") as log:
    log.write(json.dumps([name] + args) + "\n")
def setting(key, default): return os.environ.get("JTS_TEST_" + key, default)
if name == "uname": print("Darwin")
elif name == "sw_vers": print(setting("OS", "14.0"))
elif name == "id": print(setting("ROOT_UID", "0") if len(args) == 1 else setting("CONSOLE_UID", "501"))
elif name == "stat": print(setting("CONSOLE_USER", "alice"))
elif name == "pkgutil":
    if args[0] == "--check-signature":
        mode = setting("SIGNATURE", "trusted")
        if mode == "trusted": print("Status: signed by a developer certificate issued by Apple for distribution")
        elif mode == "unsigned": print("Status: no signature"); sys.exit(1)
        elif mode == "untrusted": print("Status: signed by a certificate that is not trusted"); sys.exit(1)
        else: print("Error: invalid archive signature"); sys.exit(1)
    elif args[0] == "--expand-full":
        if setting("CORRUPT", "0") == "1": sys.exit(1)
        expanded = pathlib.Path(args[2])
        component = expanded / "MacCompanion.pkg"
        component.mkdir(parents=True)
        distribution = (fixture / "Distribution.xml").read_text()
        if setting("EXTERNAL_PACKAGE", "0") == "1": distribution = distribution.replace("MacCompanion.pkg", "https://example.invalid/other.pkg")
        if setting("DISTRIBUTION_SCRIPT", "0") == "1": distribution = distribution.replace("</installer-gui-script>", '<installation-check script="true"/></installer-gui-script>')
        (expanded / "Distribution").write_text(distribution)
        (component / "PackageInfo").write_text('<pkg-info identifier="' + setting("PACKAGE_ID", "com.jtstools.mac-companion") + '" install-location="/Applications"/>')
        shutil.copytree(fixture / "payload", component / "Payload")
        if setting("SCRIPTS", "0") == "1": (component / "Scripts").mkdir()
elif name == "spctl": sys.exit(int(setting("GATEKEEPER_FAIL", "0")))
elif name == "codesign": sys.exit(int(setting("CODESIGN_FAIL", "0")))
elif name == "ps":
    if setting("RUNNING", "0") == "1": print("/Applications/JTS Mac Companion.app/Contents/MacOS/JTSMacCompanion")
elif name == "installer":
    if setting("INSTALL_FAIL", "0") == "1": sys.exit(1)
    shutil.copytree(fixture / "payload" / "JTS Mac Companion.app", fixture / "Applications" / "JTS Mac Companion.app")
elif name == "launchctl":
    if args[0] == "print": sys.exit(int(setting("NO_GUI", "0")))
    sys.exit(subprocess.call(args[2:]))
elif name == "sudo":
    assert args[:2] == ["-H", "-u"]
    assert args[2] != "root"
    sys.exit(subprocess.call(args[3:]))
elif name == "open": sys.exit(int(setting("OPEN_FAIL", "0")))
else: raise RuntimeError("Unmocked command: " + name)
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="jts-installer-test-")
        self.addCleanup(self.temporary.cleanup)
        self.fixture = Path(self.temporary.name)
        self.bin = self.fixture / "bin"
        self.bin.mkdir()
        commands = {
            "/usr/bin/uname": "uname", "/usr/bin/sw_vers": "sw_vers", "/usr/bin/id": "id",
            "/usr/bin/stat": "stat", "/usr/sbin/pkgutil": "pkgutil", "/usr/sbin/spctl": "spctl",
            "/usr/bin/codesign": "codesign", "/usr/sbin/installer": "installer",
            "/bin/ps": "ps",
            "/bin/launchctl": "launchctl", "/usr/bin/sudo": "sudo", "/usr/bin/open": "open",
        }
        source = (ROOT / "MacCompanion/Installer/install.sh").read_text()
        for original, name in commands.items():
            tool = self.bin / name
            tool.write_text("#!" + sys.executable + "\n" + MOCK)
            tool.chmod(0o755)
            source = source.replace(original, str(tool))
        source = source.replace('app_path="/Applications/JTS Mac Companion.app"',
                                'app_path="' + str(self.fixture / "Applications/JTS Mac Companion.app") + '"')
        source = source.replace("/private/tmp/jtsmac-install.XXXXXX", str(self.fixture / "private-cache.XXXXXX"))
        self.script = self.fixture / "install.sh"
        self.script.write_text(source)
        (self.fixture / "Distribution.xml").write_text((ROOT / "MacCompanion/Installer/Distribution.xml").read_text())
        self.package = self.fixture / "JTS-Mac-Companion.pkg"
        self.package.write_bytes(b"mock package")
        bundle = self.fixture / "payload/JTS Mac Companion.app/Contents"
        bundle.mkdir(parents=True)
        (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.jtstools.mac-companion"}))

    def run_installer(self, *args, **settings):
        environment = dict(os.environ, JTS_TEST_FIXTURE=str(self.fixture), SUDO_USER="wrong-user")
        environment.update({"JTS_TEST_" + key: str(value) for key, value in settings.items()})
        return subprocess.run(["/bin/bash", str(self.script), *args], env=environment,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def commands(self, name):
        log = self.fixture / "commands.jsonl"
        if not log.exists(): return []
        return [entry for entry in map(json.loads, log.read_text().splitlines()) if entry[0] == name]

    def test_missing_package_rejected(self):
        self.package.unlink()
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(self.commands("installer"), [])

    def test_unsigned_rejected_by_default(self):
        self.assertNotEqual(self.run_installer(SIGNATURE="unsigned").returncode, 0)
        self.assertEqual(self.commands("installer"), [])

    def test_explicit_unsigned_development_install(self):
        result = self.run_installer("--allow-unsigned", "--no-launch", SIGNATURE="unsigned")
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = self.commands("installer")[0]
        self.assertEqual(installed[-2:], ["-target", "/"])
        self.assertNotEqual(installed[2], str(self.package))
        self.assertEqual(self.commands("open"), [])

    def test_corrupt_archive_rejected_even_with_unsigned_override(self):
        result = self.run_installer("--allow-unsigned", SIGNATURE="unsigned", CORRUPT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands("installer"), [])

    def test_untrusted_or_invalid_signature_cannot_be_overridden(self):
        for mode in ["untrusted", "invalid"]:
            self.assertNotEqual(self.run_installer("--allow-unsigned", SIGNATURE=mode).returncode, 0)
        self.assertEqual(self.commands("installer"), [])

    def test_gatekeeper_rejection_stops_install(self):
        self.assertNotEqual(self.run_installer(GATEKEEPER_FAIL="1").returncode, 0)
        self.assertEqual(self.commands("installer"), [])

    def test_wrong_product_and_privileged_scripts_rejected(self):
        self.assertNotEqual(self.run_installer(PACKAGE_ID="other.product").returncode, 0)
        self.assertNotEqual(self.run_installer(SCRIPTS="1").returncode, 0)
        self.assertEqual(self.commands("installer"), [])

    def test_invalid_app_signature_rejected(self):
        self.assertNotEqual(self.run_installer(CODESIGN_FAIL="1").returncode, 0)
        self.assertEqual(self.commands("installer"), [])

    def test_external_package_or_distribution_script_rejected(self):
        self.assertNotEqual(self.run_installer(EXTERNAL_PACKAGE="1").returncode, 0)
        self.assertNotEqual(self.run_installer(DISTRIBUTION_SCRIPT="1").returncode, 0)
        self.assertEqual(self.commands("installer"), [])

    def test_running_companion_blocks_upgrade_before_overwrite(self):
        result = self.run_installer(RUNNING="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Quit it", result.stderr)
        self.assertEqual(self.commands("installer"), [])
        self.assertEqual(self.commands("open"), [])

    def test_nonroot_and_old_system_rejected(self):
        self.assertNotEqual(self.run_installer(ROOT_UID="501").returncode, 0)
        self.assertNotEqual(self.run_installer(OS="13.6").returncode, 0)
        self.assertEqual(self.commands("installer"), [])

    def test_verify_only_is_unprivileged_and_does_not_install(self):
        result = self.run_installer("--verify-only", ROOT_UID="501")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands("installer"), [])
        self.assertEqual(self.commands("open"), [])

    def test_gui_launch_uses_console_user_never_sudo_user(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        asuser = [command for command in self.commands("launchctl") if command[1] == "asuser"][0]
        self.assertEqual(asuser[2], "501")
        self.assertEqual(self.commands("sudo")[0][1:4], ["-H", "-u", "alice"])
        self.assertEqual(self.commands("open")[0][-2:], ["--args", "--onboarding"])

    def test_no_console_user_defers_launch(self):
        result = self.run_installer(CONSOLE_USER="root")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands("open"), [])

    def test_gui_session_missing_defers_launch(self):
        result = self.run_installer(NO_GUI="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.commands("open"), [])

    def test_installer_failure_never_claims_success_or_launches(self):
        result = self.run_installer(INSTALL_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Installation complete", result.stdout)
        self.assertEqual(self.commands("open"), [])

    def test_launch_failure_reports_installed_state_and_exit_three(self):
        result = self.run_installer(OPEN_FAIL="1")
        self.assertEqual(result.returncode, 3)
        self.assertIn("Installation complete", result.stdout)


if __name__ == "__main__": unittest.main(verbosity=2)
