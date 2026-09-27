"""Check process selection without launching or terminating any real app."""

from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DebugLaunchProcessScopeTests(unittest.TestCase):
    def test_launch_built_verifies_before_open_and_stops_on_failure(self):
        source = (ROOT / "script/build_and_run.sh").read_text()
        dispatch = 'case "$MODE" in' + source.split('case "$MODE" in', 1)[1]
        for status in [0, 1]:
            stubs = f'''set -e
MODE=--launch-built
stop_existing_app() {{ echo stop; }}
verify_built_app() {{ echo verify; return {status}; }}
build_app() {{ echo unexpected-build; return 99; }}
open_app() {{ echo open; }}
verify_app() {{ echo launched; }}
'''
            result = subprocess.run(["bash", "-c", stubs + dispatch],
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, status)
            self.assertEqual(result.stdout, "stop\nverify\n" + ("open\nlaunched\n" if status == 0 else ""))

    def test_only_canonical_gui_is_selected_not_mcp_test_host_or_12(self):
        source = (ROOT / "script/build_and_run.sh").read_text()
        selector = "running_gui_app_pids() {" + source.split(
            "running_gui_app_pids() {", 1
        )[1].split("\nhas_running_gui_app()", 1)[0]
        fixture = r'''
APP_NAME="JTS Terminal"
APP_BINARY="/fixture/JTSTerminal-2.0/DerivedData/Run/JTS Terminal.app/Contents/MacOS/JTS Terminal"
pgrep() { printf '%s\n' 100 101 102 103; }
ps() {
  case "$2:$4" in
    100:comm=|102:comm=) printf '%s\n' "$APP_BINARY" ;;
    100:args=) printf '%s\n' "$APP_BINARY" ;;
    102:args=) printf '%s\n' "$APP_BINARY --mcp" ;;
    101:comm=) printf '%s\n' '/fixture/JTSTerminal/DerivedData/Run/JTS Terminal.app/Contents/MacOS/JTS Terminal' ;;
    103:comm=) printf '%s\n' '/fixture/JTSTerminal-2.0/DerivedData/Tests/JTS Terminal.app/Contents/MacOS/JTS Terminal' ;;
    *) return 1 ;;
  esac
}
'''
        result = subprocess.run(
            ["bash", "-c", fixture + selector + "\nrunning_gui_app_pids\n"],
            capture_output=True, text=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "100\n")


if __name__ == "__main__":
    unittest.main()
