#if ENABLE_RDP_2
@preconcurrency import Foundation
import IOSurface

@objc(JTFreeRDPClientProtocol)
private protocol JTFreeRDPClientXPCProtocol: NSObjectProtocol {
    @objc(desktopDidChangeState:)
    func desktopDidChangeState(_ state: NSDictionary)

    @objc(desktopDidUpdateSurface:metadata:)
    func desktopDidUpdateSurface(_ surface: IOSurface, metadata: NSDictionary)

    @objc(desktopDidReceiveDVCMessage:metadata:)
    func desktopDidReceiveDVCMessage(_ message: NSData, metadata: NSDictionary)

    @objc(desktopDidReceiveClipboardText:metadata:)
    func desktopDidReceiveClipboardText(_ text: NSData, metadata: NSDictionary)

    @objc(desktopDidRequireCertificateDecision:)
    func desktopDidRequireCertificateDecision(_ certificate: NSDictionary)
}

@objc(JTFreeRDPServiceProtocol)
private protocol JTFreeRDPServiceXPCProtocol: NSObjectProtocol {
    @objc(connectWithConfiguration:reply:)
    func connect(
        withConfiguration configuration: NSDictionary,
        reply: @escaping (NSDictionary) -> Void
    )

    @objc(connectWithConfiguration:relaySocket:reply:)
    func connect(withConfiguration configuration: NSDictionary,
                 relaySocket: FileHandle, reply: @escaping (NSDictionary) -> Void)

    @objc(disconnectWithReply:)
    func disconnect(reply: @escaping () -> Void)

    @objc(sendInput:request:reply:)
    func sendInput(
        _ input: NSDictionary,
        request: NSDictionary,
        reply: @escaping (NSDictionary) -> Void
    )

    @objc(sendDVCMessage:request:expectedChannelGeneration:reply:)
    func sendDVCMessage(
        _ message: NSData,
        request: NSDictionary,
        expectedChannelGeneration: UInt64,
        reply: @escaping (NSDictionary) -> Void
    )

    @objc(updateClipboardText:request:reply:)
    func updateClipboardText(
        _ text: NSData?,
        request: NSDictionary,
        reply: @escaping (NSDictionary) -> Void
    )

    @objc(setClipboardIsolation:text:request:reply:)
    func setClipboardIsolation(
        _ isolated: Bool,
        text: NSData?,
        request: NSDictionary,
        reply: @escaping (NSDictionary) -> Void
    )

    @objc(offerCompanionInstallerWithRequest:reply:)
    func offerCompanionInstaller(
        request: NSDictionary,
        reply: @escaping (NSDictionary) -> Void
    )

    @objc(clearCompanionInstallerWithRequest:reply:)
    func clearCompanionInstaller(
        request: NSDictionary,
        reply: @escaping (NSDictionary) -> Void
    )

    @objc(cancelRequest:reply:)
    func cancelRequest(_ cancellation: NSDictionary, reply: @escaping (NSDictionary) -> Void)

    @objc(copyFrameWithReply:)
    func copyFrame(reply: @escaping (NSData?, NSDictionary) -> Void)

    @objc(pingWithReply:)
    func ping(reply: @escaping (NSDictionary) -> Void)

#if DEBUG
    @objc(crashForTestingWithReply:)
    func crashForTesting(reply: @escaping () -> Void)
#endif
}

nonisolated struct FreeRDPXPCFailure: LocalizedError, Sendable {
    var code: String
    var message: String

    var errorDescription: String? { "\(code): \(message)" }
}

nonisolated struct FreeRDPFrameCopy: @unchecked Sendable {
    var pixels: Data
    var metadata: [String: Any]
}

nonisolated struct RDPCompanionInstallerOffer: Equatable, Sendable {
    static let remoteFileNamePrefix = "JTS-Companion-"
    static let remoteFileNameSuffix = ".exe"

    let fileName: String
    let fileSize: UInt64
    let sha256: String

    static func isValidRemoteFileName(_ value: String) -> Bool {
        guard value.hasPrefix(remoteFileNamePrefix),
              value.hasSuffix(remoteFileNameSuffix) else {
            return false
        }
        let token = value
            .dropFirst(remoteFileNamePrefix.count)
            .dropLast(remoteFileNameSuffix.count)
        return token.utf8.count == 32 && token.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

nonisolated enum FreeRDPXPCRequestDeadlines {
    static let connect: TimeInterval = 10
    static let ping: TimeInterval = 2
    static let disconnect: TimeInterval = 2
    static let input: TimeInterval = 2
    static let dvc: TimeInterval = 2
    static let clipboard: TimeInterval = 2
    static let companionInstaller: TimeInterval = 10
    static let copyFrame: TimeInterval = 5
    static let remoteCancellation: TimeInterval = 0.25
}

@MainActor
final class FreeRDPXPCSession {
    static let serviceName = "com.lljts.JTSTerminal.FreeRDPService"

    private struct ConnectionBinding {
        let connection: NSXPCConnection
        let generation: UInt64
        let attemptID: UUID
    }

    var onState: (([String: Any]) -> Void)?
    var onSurface: ((IOSurface, [String: Any]) -> Void)?
    var onDVCMessage: ((Data, UInt64) -> Void)?
    var onClipboardText: ((Data) -> Void)?
    var onCertificateChallenge: (([String: Any]) -> Void)?
    var onInvalidation: ((UUID, String) -> Void)?

    private var connection: NSXPCConnection?
    private var callbackSink: FreeRDPXPCClientSink?
    private var connectionGeneration: UInt64 = 0
    private var activeConnectionGeneration: UInt64?
    private var activeConnectionAttemptID: UUID?
    private var activeClipboardIsolationGeneration: UInt64 = 0
    private let requestCoordinator = XPCRequestCoordinator()

    init() {}

    deinit {
        requestCoordinator.failAll(FreeRDPXPCFailure(
            code: "RDP_XPC_INVALIDATED",
            message: "The FreeRDP XPC session was released."
        ))
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
    }

    func connect(
        configuration: [String: Any],
        relaySocket: FileHandle? = nil,
        deadlineMilliseconds: Int? = nil
    ) async throws {
        guard let rawAttemptID = configuration["connectionAttemptId"] as? String,
              rawAttemptID.count == 36,
              let connectionAttemptID = UUID(uuidString: rawAttemptID) else {
            throw FreeRDPXPCFailure(
                code: "INVALID_CONFIGURATION",
                message: "The RDP connection attempt identifier is invalid."
            )
        }
        invalidateConnection(failingPendingWith: FreeRDPXPCFailure(
            code: "RDP_XPC_REPLACED",
            message: "A new FreeRDP XPC connection replaced the previous connection."
        ))
        connectionGeneration &+= 1
        let generation = connectionGeneration

        let connection = NSXPCConnection(serviceName: Self.serviceName)
        let binding = ConnectionBinding(
            connection: connection,
            generation: generation,
            attemptID: connectionAttemptID
        )
        let serviceInterface = NSXPCInterface(with: JTFreeRDPServiceXPCProtocol.self)
        Self.configureServiceInterface(serviceInterface)
        connection.remoteObjectInterface = serviceInterface
        let callbackSink = FreeRDPXPCClientSink(owner: self, generation: generation)
        let clientInterface = NSXPCInterface(with: JTFreeRDPClientXPCProtocol.self)
        let surfaceClasses = NSSet(object: IOSurface.self) as! Set<AnyHashable>
        clientInterface.setClasses(
            surfaceClasses,
            for: #selector(JTFreeRDPClientXPCProtocol.desktopDidUpdateSurface(_:metadata:)),
            argumentIndex: 0,
            ofReply: false
        )
        Self.configureClientInterface(clientInterface)
        connection.exportedInterface = clientInterface
        connection.exportedObject = callbackSink
#if !DEBUG
        connection.setCodeSigningRequirement(
            "anchor apple generic and identifier \"com.lljts.JTSTerminal.FreeRDPService\" and certificate leaf[subject.OU] = \"YOURTEAMID\""
        )
#endif
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleUnexpectedConnectionLoss(
                    binding: binding,
                    code: "RDP_XPC_INTERRUPTED",
                    message: "The FreeRDP XPC helper was interrupted."
                )
            }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleUnexpectedConnectionLoss(
                    binding: binding,
                    code: "RDP_XPC_INVALIDATED",
                    message: "The FreeRDP XPC helper connection was invalidated."
                )
            }
        }
        self.connection = connection
        self.callbackSink = callbackSink
        activeConnectionGeneration = generation
        activeConnectionAttemptID = connectionAttemptID
        activeClipboardIsolationGeneration = 0
        connection.resume()

        var generationBoundConfiguration = configuration
        generationBoundConfiguration["connectionGeneration"] = generation
        generationBoundConfiguration["connectionAttemptId"] = connectionAttemptID.uuidString.lowercased()
        do {
            let result: [String: Any] = try await requestCoordinator.perform(
                deadlineSeconds: Self.connectDeadlineSeconds(
                    requestedMilliseconds: deadlineMilliseconds
                )
            ) { completion in
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    completion(.failure(Self.proxyFailure(error)))
                }) as? JTFreeRDPServiceXPCProtocol else {
                    completion(.failure(FreeRDPXPCFailure(
                        code: "XPC_PROXY_UNAVAILABLE",
                        message: "The signed FreeRDP XPC service is unavailable."
                    )))
                    return
                }
                let receive: (NSDictionary) -> Void = { reply in
                    completion(.success(reply as? [String: Any] ?? [:]))
                }
                if let relaySocket {
                    proxy.connect(withConfiguration: generationBoundConfiguration as NSDictionary,
                                  relaySocket: relaySocket, reply: receive)
                } else {
                    proxy.connect(withConfiguration: generationBoundConfiguration as NSDictionary, reply: receive)
                }
            }
            try Self.requireSuccess(result)
            guard isCurrent(binding),
                  let echoedAttempt = result["connectionAttemptId"] as? String,
                  UUID(uuidString: echoedAttempt) == connectionAttemptID else {
                throw FreeRDPXPCFailure(
                    code: "RDP_XPC_PROTOCOL_VIOLATION",
                    message: "The FreeRDP XPC helper did not bind its reply to the requested connection attempt."
                )
            }
        } catch {
            let normalizedError = Self.normalizedRequestError(error, operation: "connect")
            let teardownFailure = normalizedError as? FreeRDPXPCFailure ?? FreeRDPXPCFailure(
                code: "RDP_XPC_CONNECT_ABORTED",
                message: "The FreeRDP XPC connection attempt did not complete."
            )
            invalidateConnection(binding, failingPendingWith: teardownFailure)
            throw normalizedError
        }
    }

    func disconnect() async {
        guard let binding = currentConnectionBinding() else {
            invalidateConnection(failingPendingWith: FreeRDPXPCFailure(
                code: "RDP_XPC_DISCONNECTED",
                message: "The FreeRDP XPC helper disconnected."
            ))
            return
        }

        do {
            let _: Void = try await requestCoordinator.perform(
                deadlineSeconds: FreeRDPXPCRequestDeadlines.disconnect
            ) { completion in
                guard let proxy = binding.connection.remoteObjectProxyWithErrorHandler({ error in
                    completion(.failure(Self.proxyFailure(error)))
                }) as? JTFreeRDPServiceXPCProtocol else {
                    completion(.failure(FreeRDPXPCFailure(
                        code: "XPC_PROXY_UNAVAILABLE",
                        message: "The signed FreeRDP XPC service is unavailable."
                    )))
                    return
                }
                proxy.disconnect {
                    completion(.success(()))
                }
            }
        } catch {
            // Teardown below is authoritative. Proxy, interruption, invalidation,
            // and cancellation failures all converge on the same local state.
        }
        invalidateConnection(binding, failingPendingWith: FreeRDPXPCFailure(
            code: "RDP_XPC_DISCONNECTED",
            message: "The FreeRDP XPC helper disconnected."
        ))
    }

    func invalidateImmediately() {
        invalidateConnection(failingPendingWith: FreeRDPXPCFailure(
            code: "RDP_XPC_INVALIDATED",
            message: "The FreeRDP XPC connection was invalidated."
        ))
    }

    func sendInput(
        _ input: [String: Any],
        deadlineMilliseconds: Int? = nil
    ) async throws {
        try await performMutatingRequest(
            operation: "input",
            defaultDeadlineSeconds: FreeRDPXPCRequestDeadlines.input,
            requestedDeadlineMilliseconds: deadlineMilliseconds
        ) { proxy, envelope, reply in
            proxy.sendInput(input as NSDictionary, request: envelope, reply: reply)
        }
    }

    func sendDVCMessage(
        _ message: Data,
        expectedChannelGeneration: UInt64,
        deadlineMilliseconds: Int? = nil
    ) async throws {
        try await performMutatingRequest(
            operation: "DVC",
            defaultDeadlineSeconds: FreeRDPXPCRequestDeadlines.dvc,
            requestedDeadlineMilliseconds: deadlineMilliseconds
        ) { proxy, envelope, reply in
            proxy.sendDVCMessage(
                message as NSData,
                request: envelope,
                expectedChannelGeneration: expectedChannelGeneration,
                reply: reply
            )
        }
    }

    func updateClipboardText(
        _ text: Data?,
        deadlineMilliseconds: Int? = nil
    ) async throws {
        if let text {
            do {
                _ = try RDPTextClipboardCodec.decode(text)
            } catch {
                throw FreeRDPXPCFailure(
                    code: "RDP_CLIPBOARD_TEXT_INVALID",
                    message: "Clipboard text must be valid UTF-8 without embedded null characters and no larger than 4 MiB."
                )
            }
        }
        try await performMutatingRequest(
            operation: "clipboard",
            defaultDeadlineSeconds: FreeRDPXPCRequestDeadlines.clipboard,
            requestedDeadlineMilliseconds: deadlineMilliseconds
        ) { proxy, envelope, reply in
            proxy.updateClipboardText(
                text.map { $0 as NSData },
                request: envelope,
                reply: reply
            )
        }
    }

    func setClipboardIsolation(
        _ isolated: Bool,
        text: Data?,
        deadlineMilliseconds: Int? = nil
    ) async throws {
        if let text {
            do {
                _ = try RDPTextClipboardCodec.decode(text)
            } catch {
                throw FreeRDPXPCFailure(
                    code: "RDP_CLIPBOARD_TEXT_INVALID",
                    message: "Clipboard text must be valid UTF-8 without embedded null characters and no larger than 4 MiB."
                )
            }
        }
        let expectedConnectionGeneration = activeConnectionGeneration
        let expectedAttemptID = activeConnectionAttemptID
        try await performMutatingRequest(
            operation: isolated ? "clipboard isolation" : "clipboard resume",
            defaultDeadlineSeconds: FreeRDPXPCRequestDeadlines.clipboard,
            requestedDeadlineMilliseconds: deadlineMilliseconds
        ) { proxy, envelope, reply in
            proxy.setClipboardIsolation(
                isolated,
                text: text.map { $0 as NSData },
                request: envelope,
                reply: reply
            )
        }
        guard activeConnectionGeneration == expectedConnectionGeneration,
              activeConnectionAttemptID == expectedAttemptID else {
            throw FreeRDPXPCFailure(
                code: "RDP_CLIPBOARD_CONNECTION_CHANGED",
                message: "The RDP connection changed while applying clipboard isolation."
            )
        }
        activeClipboardIsolationGeneration =
            activeClipboardIsolationGeneration == .max
                ? 1
                : activeClipboardIsolationGeneration + 1
    }

    func offerCompanionInstaller(
        deadlineMilliseconds: Int? = nil
    ) async throws -> RDPCompanionInstallerOffer {
        guard let binding = currentConnectionBinding() else {
            throw FreeRDPXPCFailure(
                code: "XPC_NOT_CONNECTED",
                message: "The FreeRDP XPC helper is not connected."
            )
        }
        let expectedGeneration = binding.generation
        let expectedAttemptID = binding.attemptID
        let result = try await performMutatingRequest(
            operation: "Companion installer offer",
            defaultDeadlineSeconds: FreeRDPXPCRequestDeadlines.companionInstaller,
            requestedDeadlineMilliseconds: deadlineMilliseconds
        ) { proxy, envelope, reply in
            proxy.offerCompanionInstaller(request: envelope, reply: reply)
        }
        guard activeConnectionGeneration == expectedGeneration,
              activeConnectionAttemptID == expectedAttemptID,
              let fileName = result["fileName"] as? String,
              RDPCompanionInstallerOffer.isValidRemoteFileName(fileName),
              let fileSize = Self.boundedUnsignedInteger(
                  result["fileSize"],
                  minimum: 1,
                  maximum: UInt64(UInt32.max)
              ),
              let sha256 = result["sha256"] as? String,
              Self.isLowercaseSHA256(sha256),
              let echoedAttemptID = result["connectionAttemptId"] as? String,
              UUID(uuidString: echoedAttemptID) == expectedAttemptID else {
            let failure = FreeRDPXPCFailure(
                code: "RDP_XPC_PROTOCOL_VIOLATION",
                message: "The FreeRDP XPC helper returned invalid Companion installer metadata."
            )
            if invalidateConnection(binding, failingPendingWith: failure) {
                onInvalidation?(binding.attemptID, failure.message)
            }
            throw failure
        }
        return RDPCompanionInstallerOffer(
            fileName: fileName,
            fileSize: fileSize,
            sha256: sha256
        )
    }

    func clearCompanionInstallerOffer(
        deadlineMilliseconds: Int? = nil
    ) async throws {
        try await performMutatingRequest(
            operation: "Companion installer clear",
            defaultDeadlineSeconds: FreeRDPXPCRequestDeadlines.companionInstaller,
            requestedDeadlineMilliseconds: deadlineMilliseconds
        ) { proxy, envelope, reply in
            proxy.clearCompanionInstaller(request: envelope, reply: reply)
        }
    }

    func copyFrame() async throws -> FreeRDPFrameCopy {
        guard let binding = currentConnectionBinding() else {
            throw FreeRDPXPCFailure(code: "XPC_NOT_CONNECTED", message: "The FreeRDP XPC helper is not connected.")
        }
        do {
            return try await performOrdinaryRequest(
                operation: "frame copy",
                deadlineSeconds: FreeRDPXPCRequestDeadlines.copyFrame,
                binding: binding
            ) { completion in
                guard let proxy = binding.connection.remoteObjectProxyWithErrorHandler({ error in
                    completion(.failure(Self.proxyFailure(error)))
                }) as? JTFreeRDPServiceXPCProtocol else {
                    completion(.failure(FreeRDPXPCFailure(
                        code: "XPC_PROXY_UNAVAILABLE",
                        message: "The FreeRDP XPC service proxy is unavailable."
                    )))
                    return
                }
                proxy.copyFrame { pixels, metadata in
                    guard let pixels else {
                        completion(.failure(FreeRDPXPCFailure(
                            code: "FRAME_UNAVAILABLE",
                            message: "The RDP desktop has not produced a framebuffer yet."
                        )))
                        return
                    }
                    guard let validated = FreeRDPXPCInboundValidation.frameCopy(
                        pixels: pixels,
                        metadata: metadata
                    ),
                    let rawAttemptID = validated["connectionAttemptId"] as? String,
                    UUID(uuidString: rawAttemptID) == binding.attemptID else {
                        completion(.failure(FreeRDPXPCFailure(
                            code: "RDP_XPC_PROTOCOL_VIOLATION",
                            message: "The FreeRDP XPC helper returned an invalid frame copy."
                        )))
                        return
                    }
                    completion(.success(FreeRDPFrameCopy(
                        pixels: pixels as Data,
                        metadata: validated
                    )))
                }
            }
        } catch let failure as FreeRDPXPCFailure where failure.code == "RDP_XPC_PROTOCOL_VIOLATION" {
            handleProtocolViolation(failure.message, binding: binding)
            throw failure
        }
    }

    func ping() async throws -> [String: Any] {
        try await request(
            operation: "ping",
            deadlineSeconds: FreeRDPXPCRequestDeadlines.ping
        ) { proxy, reply in
            proxy.ping(reply: reply)
        }
    }

    private func request(
        operation: String,
        deadlineSeconds: TimeInterval,
        _ body: @escaping (JTFreeRDPServiceXPCProtocol, @escaping (NSDictionary) -> Void) -> Void
    ) async throws -> [String: Any] {
        guard let binding = currentConnectionBinding() else {
            throw FreeRDPXPCFailure(code: "XPC_NOT_CONNECTED", message: "The FreeRDP XPC helper is not connected.")
        }
        return try await performOrdinaryRequest(
            operation: operation,
            deadlineSeconds: deadlineSeconds,
            binding: binding
        ) { completion in
            guard let proxy = binding.connection.remoteObjectProxyWithErrorHandler({ error in
                completion(.failure(Self.proxyFailure(error)))
            }) as? JTFreeRDPServiceXPCProtocol else {
                completion(.failure(FreeRDPXPCFailure(
                    code: "XPC_PROXY_UNAVAILABLE",
                    message: "The FreeRDP XPC service proxy is unavailable."
                )))
                return
            }
            body(proxy) { reply in
                completion(.success(reply as? [String: Any] ?? [:]))
            }
        }
    }

    @discardableResult
    private func performMutatingRequest(
        operation: String,
        defaultDeadlineSeconds: TimeInterval,
        requestedDeadlineMilliseconds: Int?,
        _ body: @escaping (
            JTFreeRDPServiceXPCProtocol,
            NSDictionary,
            @escaping (NSDictionary) -> Void
        ) -> Void
    ) async throws -> [String: Any] {
        guard let connection,
              let generation = activeConnectionGeneration,
              let connectionAttemptID = activeConnectionAttemptID else {
            throw FreeRDPXPCFailure(
                code: "XPC_NOT_CONNECTED",
                message: "The FreeRDP XPC helper is not connected."
            )
        }
        let deadlineSeconds = Self.mutationDeadlineSeconds(
            requestedMilliseconds: requestedDeadlineMilliseconds,
            defaultSeconds: defaultDeadlineSeconds
        )
        let requestID = UUID()
        let deadlineUptimeMilliseconds = UInt64(
            max(1, (ProcessInfo.processInfo.systemUptime + deadlineSeconds) * 1_000)
        )
        let envelope: NSDictionary = [
            "requestId": requestID.uuidString.lowercased(),
            "connectionGeneration": generation,
            "connectionAttemptId": connectionAttemptID.uuidString.lowercased(),
            "deadlineUptimeMilliseconds": deadlineUptimeMilliseconds,
        ]

        do {
            let result: [String: Any] = try await requestCoordinator.perform(
                deadlineSeconds: deadlineSeconds
            ) { completion in
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    completion(.failure(Self.proxyFailure(error)))
                }) as? JTFreeRDPServiceXPCProtocol else {
                    completion(.failure(FreeRDPXPCFailure(
                        code: "XPC_PROXY_UNAVAILABLE",
                        message: "The FreeRDP XPC service proxy is unavailable."
                    )))
                    return
                }
                body(proxy, envelope) { reply in
                    completion(.success(reply as? [String: Any] ?? [:]))
                }
            }
            try Self.requireSuccess(result)
            return result
        } catch {
            let isAbandonedMutation = error is CancellationError || error is XPCRequestTimeoutFailure
            guard isAbandonedMutation else { throw error }

            _ = await requestRemoteCancellation(
                requestID: requestID,
                generation: generation,
                connectionAttemptID: connectionAttemptID,
                connection: connection
            )
            let normalized: Error = error is XPCRequestTimeoutFailure
                ? Self.normalizedRequestError(error, operation: operation)
                : error
            if self.connection === connection,
               activeConnectionGeneration == generation,
               activeConnectionAttemptID == connectionAttemptID {
                let failure = normalized as? FreeRDPXPCFailure ?? FreeRDPXPCFailure(
                    code: "RDP_XPC_MUTATION_CANCELLED",
                    message: "The FreeRDP XPC \(operation) request was cancelled; the helper connection was invalidated to prevent late execution."
                )
                invalidateConnection(failingPendingWith: failure)
                onInvalidation?(connectionAttemptID, failure.message)
            }
            throw normalized
        }
    }

    private static func boundedUnsignedInteger(
        _ value: Any?,
        minimum: UInt64,
        maximum: UInt64
    ) -> UInt64? {
        let number: NSNumber
        if let candidate = value as? NSNumber {
            number = candidate
        } else {
            return nil
        }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.stringValue
        guard !raw.hasPrefix("-"), let parsed = UInt64(raw),
              parsed >= minimum, parsed <= maximum else {
            return nil
        }
        return parsed
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func requestRemoteCancellation(
        requestID: UUID,
        generation: UInt64,
        connectionAttemptID: UUID,
        connection: NSXPCConnection
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let resolver = XPCRemoteCancellationResolver(continuation: continuation)
            let timeout = DispatchWorkItem {
                resolver.resolve(false)
            }
            resolver.install(timeout: timeout)
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + FreeRDPXPCRequestDeadlines.remoteCancellation,
                execute: timeout
            )
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                resolver.resolve(false)
            }) as? JTFreeRDPServiceXPCProtocol else {
                resolver.resolve(false)
                return
            }
            proxy.cancelRequest([
                "requestId": requestID.uuidString.lowercased(),
                "connectionGeneration": generation,
                "connectionAttemptId": connectionAttemptID.uuidString.lowercased(),
            ] as NSDictionary) { result in
                resolver.resolve(result["ok"] as? Bool == true)
            }
        }
    }

    private func performOrdinaryRequest<Value>(
        operation: String,
        deadlineSeconds: TimeInterval,
        binding: ConnectionBinding,
        _ start: (@escaping (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        do {
            return try await requestCoordinator.perform(
                deadlineSeconds: deadlineSeconds,
                start
            )
        } catch let timeout as XPCRequestTimeoutFailure {
            let failure = Self.timeoutFailure(timeout, operation: operation)
            if invalidateConnection(binding, failingPendingWith: failure) {
                onInvalidation?(binding.attemptID, failure.message)
            }
            throw failure
        }
    }

    private func currentConnectionBinding() -> ConnectionBinding? {
        guard let connection,
              let generation = activeConnectionGeneration,
              let attemptID = activeConnectionAttemptID else {
            return nil
        }
        return ConnectionBinding(
            connection: connection,
            generation: generation,
            attemptID: attemptID
        )
    }

    private func isCurrent(_ binding: ConnectionBinding) -> Bool {
        connection === binding.connection
            && activeConnectionGeneration == binding.generation
            && activeConnectionAttemptID == binding.attemptID
    }

    @discardableResult
    private func invalidateConnection(
        _ binding: ConnectionBinding,
        failingPendingWith failure: FreeRDPXPCFailure
    ) -> Bool {
        guard isCurrent(binding) else { return false }
        invalidateConnection(failingPendingWith: failure)
        return true
    }

    private func invalidateConnection(failingPendingWith failure: FreeRDPXPCFailure) {
        activeConnectionGeneration = nil
        activeConnectionAttemptID = nil
        activeClipboardIsolationGeneration = 0
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
        callbackSink = nil
        requestCoordinator.failAll(failure)
    }

    private func handleUnexpectedConnectionLoss(
        binding: ConnectionBinding,
        code: String,
        message: String
    ) {
        guard invalidateConnection(
            binding,
            failingPendingWith: FreeRDPXPCFailure(code: code, message: message)
        ) else { return }
        onInvalidation?(binding.attemptID, message)
    }

    fileprivate func receiveState(_ state: [String: Any], generation: UInt64) {
        guard callbackMatchesActiveAttempt(state, generation: generation) else { return }
        onState?(state)
    }

    fileprivate func receiveSurface(_ surface: IOSurface, metadata: [String: Any], generation: UInt64) {
        guard callbackMatchesActiveAttempt(metadata, generation: generation) else { return }
        onSurface?(surface, metadata)
    }

    fileprivate func receiveDVCMessage(
        _ message: FreeRDPValidatedDVCMessage,
        generation: UInt64
    ) {
        guard activeConnectionGeneration == generation,
              activeConnectionAttemptID == message.connectionAttemptID else { return }
        onDVCMessage?(message.data, message.channelGeneration)
    }

    fileprivate func receiveClipboardText(
        _ message: FreeRDPValidatedClipboardText,
        generation: UInt64
    ) {
        guard activeConnectionGeneration == generation,
              activeConnectionAttemptID == message.connectionAttemptID,
              activeClipboardIsolationGeneration == message.isolationGeneration else {
            return
        }
        onClipboardText?(message.data)
    }

    fileprivate func receiveCertificateChallenge(_ certificate: [String: Any], generation: UInt64) {
        guard callbackMatchesActiveAttempt(certificate, generation: generation) else { return }
        onCertificateChallenge?(certificate)
    }

    private func callbackMatchesActiveAttempt(
        _ metadata: [String: Any],
        generation: UInt64
    ) -> Bool {
        guard activeConnectionGeneration == generation,
              let activeConnectionAttemptID,
              let rawAttemptID = metadata["connectionAttemptId"] as? String,
              UUID(uuidString: rawAttemptID) == activeConnectionAttemptID else {
            return false
        }
        return true
    }

    fileprivate func receiveProtocolViolation(_ message: String, generation: UInt64?) {
        guard let generation,
              let binding = currentConnectionBinding(),
              binding.generation == generation else { return }
        handleProtocolViolation(message, binding: binding)
    }

    private func handleProtocolViolation(
        _ message: String,
        binding: ConnectionBinding
    ) {
        let failure = FreeRDPXPCFailure(code: "RDP_XPC_PROTOCOL_VIOLATION", message: message)
        guard invalidateConnection(binding, failingPendingWith: failure) else { return }
        onInvalidation?(binding.attemptID, message)
    }

    private static func requireSuccess(_ result: [String: Any]) throws {
        guard result["ok"] as? Bool == true else {
            throw FreeRDPXPCFailure(
                code: result["code"] as? String ?? "RDP_XPC_REQUEST_FAILED",
                message: result["message"] as? String ?? "The FreeRDP XPC request failed."
            )
        }
    }

    private static func proxyFailure(_ error: Error) -> FreeRDPXPCFailure {
        FreeRDPXPCFailure(
            code: "RDP_XPC_PROXY_ERROR",
            message: error.localizedDescription
        )
    }

    private static func normalizedRequestError(_ error: Error, operation: String) -> Error {
        guard let timeout = error as? XPCRequestTimeoutFailure else {
            return error
        }
        return timeoutFailure(timeout, operation: operation)
    }

    private static func timeoutFailure(
        _ timeout: XPCRequestTimeoutFailure,
        operation: String
    ) -> FreeRDPXPCFailure {
        FreeRDPXPCFailure(
            code: timeout.code,
            message: "The FreeRDP XPC \(operation) request did not reply within \(timeout.deadlineSeconds) seconds. The stalled helper connection was invalidated."
        )
    }

    private static func mutationDeadlineSeconds(
        requestedMilliseconds: Int?,
        defaultSeconds: TimeInterval
    ) -> TimeInterval {
        guard let requestedMilliseconds else { return defaultSeconds }
        let requested = TimeInterval(requestedMilliseconds) / 1_000
        return min(defaultSeconds, max(0.1, requested))
    }

    nonisolated static func connectDeadlineSeconds(
        requestedMilliseconds: Int?
    ) -> TimeInterval {
        guard let requestedMilliseconds else {
            return FreeRDPXPCRequestDeadlines.connect
        }
        let requested = TimeInterval(requestedMilliseconds) / 1_000
        return min(FreeRDPXPCRequestDeadlines.connect, max(0.1, requested))
    }

    private static func configureServiceInterface(_ interface: NSXPCInterface) {
        let propertyList = propertyListClasses
        let data = dataClasses
        let relaySelector = #selector(JTFreeRDPServiceXPCProtocol.connect(withConfiguration:relaySocket:reply:))
        interface.setClasses(propertyList, for: relaySelector, argumentIndex: 0, ofReply: false)
        interface.setClasses(NSSet(object: FileHandle.self) as! Set<AnyHashable>,
                             for: relaySelector, argumentIndex: 1, ofReply: false)
        interface.setClasses(propertyList, for: relaySelector, argumentIndex: 0, ofReply: true)
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.connect(withConfiguration:reply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.connect(withConfiguration:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.sendInput(_:request:reply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.sendInput(_:request:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.sendInput(_:request:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            data,
            for: #selector(JTFreeRDPServiceXPCProtocol.sendDVCMessage(_:request:expectedChannelGeneration:reply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.sendDVCMessage(_:request:expectedChannelGeneration:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.sendDVCMessage(_:request:expectedChannelGeneration:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            data,
            for: #selector(JTFreeRDPServiceXPCProtocol.updateClipboardText(_:request:reply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.updateClipboardText(_:request:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.updateClipboardText(_:request:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            data,
            for: #selector(JTFreeRDPServiceXPCProtocol.setClipboardIsolation(_:text:request:reply:)),
            argumentIndex: 1,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.setClipboardIsolation(_:text:request:reply:)),
            argumentIndex: 2,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.setClipboardIsolation(_:text:request:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.offerCompanionInstaller(request:reply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.offerCompanionInstaller(request:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.clearCompanionInstaller(request:reply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.clearCompanionInstaller(request:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.cancelRequest(_:reply:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.cancelRequest(_:reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            data,
            for: #selector(JTFreeRDPServiceXPCProtocol.copyFrame(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.copyFrame(reply:)),
            argumentIndex: 1,
            ofReply: true
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPServiceXPCProtocol.ping(reply:)),
            argumentIndex: 0,
            ofReply: true
        )
    }

    private static func configureClientInterface(_ interface: NSXPCInterface) {
        let propertyList = propertyListClasses
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPClientXPCProtocol.desktopDidChangeState(_:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPClientXPCProtocol.desktopDidUpdateSurface(_:metadata:)),
            argumentIndex: 1,
            ofReply: false
        )
        interface.setClasses(
            dataClasses,
            for: #selector(JTFreeRDPClientXPCProtocol.desktopDidReceiveDVCMessage(_:metadata:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPClientXPCProtocol.desktopDidReceiveDVCMessage(_:metadata:)),
            argumentIndex: 1,
            ofReply: false
        )
        interface.setClasses(
            dataClasses,
            for: #selector(JTFreeRDPClientXPCProtocol.desktopDidReceiveClipboardText(_:metadata:)),
            argumentIndex: 0,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPClientXPCProtocol.desktopDidReceiveClipboardText(_:metadata:)),
            argumentIndex: 1,
            ofReply: false
        )
        interface.setClasses(
            propertyList,
            for: #selector(JTFreeRDPClientXPCProtocol.desktopDidRequireCertificateDecision(_:)),
            argumentIndex: 0,
            ofReply: false
        )
    }

    private static var propertyListClasses: Set<AnyHashable> {
        NSSet(array: [
            NSDictionary.self,
            NSArray.self,
            NSString.self,
            NSNumber.self,
            NSData.self,
        ]) as! Set<AnyHashable>
    }

    private static var dataClasses: Set<AnyHashable> {
        NSSet(object: NSData.self) as! Set<AnyHashable>
    }
}

nonisolated private final class XPCRemoteCancellationResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: DispatchWorkItem?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func install(timeout: DispatchWorkItem) {
        lock.lock()
        if continuation != nil {
            self.timeout = timeout
            lock.unlock()
        } else {
            lock.unlock()
            timeout.cancel()
        }
    }

    func resolve(_ value: Bool) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let timeout = timeout
        self.timeout = nil
        lock.unlock()
        timeout?.cancel()
        continuation.resume(returning: value)
    }
}

private final class FreeRDPXPCClientSink: NSObject, JTFreeRDPClientXPCProtocol, @unchecked Sendable {
    private struct SurfaceDelivery {
        let surface: IOSurface
        let metadata: [String: Any]
    }

    weak var owner: FreeRDPXPCSession?
    let generation: UInt64
    private let limiter = FreeRDPXPCInboundLimiter()
    private let surfaceLimiter = FreeRDPXPCInboundLimiter(
        maximumPendingCallbacks: 2,
        maximumPendingBytes: FreeRDPXPCInboundValidation.maximumFramebufferBytes * 2
    )
    private lazy var surfaceSlot = FreeRDPXPCLatestCallbackSlot<SurfaceDelivery>(
        limiter: surfaceLimiter,
        reservedByteCost: FreeRDPXPCInboundValidation.maximumFramebufferBytes
    )

    init(owner: FreeRDPXPCSession, generation: UInt64) {
        self.owner = owner
        self.generation = generation
    }

    func desktopDidChangeState(_ state: NSDictionary) {
        guard let value = FreeRDPXPCInboundValidation.state(state) else {
            reportProtocolViolation("The FreeRDP XPC helper sent an invalid state callback.")
            return
        }
        let cost = FreeRDPXPCInboundValidation.estimatedByteCost(of: value)
        guard admit(cost: cost) else { return }
        Task { @MainActor [weak owner, generation, limiter] in
            defer { limiter.complete(byteCost: cost) }
            owner?.receiveState(value, generation: generation)
        }
    }

    func desktopDidUpdateSurface(_ surface: IOSurface, metadata: NSDictionary) {
        guard let value = FreeRDPXPCInboundValidation.surfaceMetadata(
            metadata,
            surface: surface
        ) else {
            reportProtocolViolation("The FreeRDP XPC helper sent an invalid surface callback.")
            return
        }
        guard !limiter.hasRejectedInput else { return }
        switch surfaceSlot.submit(SurfaceDelivery(surface: surface, metadata: value)) {
        case .scheduleDrain:
            scheduleSurfaceDrain()
        case .coalesced:
            break
        case .firstRejection:
            _ = limiter.reject()
            notifyProtocolViolation(
                "The FreeRDP XPC helper exceeded the bounded callback queue."
            )
        case .rejected:
            break
        }
    }

    func desktopDidReceiveDVCMessage(_ message: NSData, metadata: NSDictionary) {
        guard let value = FreeRDPXPCInboundValidation.dvcMessage(
            message,
            metadata: metadata
        ) else {
            reportProtocolViolation("The FreeRDP XPC helper sent an invalid Companion DVC callback.")
            return
        }
        let cost = value.data.count
        guard admit(cost: cost) else { return }
        Task { @MainActor [weak owner, generation, limiter] in
            defer { limiter.complete(byteCost: cost) }
            owner?.receiveDVCMessage(value, generation: generation)
        }
    }

    func desktopDidReceiveClipboardText(_ text: NSData, metadata: NSDictionary) {
        guard let value = FreeRDPXPCInboundValidation.clipboardText(
            text,
            metadata: metadata
        ) else {
            reportProtocolViolation("The FreeRDP XPC helper sent invalid clipboard text.")
            return
        }
        let cost = value.data.count
        guard admit(cost: cost) else { return }
        Task { @MainActor [weak owner, generation, limiter] in
            defer { limiter.complete(byteCost: cost) }
            owner?.receiveClipboardText(value, generation: generation)
        }
    }

    func desktopDidRequireCertificateDecision(_ certificate: NSDictionary) {
        guard let value = FreeRDPXPCInboundValidation.certificate(certificate) else {
            reportProtocolViolation("The FreeRDP XPC helper sent an invalid certificate callback.")
            return
        }
        let cost = FreeRDPXPCInboundValidation.estimatedByteCost(of: value)
        guard admit(cost: cost) else { return }
        Task { @MainActor [weak owner, generation, limiter] in
            defer { limiter.complete(byteCost: cost) }
            owner?.receiveCertificateChallenge(value, generation: generation)
        }
    }

    private func admit(cost: Int) -> Bool {
        switch limiter.admit(byteCost: cost) {
        case .accepted:
            return true
        case .firstRejection:
            _ = surfaceLimiter.reject()
            notifyProtocolViolation(
                "The FreeRDP XPC helper exceeded the bounded callback queue."
            )
            return false
        case .rejected:
            return false
        }
    }

    private func reportProtocolViolation(_ message: String) {
        guard limiter.reject() == .firstRejection else { return }
        _ = surfaceLimiter.reject()
        notifyProtocolViolation(message)
    }

    private func notifyProtocolViolation(_ message: String) {
        Task { @MainActor [weak owner, generation] in
            owner?.receiveProtocolViolation(message, generation: generation)
        }
    }

    private func scheduleSurfaceDrain() {
        Task { @MainActor [weak self] in
            self?.drainLatestSurface()
        }
    }

    @MainActor
    private func drainLatestSurface() {
        if let delivery = surfaceSlot.takeLatestForDelivery() {
            owner?.receiveSurface(
                delivery.surface,
                metadata: delivery.metadata,
                generation: generation
            )
        }
        if surfaceSlot.finishDelivery() {
            scheduleSurfaceDrain()
        }
    }
}

#endif
