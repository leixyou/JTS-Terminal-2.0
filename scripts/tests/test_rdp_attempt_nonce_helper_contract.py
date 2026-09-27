from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def source_region(source: str, start: str, end: str) -> str:
    start_index = source.index(start)
    end_index = source.index(end, start_index + len(start))
    return source[start_index:end_index]


class RDPAttemptNonceHelperContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.engine = (ROOT / "JTFreeRDPService" / "JTFreeRDPEngine.m").read_text(
            encoding="utf-8"
        )
        cls.engine_impl = cls.engine[cls.engine.index("@implementation JTFreeRDPEngine") :]
        cls.service = (ROOT / "JTFreeRDPService" / "JTFreeRDPService.m").read_text(
            encoding="utf-8"
        )
        cls.validation = (
            ROOT / "JTFreeRDPService" / "JTFreeRDPXPCValidation.m"
        ).read_text(encoding="utf-8")
        cls.client = (
            ROOT / "JTSTerminal" / "RemoteDesktop" / "FreeRDPXPCClient.swift"
        ).read_text(encoding="utf-8")
        cls.runtime = (
            ROOT / "JTSTerminal" / "RemoteDesktop" / "RDPDesktopRuntimeStore.swift"
        ).read_text(encoding="utf-8")
        cls.helper_main = (
            ROOT / "JTFreeRDPService" / "main.m"
        ).read_text(encoding="utf-8")

    def test_configuration_reply_and_request_envelopes_bind_the_attempt(self) -> None:
        configuration = source_region(
            self.validation,
            "JTFreeRDPSanitizedConfiguration(",
            "JTFreeRDPSanitizedInput(",
        )
        self.assertIn('@"connectionAttemptId"', configuration)
        self.assertIn("JTCanonicalUUIDString", configuration)

        connect = source_region(
            self.service,
            "- (void)connectWithConfiguration:",
            "- (void)disconnectWithReply:",
        )
        self.assertIn('@"connectionAttemptId": attemptIdentifier', connect)

        self.assertEqual(
            self.service.count(
                "expectedAttemptIdentifier:self.connectionAttemptIdentifier"
            ),
            6,
        )
        cancellation = source_region(
            self.service,
            "- (void)cancelRequest:",
            "- (void)copyFrameWithReply:",
        )
        self.assertIn("self.connectionAttemptIdentifier", cancellation)

    def test_every_attempt_bound_helper_output_carries_the_nonce(self) -> None:
        surface = source_region(
            self.engine_impl,
            "- (BOOL)handleEndPaint:",
            "- (BOOL)handleDesktopResize:",
        )
        self.assertIn('@"connectionAttemptId": self.connectionAttemptIdentifier', surface)

        certificate_pem = source_region(
            self.engine_impl,
            "- (int)verifyPinnedCertificatePEM:",
            "- (DWORD)verifyCertificateForHost:",
        )
        certificate_host = source_region(
            self.engine_impl,
            "- (DWORD)verifyCertificateForHost:",
            "- (nullable NSString *)certificateFingerprintFromCString:",
        )
        self.assertIn('@"connectionAttemptId": self.connectionAttemptIdentifier', certificate_pem)
        self.assertIn('@"connectionAttemptId": self.connectionAttemptIdentifier', certificate_host)

        state = source_region(
            self.engine_impl,
            "- (void)notifyState:(NSString *)phase\n               code:(nullable NSString *)code\n            message:(nullable NSString *)message\n        certificate:",
            "- (uint64_t)nextStateRevision",
        )
        self.assertIn('@"connectionAttemptId": self.connectionAttemptIdentifier', state)

    def test_input_resize_dvc_and_clipboard_revalidate_at_execution(self) -> None:
        enqueue_input = source_region(
            self.engine_impl,
            "- (BOOL)enqueueInput:",
            "- (BOOL)enqueueDVCMessage:",
        )
        self.assertIn(
            'command[@"expectedConnectionAttemptId"] = request.connectionAttemptIdentifier',
            enqueue_input,
        )
        self.assertIn("JTFreeRDPInputCommandForExecution(", enqueue_input)

        enqueue_dvc = source_region(
            self.engine_impl,
            "- (BOOL)enqueueDVCMessage:",
            "- (BOOL)cancelRequestIdentifier:",
        )
        self.assertIn('@"expectedConnectionAttemptId": request.connectionAttemptIdentifier', enqueue_dvc)
        self.assertIn('@"expectedDVCGeneration": @(expectedChannelGeneration)', enqueue_dvc)
        self.assertIn("JTFreeRDPConnectionAttemptValidationError(", enqueue_dvc)
        self.assertIn("JTFreeRDPDVCGenerationValidationError(", enqueue_dvc)
        enqueue_clipboard = source_region(
            self.engine_impl,
            "- (BOOL)enqueueClipboardText:",
            "- (BOOL)cancelRequestIdentifier:",
        )
        self.assertIn(
            '@"expectedConnectionAttemptId": request.connectionAttemptIdentifier',
            enqueue_clipboard,
        )
        self.assertIn(
            "JTFreeRDPConnectionAttemptValidationError(",
            enqueue_clipboard,
        )
        self.assertIn("- (BOOL)enqueueClipboardIsolation:", enqueue_clipboard)
        self.assertIn('@"expectedConnectionAttemptId": request.connectionAttemptIdentifier', enqueue_clipboard)

        drain = source_region(
            self.engine_impl,
            "- (void)drainCommands:",
            "- (NSError * _Nullable)sendInputCommand:",
        )
        self.assertIn("JTFreeRDPConnectionAttemptValidationError(", drain)
        self.assertIn("JTFreeRDPDVCGenerationValidationError(", drain)
        self.assertIn("expectedGeneration:", drain)

        execution = source_region(
            self.engine_impl,
            "- (NSError * _Nullable)sendInputCommand:",
            "- (NSError * _Nullable)sendResizeCommand:",
        )
        validator_index = execution.index("JTFreeRDPInputCommandForExecution(")
        resize_index = execution.index('[type isEqualToString:@"resize"]')
        self.assertLess(validator_index, resize_index)
        self.assertIn("self.connectionAttemptIdentifier", execution)

    def test_stale_attempt_has_one_stable_machine_code(self) -> None:
        self.assertIn('@"RDP_XPC_STALE_ATTEMPT"', self.validation)
        self.assertNotIn('@"RDP_STALE_ATTEMPT"', self.validation)

    def test_client_async_teardown_is_bound_to_the_exact_connection_epoch(self) -> None:
        self.assertIn("private struct ConnectionBinding", self.client)
        current_binding = source_region(
            self.client,
            "private func isCurrent(_ binding: ConnectionBinding)",
            "@discardableResult\n    private func invalidateConnection(",
        )
        self.assertIn("connection === binding.connection", current_binding)
        self.assertIn("activeConnectionGeneration == binding.generation", current_binding)
        self.assertIn("activeConnectionAttemptID == binding.attemptID", current_binding)

        connect = source_region(self.client, "func connect(", "func disconnect()")
        self.assertIn("invalidateConnection(binding, failingPendingWith: teardownFailure)", connect)
        disconnect = source_region(self.client, "func disconnect()", "func invalidateImmediately()")
        self.assertIn("guard let binding = currentConnectionBinding()", disconnect)
        self.assertIn("invalidateConnection(binding, failingPendingWith:", disconnect)

        frame = source_region(self.client, "func copyFrame()", "func ping()")
        self.assertIn("binding: binding", frame)
        self.assertIn("handleProtocolViolation(failure.message, binding: binding)", frame)
        ordinary = source_region(
            self.client,
            "private func performOrdinaryRequest<Value>(",
            "private func currentConnectionBinding()",
        )
        self.assertIn("binding: ConnectionBinding", ordinary)
        self.assertIn("if invalidateConnection(binding, failingPendingWith: failure)", ordinary)

    def test_clipboard_xpc_payloads_have_explicit_class_allowlists(self) -> None:
        self.assertGreaterEqual(
            self.helper_main.count(
                "@selector(updateClipboardText:request:reply:)"
            ),
            3,
        )
        self.assertGreaterEqual(
            self.helper_main.count(
                "@selector(setClipboardIsolation:text:request:reply:)"
            ),
            3,
        )
        self.assertGreaterEqual(
            self.helper_main.count(
                "@selector(desktopDidReceiveClipboardText:metadata:)"
            ),
            2,
        )
        self.assertIn(
            "NSSet<Class> *data = JTFreeRDPDataClasses();",
            self.helper_main,
        )

    def test_reconnect_worker_is_bound_to_one_attempt_and_task(self) -> None:
        schedule = source_region(
            self.runtime,
            "private func scheduleReconnect(",
            "private func prepareForReconnect(",
        )
        self.assertIn("let expectedConnectionAttemptID = active.connectionAttemptID", schedule)
        self.assertIn("active.reconnectTaskID == reconnectTaskID", schedule)
        self.assertIn(
            "expectedConnectionAttemptID: expectedConnectionAttemptID",
            schedule,
        )

        reconnect = source_region(
            self.runtime,
            "private func performReconnect(",
            "private func connectionPassword(",
        )
        self.assertGreaterEqual(
            reconnect.count("active.connectionAttemptID == expectedConnectionAttemptID"),
            4,
        )
        self.assertGreaterEqual(reconnect.count("!Task.isCancelled"), 4)

    def test_dvc_lifecycle_generation_crosses_xpc_in_both_directions(self) -> None:
        self.assertIn("JTCompanionDVCChannelCallback", self.engine)
        self.assertIn("sizeof(JTCompanionDVCChannelCallback)", self.engine)
        dvc_runtime = source_region(
            self.engine_impl,
            "- (BOOL)isDVCChannelConnected",
            "- (void)handleChannelConnected:",
        )
        self.assertIn("callback->generation = generation", dvc_runtime)
        self.assertIn("self.engineState->dvcGeneration == callbackGeneration", dvc_runtime)
        self.assertIn("self.engineState->dvcGeneration == generation", dvc_runtime)
        self.assertIn("rdpEngineDidReceiveDVCMessage:message metadata:metadata", dvc_runtime)

        notify = source_region(
            self.engine_impl,
            "- (void)notifyState:(NSString *)phase",
            "- (uint64_t)nextStateRevision",
        )
        self.assertIn('@"companionDVCGeneration": @(companionGeneration)', notify)

        self.assertIn(
            "expectedChannelGeneration: expectedChannelGeneration",
            self.client,
        )
        self.assertIn("message.channelGeneration", self.client)
        self.assertIn(
            "active.companionDVCGeneration == channelGeneration",
            self.runtime,
        )

    def test_dvc_diagnostics_are_debug_only_numeric_metadata(self) -> None:
        diagnostics = source_region(
            self.engine,
            "#if DEBUG\nstatic os_log_t JTCompanionDVCLog(void)",
            "static void JTEnableScopedFreeRDPDiagnostics(void)",
        )
        self.assertEqual(diagnostics.count("os_log_debug("), 2)
        for forbidden in ("%{public}@", "%{public}s", "%{public}p", "NSData", "NSString", "const BYTE", "requestId", "sessionID"):
            self.assertNotIn(forbidden, diagnostics)

        callback = source_region(
            self.engine,
            "static UINT JTCompanionDVCOnData(",
            "static UINT JTCompanionDVCOnOpen(",
        )
        self.assertIn(
            "#if DEBUG\n    JTLogCompanionDVCStream(Stream_Length(stream), Stream_GetPosition(stream), length);\n#endif",
            callback,
        )
        self.assertLess(callback.index("JTLogCompanionDVCStream("), callback.index("if (length >"))
        # Diagnostics must observe the supplied cursor without changing it or
        # substituting the full stream length for the unread payload length.
        self.assertIn("size_t length = Stream_GetRemainingLength(stream)", callback)
        self.assertIn("handleDVCData:Stream_ConstPointer(stream)", callback)
        self.assertNotIn("Stream_SetPosition", callback)

        dispatch = source_region(
            self.engine_impl,
            "- (void)handleDVCData:",
            "- (void)textClipboardBridge:",
        )
        self.assertIn("#if DEBUG\n    JTLogCompanionDVCDispatch(", dispatch)
        diagnostic_start = dispatch.index("JTLogCompanionDVCDispatch(")
        diagnostic_end = dispatch.index("#endif", diagnostic_start)
        self.assertNotIn("bytes,", dispatch[diagnostic_start:diagnostic_end])
        self.assertLess(dispatch.index("[self.dvcChannelLock lock]"), diagnostic_start)
        self.assertLess(diagnostic_end, dispatch.index("[self.dvcChannelLock unlock]"))


if __name__ == "__main__":
    unittest.main()
