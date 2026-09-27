"""Exercise acceptance scope without compiling or launching the app."""

from pathlib import Path
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class MacOSAcceptanceRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="jts-acceptance-runner.")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.calls = self.root / "calls.jsonl"
        self.scripts = self.root / "scripts"
        self.scripts.mkdir()
        self.runner = self.scripts / "run_macos_tests.sh"
        shutil.copy2(ROOT / "scripts/run_macos_tests.sh", self.runner)
        self.developer = self.root / "Developer"
        self.bin = self.developer / "usr/bin"
        self.bin.mkdir(parents=True)
        self.stub("xcodebuild", """
if 'build-for-testing' in args:
    products = Path(args[args.index('-derivedDataPath') + 1]) / 'Build/Products/Debug'
    (products / 'JTSTerminalRDP2Tests.xctest').mkdir(parents=True)
if 'test-without-building' in args:
    sys.exit(int(os.environ.get('STUB_TESTMANAGER_STATUS', '0')))
""")
        self.stub("xctest", "")
        self.stub("xcrun", """
if args == ['--find', 'xctest']:
    print(Path(sys.argv[0]).with_name('xctest'))
    sys.exit(0)
print(json.dumps({'result': 'Passed',
                  'totalTestCount': int(os.environ.get('STUB_TEST_COUNT', '2')),
                  'passedTests': int(os.environ.get('STUB_TEST_COUNT', '2'))}))
""")
        self.write_stub(
            self.scripts / "retain_latest_debug_and_release.py", "retention", ""
        )

    def stub(self, name, body):
        self.write_stub(self.bin / name, name, body)

    def write_stub(self, path, name, body):
        path.write_text(
            f"#!{sys.executable}\nimport json, os, sys\nfrom pathlib import Path\n"
            f"with open({str(self.calls)!r}, 'a') as log:\n"
            f"    log.write(json.dumps([{name!r}, *sys.argv[1:]]) + '\\n')\n"
            "args = sys.argv[1:]\n" + body,
            encoding="utf-8",
        )
        path.chmod(0o755)

    def run_runner(self, *arguments, **environment):
        env = os.environ.copy()
        # A fake DEVELOPER_DIR redirects macOS's /usr/bin/python3 shim too.
        # Stub xcrun discovery instead so no real XCTest process is launched.
        env.pop("DEVELOPER_DIR", None)
        env.update(
            PATH=f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            JTS_MACOS_TEST_ARTIFACT_ROOT=str(self.root / "logs"),
            JTS_MACOS_TEST_DESTINATION="platform=macOS",
            **environment,
        )
        result = subprocess.run(
            ["bash", str(self.runner), *arguments], env=env,
            capture_output=True, text=True, timeout=15,
        )
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()] \
            if self.calls.exists() else []
        return result, calls

    def test_default_runs_unit_bundle_once_and_retains_products_afterwards(self):
        result, calls = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([call[0] for call in calls], ["xcrun", "xcodebuild", "xctest", "retention"])
        self.assertIn("-only-testing:JTSTerminalRDP2Tests", calls[1])
        self.assertIn(str(self.root / "DerivedData/Tests"), calls[1])
        self.assertNotIn("--keep-app", calls[-1])

    def test_selection_runs_once_in_xcode_without_direct_or_supplemental_pass(self):
        selected = (
            "JTSTerminalRDP2Tests/AboutTests",
            "JTSTerminalRDP2Tests/BuildTests/dateIsFormatted()",
        )
        result, calls = self.run_runner(
            "--only-testing", selected[0], "--only-testing", selected[1],
            "--require-testmanager",
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([call[0] for call in calls], ["xcrun", "xcodebuild", "xcrun", "retention"])
        self.assertEqual(calls[1][-1], "test")
        for identifier in selected:
            self.assertIn(f"-only-testing:{identifier}", calls[1])
        self.assertNotIn("-only-testing:JTSTerminalRDP2Tests", calls[1])

    def test_empty_selection_result_cannot_be_reported_as_passing(self):
        result, calls = self.run_runner(
            "--only-testing", "JTSTerminalRDP2Tests/MissingTests", STUB_TEST_COUNT="0"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not all execute and pass", result.stderr)
        self.assertEqual(calls[-1][0], "retention")

    def test_method_without_parentheses_is_normalized_without_expanding_scope(self):
        selector = "JTSTerminalRDP2Tests/BuildTests/dateIsFormatted"
        result, calls = self.run_runner("--only-testing", selector)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([call[0] for call in calls], ["xcrun", "xcodebuild", "xcrun", "retention"])
        self.assertIn(f"-only-testing:{selector}()", calls[1])
        self.assertNotIn(f"-only-testing:{selector}", calls[1])
        self.assertNotIn("-only-testing:JTSTerminalRDP2Tests", calls[1])

    def test_raw_filters_ui_selectors_and_whole_target_fail_before_build(self):
        for arguments in (
            ("--", "-only-testing:JTSTerminalRDP2Tests/AboutTests"),
            ("--", "-skip-testing:JTSTerminalRDP2Tests/AboutTests"),
            ("--only-testing", "JTSTerminalRDP2UITests/AboutTests"),
            ("--only-testing", "JTSTerminalRDP2Tests"),
            ("--only-testing", "JTSTerminalRDP2Tests/*"),
            ("--skip-testmanager", "--require-testmanager"),
            ("--require-testmanager", "--skip-testmanager"),
        ):
            with self.subTest(arguments=arguments):
                result, calls = self.run_runner(*arguments)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(calls, [])

    def test_daily_debug_cache_and_alias_are_rejected_before_build(self):
        daily = self.root / "DerivedData/Run"
        daily.mkdir(parents=True)
        alias = self.root / "test-cache-alias"
        alias.symlink_to(daily, target_is_directory=True)
        for path in (daily, daily / "nested", daily.parent, alias):
            with self.subTest(path=path):
                result, calls = self.run_runner("--derived-data", str(path))
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("separate from DerivedData/Run", result.stderr)
                self.assertEqual(calls, [])

    def test_explicit_testmanager_failure_is_propagated_and_retention_still_runs(self):
        result, calls = self.run_runner("--require-testmanager", STUB_TESTMANAGER_STATUS="65")
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertEqual(
            [call[0] for call in calls], ["xcrun", "xcodebuild", "xctest", "xcodebuild", "retention"]
        )
        self.assertIn("test-without-building", calls[3])

    def test_optional_diagnostic_timeout_does_not_invalidate_passed_unit_gate(self):
        result, calls = self.run_runner("--with-testmanager", STUB_TESTMANAGER_STATUS="124")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("not reported as a full TestManager pass", result.stderr)
        self.assertEqual(calls[-1][0], "retention")


if __name__ == "__main__":
    unittest.main()
