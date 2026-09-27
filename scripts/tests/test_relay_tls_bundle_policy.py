"""Bundle policy permits the dedicated relay delegates to apply user trust policy."""
from pathlib import Path
import plistlib
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RelayTLSBundlePolicyTests(unittest.TestCase):
    def test_app_and_helper_can_handle_user_supplied_relay_certificates(self):
        for name in ("JTSTerminal/Info.plist", "JTCompanionTransportService/Info.plist"):
            with self.subTest(bundle=name):
                with (ROOT / name).open("rb") as stream:
                    info = plistlib.load(stream)
                self.assertEqual(info["NSAppTransportSecurity"], {"NSAllowsArbitraryLoads": True})


if __name__ == "__main__":
    unittest.main()
