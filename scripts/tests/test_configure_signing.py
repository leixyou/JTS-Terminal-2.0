"""Public-source signing configuration is explicit, bounded and fail-closed."""
from pathlib import Path
import json
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import configure_signing as signing


class ConfigureSigningTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        for relative in signing.SIGNING_FILES:
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('anchor apple generic and identifier "fixed.identifier" and certificate leaf[subject.OU] = "YOURTEAMID"\n')

    def test_all_exact_pins_and_project_are_replaced_together(self):
        self.assertEqual(signing.configure(self.root, "ABC1234567"), len(signing.SIGNING_FILES))
        for relative in signing.SIGNING_FILES:
            content = (self.root / relative).read_text()
            self.assertNotIn(signing.PLACEHOLDER, content)
            self.assertIn('certificate leaf[subject.OU] = "ABC1234567"', content)
            self.assertIn('anchor apple generic and identifier "fixed.identifier"', content)
        self.assertEqual(json.loads((self.root / signing.STATE_FILE).read_text())["teamID"], "ABC1234567")

    def test_invalid_and_injected_values_do_not_change_files(self):
        initial = {relative: (self.root / relative).read_bytes() for relative in signing.SIGNING_FILES}
        for value in ("", "short", "abc1234567", "ABC12345678", "YOURTEAMID", 'ABC1234567" or true', "ABC123456\n"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                signing.configure(self.root, value)
        self.assertFalse((self.root / signing.STATE_FILE).exists())
        self.assertEqual(initial, {relative: (self.root / relative).read_bytes() for relative in signing.SIGNING_FILES})

    def test_missing_marker_fails_before_any_change(self):
        (self.root / signing.SIGNING_FILES[-1]).write_text("unexpected signing source")
        with self.assertRaisesRegex(ValueError, "no files changed"):
            signing.configure(self.root, "ABC1234567")
        self.assertIn(signing.PLACEHOLDER, (self.root / signing.SIGNING_FILES[0]).read_text())
        self.assertFalse((self.root / signing.STATE_FILE).exists())

    def test_idempotent_and_explicit_reconfiguration(self):
        signing.configure(self.root, "ABC1234567")
        signing.configure(self.root, "ABC1234567")
        signing.configure(self.root, "XYZ7654321")
        for relative in signing.SIGNING_FILES:
            self.assertIn("XYZ7654321", (self.root / relative).read_text())
            self.assertNotIn("ABC1234567", (self.root / relative).read_text())

    def test_source_symlink_rejected_before_any_change(self):
        path = self.root / signing.SIGNING_FILES[-1]
        path.unlink()
        destination = self.root / "outside-source"
        destination.write_text(signing.PLACEHOLDER)
        path.symlink_to(destination)
        with self.assertRaises(ValueError):
            signing.configure(self.root, "ABC1234567")
        self.assertEqual(destination.read_text(), signing.PLACEHOLDER)

    def test_actual_snapshot_contains_each_fixed_signing_marker(self):
        source_root = Path(__file__).resolve().parents[2]
        configured = source_root / signing.STATE_FILE
        expected = json.loads(configured.read_text())["teamID"] if configured.exists() else signing.PLACEHOLDER
        for relative in signing.SIGNING_FILES:
            self.assertIn(expected, (source_root / relative).read_text(), relative)


if __name__ == "__main__":
    unittest.main()
