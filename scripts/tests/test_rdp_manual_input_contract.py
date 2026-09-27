from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source_region(source: str, start: str, end: str) -> str:
    start_index = source.index(start)
    end_index = source.index(end, start_index + len(start))
    return source[start_index:end_index]


class RDPManualInputContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.runtime = (ROOT / "JTSTerminal" / "RemoteDesktop" / "RDPDesktopRuntimeStore.swift").read_text(
            encoding="utf-8"
        )
        cls.engine = (ROOT / "JTFreeRDPService" / "JTFreeRDPEngine.m").read_text(
            encoding="utf-8"
        )
        cls.service = (ROOT / "JTFreeRDPService" / "JTFreeRDPService.m").read_text(
            encoding="utf-8"
        )
        cls.validation = (
            ROOT / "JTFreeRDPService" / "JTFreeRDPXPCValidation.m"
        ).read_text(encoding="utf-8")
        cls.bootstrap = (
            ROOT
            / "JTSTerminal"
            / "WindowsCompanion"
            / "RDPCompanionBootstrapInstaller.swift"
        ).read_text(encoding="utf-8")
        cls.installation_view = (
            ROOT
            / "JTSTerminal"
            / "WindowsCompanion"
            / "WindowsCompanionInstallationProgressView.swift"
        ).read_text(encoding="utf-8")

    def test_only_the_internal_manual_path_marks_pointer_input(self) -> None:
        self.assertEqual(self.runtime.count('input["inputOrigin"] = "localManual"'), 5)
        action_dispatch = source_region(
            self.runtime,
            "private func performDesktopAction(",
            "func closeDesktop(",
        )
        self.assertIn(
            "localManualFrame: isManualInput ? frame.metadata : nil",
            action_dispatch,
        )
        send_mouse = source_region(
            self.runtime,
            "private func sendMouse(",
            "func companionRequest(",
        )
        manual_branch = source_region(
            send_mouse,
            "if let localManualFrame {",
            "try await sendDesktopInput(",
        )
        self.assertIn('input["inputOrigin"] = "localManual"', manual_branch)
        self.assertIn('input["coordinateSpaceWidth"] = localManualFrame.pixelWidth', manual_branch)
        self.assertIn('input["coordinateSpaceHeight"] = localManualFrame.pixelHeight', manual_branch)
        raw_actions = source_region(
            self.runtime,
            "private func performRawAction(",
            "private func sendMouse(",
        )
        self.assertEqual(raw_actions.count('input["inputOrigin"] = "localManual"'), 3)
        self.assertEqual(raw_actions.count('"expectedStateRevision": request.expectedStateRevision'), 3)

    def test_companion_bootstrap_uses_language_independent_bounded_rdp_input(self) -> None:
        installation = source_region(
            self.runtime,
            "private func runCompanionInstallation(",
            "private func reserveClipboardForCompanionInstallation(",
        )
        self.assertNotIn("command: plan.cleanupCommand", installation)
        self.assertIn("temporaryFolderAddress: plan.temporaryFolderAddress", installation)
        self.assertIn("command: plan.powerShellLaunchCommand", installation)
        self.assertIn("script: plan.powerShellScript", installation)
        self.assertIn("powerShellLaunchFrameID", installation)
        self.assertIn("waitForCompanionInstallationDesktopTransition(", installation)
        paste = source_region(
            self.runtime,
            "private func pasteCompanionInstallerIntoTemporaryFolder(",
            "private func waitForCompanionInstallationDesktopTransition(",
        )
        self.assertIn("sendCompanionInstallationRunCommand(", paste)
        self.assertIn("command: temporaryFolderAddress", paste)
        self.assertIn("waitForCompanionInstallationDesktopTransition(", paste)
        self.assertIn('["control", "v"].map(Self.scanCode(for:))', paste)
        self.assertNotIn('["meta", "e"]', paste)
        self.assertNotIn('["control", "l"]', paste)
        readiness = source_region(
            self.runtime,
            "private func waitForCompanionInstallationDesktopTransition(",
            "private func sendCompanionInstallationPowerShellScript(",
        )
        self.assertIn("desktopLaunchMinimumReadinessDelay", readiness)
        self.assertIn("desktopLaunchTransitionTimeout", readiness)
        self.assertIn("var observedTransition = false", readiness)
        self.assertIn("if observedTransition, ContinuousClock.now >= earliestReady", readiness)
        self.assertGreaterEqual(
            installation.count("try requireCompanionStillMissing(active)"),
            3,
        )
        self.assertNotIn("InvokeVerb", self.bootstrap)
        self.assertNotIn("Start-Process explorer.exe", self.bootstrap)
        self.assertIn("maximumRunCommandBytes = 259", self.bootstrap)
        self.assertIn("desktopLaunchTransitionTimeout: Duration = .seconds(20)", self.bootstrap)
        self.assertIn("desktopLaunchMinimumReadinessDelay: Duration = .seconds(8)", self.bootstrap)
        self.assertIn('static let temporaryFolderAddress = "%TEMP%"', self.bootstrap)
        self.assertIn('static let powerShellLaunchCommand = "powershell.exe -NoLogo -NoProfile"', self.bootstrap)
        self.assertNotIn("Get-AuthenticodeSignature", self.bootstrap)
        self.assertNotIn("SignerCertificate", self.bootstrap)
        self.assertIn("Get-FileHash -Algorithm SHA256 -LiteralPath $p", self.bootstrap)
        self.assertIn("throw 'hash mismatch'", self.bootstrap)
        self.assertIn("[IO.FileShare]::None", self.bootstrap)
        self.assertIn("$i.Length -eq", self.bootstrap)
        self.assertIn("remoteTransferTimeoutSeconds = 150", self.bootstrap)
        self.assertIn("remoteSetupTimeoutMilliseconds = 120_000", self.bootstrap)
        self.assertIn("Remove-Item -LiteralPath $p -Force", self.bootstrap)
        self.assertLess(
            self.bootstrap.index("Get-FileHash -Algorithm SHA256"),
            self.bootstrap.index("Start-Process -FilePath $p"),
        )
        self.assertIn("WaitForExit(10000)", self.bootstrap)

    def test_companion_installation_copy_uses_bundled_provenance_and_keeps_uac(self) -> None:
        for name in ("WindowsCompanionInstallation.swift", "WindowsCompanionSetupView.swift"):
            source = (ROOT / "JTSTerminal" / "WindowsCompanion" / name).read_text(
                encoding="utf-8"
            )
            with self.subTest(source=name):
                self.assertIn("bundled", source)
                self.assertIn("SHA-256", source)
                self.assertIn("UAC", source)
                self.assertNotIn("Authenticode", source)
                self.assertNotIn("signed installer", source)
                self.assertNotIn("signed Companion", source)
                self.assertNotIn("已签名", source)

    def test_companion_remote_name_is_unique_and_revalidated_at_execution(self) -> None:
        name_factory = source_region(
            self.service,
            "static NSString *JTCompanionInstallerRemoteFileName(void)",
            "@interface JTCompanionInstallerArtifact",
        )
        self.assertIn("[NSUUID UUID].UUIDString", name_factory)
        self.assertIn('stringByReplacingOccurrencesOfString:@"-"', name_factory)
        self.assertIn('lowercaseString', name_factory)
        self.assertIn('@"JTS-Companion-%@.exe"', name_factory)

        service_offer = source_region(
            self.service,
            "- (void)offerCompanionInstallerWithRequest:",
            "- (void)clearCompanionInstallerWithRequest:",
        )
        self.assertIn("JTCompanionInstallerRemoteFileName()", service_offer)
        self.assertIn("remoteFileName:remoteFileName", service_offer)
        self.assertIn('@"fileName": remoteFileName', service_offer)

        enqueue = source_region(
            self.engine,
            "- (BOOL)enqueueCompanionInstallerOfferAtURL:",
            "- (BOOL)enqueueCompanionInstallerClearWithRequest:",
        )
        execution = source_region(
            self.engine,
            "- (NSError * _Nullable)sendClipboardCommand:",
            "- (NSError * _Nullable)sendInputCommand:",
        )
        validator_call = "JTFreeRDPIsValidCompanionInstallerRemoteFileName(remoteFileName)"
        self.assertIn(validator_call, enqueue)
        self.assertIn(validator_call, execution)
        self.assertIn('prefix = @"JTS-Companion-"', self.validation)
        self.assertIn('suffix = @".exe"', self.validation)
        self.assertIn("prefix.length + 32 + suffix.length", self.validation)
        self.assertIn('characterSetWithCharactersInString:@"0123456789abcdef"', self.validation)

    def test_companion_cleanup_owns_the_captured_attempt_not_the_mutable_profile(self) -> None:
        cleanup = source_region(
            self.runtime,
            "private func finishCompanionInstallationClipboard(",
            "private func scheduleCompanionInstallationSessionRetirement(",
        )
        ownership = source_region(
            cleanup,
            "let attemptIsOwned =",
            "let targetBindingChanged =",
        )
        self.assertIn("self.isCurrent(active)", ownership)
        self.assertIn("active.connectionAttemptID == expectedConnectionAttemptID", ownership)
        self.assertNotIn("targetBindingIsCurrent", ownership)
        self.assertIn("let targetBindingChanged = {", cleanup)
        self.assertIn("!self.targetBindingIsCurrent(active)", cleanup)
        self.assertGreaterEqual(
            cleanup.count("guard attemptIsOwned() else { return true }"),
            8,
        )
        self.assertGreaterEqual(cleanup.count("targetBindingChanged()"), 3)
        self.assertIn("clearCompanionInstallerOffer(", cleanup)
        self.assertGreaterEqual(cleanup.count("active.xpc.invalidateImmediately()"), 3)
        self.assertGreaterEqual(
            cleanup.count("scheduleCompanionInstallationSessionRetirement("),
            3,
        )

        retirement = source_region(
            self.runtime,
            "private func scheduleCompanionInstallationSessionRetirement(",
            "private func isTransientCompanionInstallationInputFailure(",
        )
        self.assertIn("self.isCurrent(active)", retirement)
        self.assertIn("active.connectionAttemptID == expectedConnectionAttemptID", retirement)
        self.assertIn("await self.close(active: active)", retirement)

    def test_companion_missing_is_debounced_and_active_install_has_no_fake_cancel(self) -> None:
        state_handler = source_region(
            self.runtime,
            "private func handleState(",
            "func isCurrent(",
        )
        self.assertIn("markCompanionDVCUnavailable(", state_handler)
        self.assertNotIn(
            "resetCompanionForDVCTransition(active, availability: .missing)",
            state_handler,
        )
        self.assertIn(
            "private static let defaultCompanionMissingGracePeriod: Duration = .seconds(2)",
            self.runtime,
        )
        self.assertIn("scheduleCompanionMissing(active)", self.runtime)
        self.assertNotIn("let cancel: (() -> Void)?", self.installation_view)
        self.assertNotIn("rdp-companion-install-cancel-button", self.installation_view)
        self.assertIn("rdp-companion-install-close-button", self.installation_view)

    def test_helper_rebinds_only_manual_input_and_keeps_exact_stale_checks(self) -> None:
        enqueue = source_region(
            self.engine,
            "- (BOOL)enqueueInput:",
            "- (BOOL)enqueueDVCMessage:",
        )
        self.assertIn(
            "JTFreeRDPInputCommandForExecution(",
            enqueue,
        )
        self.assertIn("self.connectionAttemptIdentifier", enqueue)
        self.assertNotIn('[command removeObjectForKey:@"inputOrigin"]', enqueue)
        validator = source_region(
            self.validation,
            "NSDictionary<NSString *, id> * _Nullable JTFreeRDPInputCommandForExecution(",
            "NSDictionary<NSString *, id> *JTFreeRDPSanitizedCancellation(",
        )
        manual_branch = source_region(
            validator,
            "if (isLocalManualInput) {",
            "NSError *validationError",
        )
        self.assertIn("coordinateSpaceMatches", manual_branch)
        self.assertIn('command[@"expectedFrameId"] = frameID', manual_branch)
        self.assertIn('command[@"expectedStateRevision"] = stateRevision', manual_branch)
        self.assertIn(
            'command[@"expectedStateRevision"] = currentRevision',
            validator,
        )

        # AI/MCP input keeps exact frame and state binding at queue drain.
        mouse_validator = source_region(
            self.validation,
            "NSError * _Nullable JTFreeRDPMouseInputValidationError(",
            "NSDictionary<NSString *, id> * _Nullable JTFreeRDPInputCommandForExecution(",
        )
        self.assertIn(
            "[expectedFrameID isEqualToString:currentFrameID",
            mouse_validator,
        )
        self.assertIn(
            "[expectedRevision isEqualToNumber:currentRevision]",
            mouse_validator,
        )
        self.assertIn('@"The referenced desktop frame is stale.', mouse_validator)
        self.assertIn(
            "![expectedRevision isEqualToNumber:currentRevision]",
            validator,
        )

    def test_compound_actions_cross_xpc_once_and_release_inside_the_engine(self) -> None:
        raw_actions = source_region(
            self.runtime,
            "private func performRawAction(",
            "private func sendMouse(",
        )
        click = source_region(raw_actions, "case .click:", "case .doubleClick:")
        self.assertEqual(click.count("sendMouse("), 1)
        self.assertIn('action: "click"', click)

        double_click = source_region(
            raw_actions,
            "case .doubleClick:",
            "case .mouseDown:",
        )
        self.assertEqual(double_click.count("sendMouse("), 1)
        self.assertIn('action: "doubleClick"', double_click)

        key_chord = source_region(raw_actions, "case .keyChord:", "case .semanticInvoke")
        self.assertEqual(key_chord.count("sendDesktopInput("), 1)
        self.assertIn('"type": "keyChord"', key_chord)
        self.assertIn('"scancodes": codes', key_chord)

        input_bridge = source_region(
            self.runtime,
            "func sendDesktopInput(",
            "func companionRequest(",
        )
        self.assertEqual(input_bridge.count("active.xpc.sendInput("), 1)
        self.assertIn("if let inputExecutor", input_bridge)

        engine_dispatch = source_region(
            self.engine,
            "- (NSError * _Nullable)sendInputCommand:",
            "- (NSError * _Nullable)sendResizeCommand:",
        )
        self.assertIn('[action isEqualToString:@"click"]', engine_dispatch)
        self.assertIn('[action isEqualToString:@"doubleClick"]', engine_dispatch)
        self.assertIn("buttonFlags | PTR_FLAGS_DOWN", engine_dispatch)
        self.assertIn("for (NSUInteger index = attemptedCount; index > 0; index--)", engine_dispatch)

    def test_final_queue_execution_revalidates_the_frame(self) -> None:
        drain = source_region(
            self.engine,
            "- (void)drainCommands:",
            "- (NSError * _Nullable)sendInputCommand:",
        )
        self.assertIn("return [self sendInputCommand:command context:context]", drain)
        execution = source_region(
            self.engine,
            "- (NSError * _Nullable)sendInputCommand:",
            "- (NSError * _Nullable)sendResizeCommand:",
        )
        self.assertIn(
            "JTFreeRDPInputCommandForExecution(",
            execution,
        )
        self.assertIn("self.connectionAttemptIdentifier", execution)

    def test_resize_failures_propagate_through_the_engine_and_xpc_reply(self) -> None:
        execution = source_region(
            self.engine,
            "- (NSError * _Nullable)sendInputCommand:",
            "- (NSError * _Nullable)sendResizeCommand:",
        )
        self.assertIn("return [self sendResizeCommand:command]", execution)

        resize = source_region(
            self.engine,
            "- (NSError * _Nullable)sendResizeCommand:",
            "- (BOOL)createSurfaceForContext:",
        )
        self.assertIn("!displayControl->SendMonitorLayout", resize)
        self.assertIn('@"DISPLAY_CONTROL_UNAVAILABLE"', resize)
        self.assertIn(
            "UINT result = displayControl->SendMonitorLayout(displayControl, 1, &monitor)",
            resize,
        )
        self.assertIn("result == CHANNEL_RC_OK ? nil : JTFreeRDPError", resize)
        self.assertIn('@"DISPLAY_RESIZE_FAILED"', resize)

        send_input = source_region(
            self.service,
            "- (void)sendInput:",
            "- (void)sendDVCMessage:",
        )
        self.assertIn("completion:^(NSError *executionError)", send_input)
        self.assertIn("JTFreeRDPFailureResult(executionError", send_input)

    def test_normal_disconnect_clears_transient_input_error_state(self) -> None:
        close = source_region(
            self.runtime,
            "private func close(",
            "func publish(_ active:",
        )
        self.assertIn("state.latestFrameID = nil", close)
        self.assertIn("state.lastErrorCode = nil", close)
        self.assertIn("state.lastErrorMessage = nil", close)


if __name__ == "__main__":
    unittest.main()
