from __future__ import annotations

import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "verify_freerdp_runtime_contract.py"
SPEC = importlib.util.spec_from_file_location("verify_freerdp_runtime_contract", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
CONTRACT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = CONTRACT
SPEC.loader.exec_module(CONTRACT)


VALID_ENGINE = r"""
static BOOL JTPreConnect(freerdp *instance)
{
    // freerdp_client_load_addins() in a comment must not count.
    NSString *diagnostic = @"freerdp_client_load_addins() in a string must not count";
    return TRUE;
}

static BOOL JTLoadChannels(freerdp *instance)
{
    return freerdp_client_load_addins(
        instance->context->channels,
        instance->context->settings);
}

static BOOL JTClientNew(freerdp *instance, rdpContext *context)
{
    instance->LoadChannels = JTLoadChannels;
    return TRUE;
}

- (BOOL)configureSettings:(rdpSettings *)settings
            configuration:(NSDictionary<NSString *, id> *)configuration
{
    BOOL clipboardEnabled = [configuration[@"clipboardEnabled"] boolValue];
    return freerdp_settings_set_bool(
               settings,
               FreeRDP_NetworkAutoDetect,
               FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportHeartbeatPdu, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportMultitransport, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, clipboardEnabled) &&
        freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectDrives, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectPrinters, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectSmartCards, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectSerialPorts, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectParallelPorts, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportSSHAgentChannel, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_UseMultimon, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SpanMonitors, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_ForceMultimon, FALSE);
}
"""

VALID_CLIPBOARD_BRIDGE = r"""
- (UINT)sendCapabilities:(CliprdrClientContext *)context
{
    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES |
        CB_STREAM_FILECLIP_ENABLED |
        CB_FILECLIP_NO_FILE_PATHS;
    return context->ClientCapabilities(context, NULL);
}
"""

VALID_EXPLICIT_EMPTY_PATCH = r"""
diff --git a/channels/cliprdr/client/cliprdr_main.c b/channels/cliprdr/client/cliprdr_main.c
--- a/channels/cliprdr/client/cliprdr_main.c
+++ b/channels/cliprdr/client/cliprdr_main.c
@@ -1,2 +1,4 @@
-old first line
-old second line
+const BOOL explicitEmptyList = formatList->numFormats == 0;
+if ((filterList.numFormats == 0) && cliprdr->initialFormatListSent &&
+    !explicitEmptyList)
+{
"""


class RuntimeContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        (self.root / "JTFreeRDPService").mkdir()
        (self.root / "scripts").mkdir()
        (self.root / "scripts" / "patches").mkdir()
        self.write_plist("Native RDP connects only to a saved Windows host.")
        self.write_build_recipe("OFF")
        self.write_explicit_empty_patch(VALID_EXPLICIT_EMPTY_PATCH)
        self.write_engine(VALID_ENGINE)
        self.write_clipboard_bridge(VALID_CLIPBOARD_BRIDGE)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def write_plist(self, purpose: str | None) -> None:
        payload = {"CFBundleIdentifier": "com.example.service"}
        if purpose is not None:
            payload["NSLocalNetworkUsageDescription"] = purpose
        with (self.root / "JTFreeRDPService" / "Info.plist").open("wb") as handle:
            plistlib.dump(payload, handle)

    def write_build_recipe(
        self,
        rdpdr: str,
        internal_md4: str = "ON",
        internal_rc4: str = "ON",
        disabled_overrides: dict[str, str] | None = None,
        apply_explicit_empty_patch: bool = True,
    ) -> None:
        disabled_definitions = {
            definition: "OFF"
            for definition in CONTRACT.SLIM_BUILD_DISABLED_DEFINITIONS
        }
        disabled_definitions["CHANNEL_RDPDR"] = rdpdr
        enabled_definitions = {
            definition: "ON"
            for definition in CONTRACT.SLIM_BUILD_ENABLED_DEFINITIONS
        }
        definitions = disabled_definitions | enabled_definitions
        definitions.update(disabled_overrides or {})
        disabled_arguments = " ".join(
            f"-D{definition}={value}"
            for definition, value in definitions.items()
        )
        patch_command = ""
        if apply_explicit_empty_patch:
            patch_command = (
                'patch -d "$source_dir" -p1 --forward --batch < '
                '"$PROJECT_DIR/scripts/patches/'
                'freerdp-explicit-empty-clipboard-list.patch"\n'
            )
        (self.root / "scripts" / "build_freerdp.sh").write_text(
            f"{patch_command}cmake -S source {disabled_arguments} "
            f"-DWITH_INTERNAL_MD4={internal_md4} "
            f"-DWITH_INTERNAL_RC4={internal_rc4}\n",
            encoding="utf-8",
        )

    def write_explicit_empty_patch(self, source: str) -> None:
        (
            self.root
            / CONTRACT.EXPLICIT_EMPTY_CLIPBOARD_PATCH
        ).write_text(source, encoding="utf-8")

    def write_engine(self, source: str) -> None:
        (self.root / "JTFreeRDPService" / "JTFreeRDPEngine.m").write_text(
            source,
            encoding="utf-8",
        )

    def write_clipboard_bridge(self, source: str) -> None:
        (
            self.root
            / "JTFreeRDPService"
            / "JTFreeRDPTextClipboardBridge.m"
        ).write_text(source, encoding="utf-8")

    def failures(self) -> list[str]:
        return [
            result.description
            for result in CONTRACT.audit_runtime_contract(self.root)
            if not result.passed
        ]

    def test_valid_contract_passes_and_ignores_comments_and_strings(self) -> None:
        self.assertEqual(self.failures(), [])

    def test_missing_local_network_purpose_fails(self) -> None:
        self.write_plist(None)
        self.assertIn(
            "JTFreeRDPService Info.plist has a non-empty NSLocalNetworkUsageDescription",
            self.failures(),
        )

    def test_rdpdr_must_remain_disabled_in_slim_recipe(self) -> None:
        self.write_build_recipe("ON")
        failures = self.failures()
        self.assertIn(
            "FreeRDP slim-build recipe sets CHANNEL_RDPDR exactly once to OFF",
            failures,
        )
        self.assertIn(
            "RDP engine explicitly disables FreeRDP_NetworkAutoDetect for the rdpdr-off build",
            failures,
        )

    def test_every_excluded_redirection_build_feature_must_remain_off(self) -> None:
        for definition in CONTRACT.SLIM_BUILD_DISABLED_DEFINITIONS:
            if definition == "CHANNEL_RDPDR":
                continue
            with self.subTest(definition=definition):
                self.write_build_recipe(
                    "OFF",
                    disabled_overrides={definition: "ON"},
                )
                self.assertIn(
                    f"FreeRDP slim-build recipe sets {definition} exactly once to OFF",
                    self.failures(),
                )

    def test_text_clipboard_channel_must_be_enabled_in_slim_recipe(self) -> None:
        self.write_build_recipe(
            "OFF",
            disabled_overrides={"CHANNEL_CLIPRDR": "OFF"},
        )
        self.assertIn(
            "FreeRDP slim-build recipe sets CHANNEL_CLIPRDR exactly once to ON",
            self.failures(),
        )

    def test_build_recipe_must_apply_explicit_empty_clipboard_patch(self) -> None:
        self.write_build_recipe(
            "OFF",
            apply_explicit_empty_patch=False,
        )
        self.assertIn(
            "FreeRDP build recipe applies the explicit-empty CLIPRDR patch",
            self.failures(),
        )

    def test_explicit_empty_patch_must_exempt_caller_empty_lists(self) -> None:
        self.write_explicit_empty_patch(
            VALID_EXPLICIT_EMPTY_PATCH.replace(
                "    !explicitEmptyList)",
                "    explicitEmptyList) // !explicitEmptyList",
            )
        )
        self.assertIn(
            "Explicit-empty CLIPRDR patch preserves caller-supplied empty format lists",
            self.failures(),
        )

    def test_explicit_empty_patch_hunk_counts_must_be_applyable(self) -> None:
        self.write_explicit_empty_patch(
            VALID_EXPLICIT_EMPTY_PATCH.replace(
                "@@ -1,2 +1,4 @@",
                "@@ -1,2 +1,3 @@",
            )
        )
        self.assertIn(
            "Explicit-empty CLIPRDR patch has well-formed unified-diff hunks",
            self.failures(),
        )

    def test_path_free_file_clipboard_capabilities_are_required(self) -> None:
        for capability in (
            "CB_STREAM_FILECLIP_ENABLED",
            "CB_FILECLIP_NO_FILE_PATHS",
        ):
            with self.subTest(capability=capability):
                self.write_clipboard_bridge(
                    VALID_CLIPBOARD_BRIDGE.replace(
                        f"        {capability} |\n",
                        "",
                    ).replace(
                        f"        {capability};",
                        "        CB_USE_LONG_FORMAT_NAMES;",
                    )
                )
                self.assertIn(
                    "CLIPRDR negotiates one path-free streamed file offer for Companion bootstrap",
                    self.failures(),
                )

    def test_locking_and_huge_file_capabilities_remain_excluded(self) -> None:
        for capability in (
            "CB_CAN_LOCK_CLIPDATA",
            "CB_HUGE_FILE_SUPPORT_ENABLED",
        ):
            with self.subTest(capability=capability):
                self.write_clipboard_bridge(
                    VALID_CLIPBOARD_BRIDGE.replace(
                        "        CB_STREAM_FILECLIP_ENABLED |",
                        f"        CB_STREAM_FILECLIP_ENABLED |\n"
                        f"        {capability} |",
                    )
                )
                self.assertIn(
                    "CLIPRDR keeps clipboard locking and huge-file transfer disabled",
                    self.failures(),
                )

    def test_internal_md4_must_be_enabled_for_ntlm_credssp(self) -> None:
        self.write_build_recipe("OFF", internal_md4="OFF")
        self.assertIn(
            "FreeRDP slim-build recipe sets WITH_INTERNAL_MD4 exactly once to ON",
            self.failures(),
        )

    def test_internal_rc4_must_be_enabled_for_ntlm_credssp(self) -> None:
        self.write_build_recipe("OFF", internal_rc4="OFF")
        self.assertIn(
            "FreeRDP slim-build recipe sets WITH_INTERNAL_RC4 exactly once to ON",
            self.failures(),
        )

    def test_required_setting_must_be_explicitly_false(self) -> None:
        self.write_engine(
            VALID_ENGINE.replace(
                "FreeRDP_SupportHeartbeatPdu, FALSE",
                "FreeRDP_SupportHeartbeatPdu, TRUE",
            )
        )
        self.assertIn(
            "RDP engine explicitly disables FreeRDP_SupportHeartbeatPdu for the rdpdr-off build",
            self.failures(),
        )

    def test_every_release_disabled_runtime_setting_must_be_explicitly_false(self) -> None:
        for setting in CONTRACT.RELEASE_RUNTIME_DISABLED_SETTINGS:
            with self.subTest(setting=setting):
                false_setting = f"{setting}, FALSE"
                self.assertIn(false_setting, VALID_ENGINE)
                self.write_engine(
                    VALID_ENGINE.replace(false_setting, f"{setting}, TRUE")
                )
                self.assertIn(
                    f"RDP engine explicitly disables {setting} for the 2.0 release",
                    self.failures(),
                )

    def test_clipboard_runtime_setting_must_follow_profile_preference(self) -> None:
        self.write_engine(
            VALID_ENGINE.replace(
                "FreeRDP_RedirectClipboard, clipboardEnabled",
                "FreeRDP_RedirectClipboard, TRUE",
            )
        )
        self.assertIn(
            "RDP engine binds FreeRDP_RedirectClipboard to the per-profile text clipboard preference",
            self.failures(),
        )

    def test_preconnect_cannot_duplicate_channel_loading(self) -> None:
        self.write_engine(
            VALID_ENGINE.replace(
                "return TRUE;\n}",
                "return freerdp_client_load_addins(instance->context->channels, "
                "instance->context->settings);\n}",
                1,
            )
        )
        failures = self.failures()
        self.assertIn(
            "JTPreConnect does not directly load FreeRDP channel add-ins",
            failures,
        )
        self.assertIn(
            "JTLoadChannels contains the engine's only freerdp_client_load_addins call",
            failures,
        )

    def test_loadchannels_callback_must_be_wired(self) -> None:
        self.write_engine(
            VALID_ENGINE.replace(
                "instance->LoadChannels = JTLoadChannels;",
                "instance->LoadChannels = NULL;",
            )
        )
        self.assertIn(
            "JTClientNew wires FreeRDP LoadChannels to JTLoadChannels",
            self.failures(),
        )


if __name__ == "__main__":
    unittest.main()
