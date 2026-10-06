import AppKit
import Combine
import Foundation
import JTSCompanionTransport
import JTSRelayEnrollment

@MainActor
final class NativeRelayHostRuntime: ObservableObject {
    @Published var invitationCode = ""
    @Published var controllerName = "我的管理电脑"
    @Published private(set) var trust: NativeRelayHostTrust?
    @Published private(set) var preview: EnrollmentHostAuthorization?
    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var status = "尚未配对公网连接"
    @Published private(set) var error: String?
    @Published private(set) var nativeServiceAvailable: Bool?
    @Published private(set) var connectedController: String?
    @Published private(set) var identityAvailable = true

    private var configuration: NativeRelayHostConfiguration?
    private var loopTask: Task<Void, Never>?
    private var identityRetryTask: Task<Void, Never>?
    private var sessionTask: Task<Void, Never>?
    private var bridge: NativeScreenSharingBridge?
    private var generation = UUID()
    private var sessionGeneration = UUID()
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var sessionActive = CompanionPermissions.hasUserDesktopSession

    init() {
        if sessionActive { reload(allowAuthenticationUI: false) }
        observeLifecycle()
    }

    func reload(allowAuthenticationUI: Bool = true) {
        guard CompanionPermissions.hasUserDesktopSession else {
            error = "请在已登录的桌面用户中运行 Companion，不能通过 sudo 启动。"
            return
        }
        do {
            let store = NativeRelayHostStore(allowAuthenticationUI: allowAuthenticationUI)
            var value = try store.load()
            let preferences = NativeRelayHostPreferences()
            if let loaded = value, preferences.pendingRevocation || preferences.paused {
                let recovered = preferences.applying(to: loaded)
                try store.save(recovered)
                value = recovered
            }
            preferences.revocationPersisted()
            stopRuntime()
            identityRetryTask?.cancel()
            identityRetryTask = nil
            configuration = value
            publish(value)
            identityAvailable = true
            error = nil
            resumeIfNeeded()
        } catch {
            stopRuntime()
            self.error = error.localizedDescription
            identityAvailable = false
            scheduleIdentityRetry()
        }
    }

    func prepareEnrollment() {
        guard identityAvailable, !busy, configuration?.trust == nil, configuration?.attempt == nil else { return }
        let code = invitationCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, CompanionPermissions.hasUserDesktopSession else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                var value = configuration ?? NativeRelayHostConfiguration()
                // Commit this stable key before requesting the invitation's offer.
                if configuration == nil { try NativeRelayHostStore().create(value) }
                else { try NativeRelayHostStore().save(value) }
                configuration = value
                let client = try EnrollmentHostClient(privateKey: value.privateKey)
                let attempt = try await client.prepare(code: code, name: Host.current().localizedName ?? "Mac")
                value.attempt = attempt
                value.controllerName = validControllerName()
                value.attemptApproved = false
                value.claimSubmitted = false
                try NativeRelayHostStore().save(value)
                configuration = value
                publish(value)
                invitationCode = ""
                error = nil
                status = "请确认管理电脑的身份和桌面授权"
            } catch {
                self.error = error.localizedDescription
                if configuration == nil { identityAvailable = false; scheduleIdentityRetry() }
            }
        }
    }

    /// Only the explicit consent button calls this. Preparing or receiving a
    /// relay offer cannot create a local desktop grant.
    func approveEnrollment() {
        guard identityAvailable, !busy, var value = configuration, value.attempt != nil else { return }
        do {
            value.controllerName = validControllerName()
            value.attemptApproved = true
            try NativeRelayHostStore().save(value)
            configuration = value
            NativeRelayHostPreferences().resumeExplicitly()
            status = "等待管理电脑确认配对"
            resumeIfNeeded()
        } catch { self.error = error.localizedDescription }
    }

    func discardEnrollment() {
        guard !busy, var value = configuration, value.trust == nil else { return }
        do {
            value.attempt = nil
            value.attemptApproved = false
            value.claimSubmitted = false
            try NativeRelayHostStore().save(value)
            stopRuntime()
            configuration = value
            publish(value)
            status = "配对已取消；原邀请不会自动重用"
        } catch { self.error = error.localizedDescription }
    }

    func setEnabled(_ wanted: Bool) {
        guard identityAvailable, var value = configuration, value.trust != nil else { return }
        if !wanted { NativeRelayHostPreferences().pause() }
        do {
            value.enabled = wanted
            try NativeRelayHostStore().save(value)
            configuration = value
            if wanted { NativeRelayHostPreferences().resumeExplicitly() }
            publish(value)
            if wanted { resumeIfNeeded() }
            else { stopRuntime(); status = "公网系统共享已停止"; resumeIfNeeded() }
        } catch {
            if !wanted {
                configuration = value
                publish(value)
                stopRuntime()
                identityAvailable = false
                scheduleIdentityRetry()
            }
            self.error = error.localizedDescription
        }
    }

    func revoke() {
        guard !busy, var value = configuration else { return }
        NativeRelayHostPreferences().beginRevocation()
        do {
            value.enabled = false
            value.trust = nil
            value.attempt = nil
            value.attemptApproved = false
            value.claimSubmitted = false
            try NativeRelayHostStore().save(value)
            NativeRelayHostPreferences().revocationPersisted()
            stopRuntime()
            configuration = value
            publish(value)
            status = "管理电脑已撤销；再次连接需要新的邀请和本机确认"
            resumeIfNeeded()
        } catch {
            // The user's revoke action immediately stops live sharing even if
            // the durable write is blocked. Recovery must reread and poll first.
            configuration = value
            publish(value)
            stopRuntime()
            identityAvailable = false
            self.error = error.localizedDescription
            scheduleIdentityRetry()
        }
    }

    func checkNativeService() {
        Task {
            nativeServiceAvailable = await NativeSharingServiceProbe.available()
        }
    }

    func shutdown() {
        stopRuntime()
        identityRetryTask?.cancel()
        identityRetryTask = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    private func publish(_ value: NativeRelayHostConfiguration?) {
        trust = value?.trust
        enabled = value?.enabled ?? false
        controllerName = value?.controllerName ?? "我的管理电脑"
        preview = try? value?.attempt?.authorization()
        if value == nil { status = "尚未配对公网连接" }
        else if enabled { status = "正在连接中继站" }
        else if preview != nil { status = value?.attemptApproved == true ? "等待管理电脑确认配对" : "请确认管理电脑的身份和桌面授权" }
        else { status = "公网系统共享已停止" }
    }

    private func validControllerName() -> String {
        let name = controllerName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !(1...128).contains(name.utf8.count) || name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return "我的管理电脑"
        }
        return name
    }

    private func resumeIfNeeded() {
        guard identityAvailable, loopTask == nil, sessionActive, !sleeping,
              CompanionPermissions.hasUserDesktopSession, let value = configuration,
              value.trust != nil || value.attemptApproved || value.hasPendingRevocations else { return }
        let current = generation
        loopTask = Task { [weak self] in await self?.runLoop(generation: current) }
    }

    private func runLoop(generation current: UUID) async {
        var failures = 0
        while !Task.isCancelled, generation == current {
            var delay: TimeInterval = 5
            do {
                guard var value = configuration else { break }
                if let attempt = value.attempt, value.attemptApproved {
                    let client = try EnrollmentHostClient(privateKey: value.privateKey)
                    var receipt: EnrollmentHostReceipt
                    if value.claimSubmitted {
                        receipt = try await client.receipt(attempt)
                        if receipt.state == .pending { receipt = try await client.claim(attempt) }
                    } else {
                        // Persist before submission, including an ambiguous successful response.
                        value.claimSubmitted = true
                        try NativeRelayHostStore().save(value)
                        configuration = value
                        receipt = try await client.claim(attempt)
                    }
                    guard generation == current else { break }
                    if receipt.state == .bound, let authorization = receipt.authorization {
                        value.trust = NativeRelayHostTrust(name: value.controllerName, authorization: authorization)
                        value.attempt = nil
                        value.attemptApproved = false
                        value.claimSubmitted = false
                        value.enabled = true
                        try NativeRelayHostStore().save(value)
                        configuration = value
                        publish(value)
                        error = nil
                    } else if [.expired, .cancelled].contains(receipt.state) {
                        value.attemptApproved = false
                        try NativeRelayHostStore().save(value)
                        configuration = value
                        status = "邀请已过期或被取消，请使用新的配对邀请"
                        break
                    } else { status = "等待管理电脑确认配对" }
                }
                try await synchronizeRevocations(generation: current)
                guard generation == current, let latest = configuration else { break }
                value = latest
                if value.enabled, let trust = value.trust {
                    let identity = try value.identity
                    let relay = RelayHTTPClient(endpoint: try RelayEndpoint(URL(string: trust.relayOrigin)!), identity: identity)
                    try await relay.presence()
                    let offers = try await relay.poll()
                    guard generation == current, configuration?.trust == trust, enabled else { break }
                    error = nil
                    if bridge == nil, sessionTask == nil { status = "已上线，等待已授权管理电脑连接" }
                    for offer in offers where offer.lane == .rdp && offer.controllerDeviceId == trust.controllerDeviceID {
                        guard sessionTask == nil else { break }
                        accept(offer: offer, identity: identity, trust: trust, runtimeGeneration: current)
                    }
                }
                if !value.enabled, value.trust == nil, !value.attemptApproved, !value.hasPendingRevocations { break }
                failures = 0
            } catch {
                guard generation == current else { break }
                self.error = error.localizedDescription
                status = "中继连接暂不可用，正在自动重试"
                failures = min(failures + 1, 5)
                delay = min(30, pow(2, Double(failures)))
            }
            do { try await Task.sleep(for: .seconds(delay)) } catch { break }
        }
        if generation == current { loopTask = nil }
    }

    private func accept(offer: RelaySessionOffer, identity: RelayIdentity, trust: NativeRelayHostTrust, runtimeGeneration: UUID) {
        let current = UUID()
        sessionGeneration = current
        sessionTask = Task { [weak self] in
            guard let self else { return }
            var carrier: (any RelayByteCarrier)?
            var channel: (any CompanionSecureChannel)?
            defer {
                if self.sessionGeneration == current {
                    self.sessionTask = nil
                    self.bridge = nil
                    self.connectedController = nil
                }
            }
            do {
                try self.requireCurrent(runtimeGeneration, session: current, trust: trust)
                let endpoint = try RelayEndpoint(URL(string: trust.relayOrigin)!)
                let raw = try await RelayWebSocketCarrier.connect(endpoint: endpoint, ticket: offer.sessionTicket, lane: .rdp)
                carrier = raw
                try self.requireCurrent(runtimeGeneration, session: current, trust: trust)
                let peer = try PairedCompanionDevice(publicKeySPKI: trust.controllerSPKI, allowedLanes: [.rdp])
                let binding = try CompanionLaneBinding(sessionID: offer.sessionId, lane: .rdp,
                    controllerDeviceID: trust.controllerDeviceID, companionDeviceID: identity.deviceID)
                let secure = try await PinnedTLSChannelFactory().accept(carrier: raw, identity: identity, peer: peer, binding: binding)
                channel = secure
                try self.requireCurrent(runtimeGeneration, session: current, trust: trust)
                _ = try await CompanionHostLaneAuthorization.accept(channel: secure, approvedGrantIDs: [trust.rdpGrantID])
                try self.requireCurrent(runtimeGeneration, session: current, trust: trust)
                let bridge = try NativeScreenSharingBridge(channel: secure)
                self.bridge = bridge
                self.connectedController = trust.name
                self.status = "正在向 \(trust.name) 转接系统屏幕共享"
                try await bridge.run()
            } catch {
                await channel?.close()
                await carrier?.close()
                guard self.generation == runtimeGeneration else { return }
                self.error = error.localizedDescription
                self.status = "系统共享连接已结束；已授权电脑可重新连接"
            }
        }
    }

    private func requireCurrent(_ runtime: UUID, session: UUID, trust: NativeRelayHostTrust) throws {
        guard identityAvailable, generation == runtime, sessionGeneration == session, enabled,
              configuration?.trust == trust else { throw CompanionTransportError.unauthorizedDevice }
    }

    private func synchronizeRevocations(generation current: UUID) async throws {
        guard let original = configuration else { return }
        if let trust = original.trust {
            let client = try EnrollmentHostRevocationClient(privateKey: original.privateKey, relayOrigin: trust.relayOrigin)
            let requests = try await client.poll(authorizations: [trust.authorization])
            guard generation == current else { throw CancellationError() }
            if let request = requests.first, var value = configuration, value.trust == trust {
                try value.deny(request, authorization: trust.authorization)
                // Denial, the old pin and signed request are one atomic vault record.
                // A storage failure still closes current connections without issuing a receipt.
                do { try NativeRelayHostStore().save(value) }
                catch {
                    configuration = value
                    publish(value)
                    identityAvailable = false
                    self.error = error.localizedDescription
                    stopRuntime()
                    scheduleIdentityRetry()
                    throw error
                }
                configuration = value
                publish(value)
                status = "管理电脑已撤销，正在同步签名回执"
                await closeSession()
            }
        }
        guard generation == current, let denied = configuration else { throw CancellationError() }
        for pending in denied.revocations where !pending.completed {
            let client = try EnrollmentHostRevocationClient(privateKey: denied.privateKey,
                relayOrigin: pending.authorization.relayOrigin)
            guard generation == current, var value = configuration,
                  let index = value.revocations.firstIndex(where: { $0.request == pending.request }) else { throw CancellationError() }
            let receipt: EnrollmentRevocationReceipt
            if let saved = value.revocations[index].receipt { receipt = saved }
            else {
                receipt = try await client.prepareReceipt(for: pending.request, authorization: pending.authorization)
                guard generation == current, let latest = configuration,
                      latest.revocations.contains(where: { $0.request == pending.request }) else { throw CancellationError() }
                value = latest
                guard let latestIndex = value.revocations.firstIndex(where: { $0.request == pending.request }) else { throw CancellationError() }
                value.revocations[latestIndex].receipt = receipt
                try NativeRelayHostStore().save(value)
                configuration = value
            }
            _ = try await client.complete(receipt, revocation: pending.request, authorization: pending.authorization)
            guard generation == current, var latest = configuration,
                  let latestIndex = latest.revocations.firstIndex(where: { $0.request == pending.request }) else { throw CancellationError() }
            latest.revocations[latestIndex].completed = true
            try NativeRelayHostStore().save(latest)
            configuration = latest
            if latest.trust == nil { status = "管理电脑已撤销，签名回执已同步；重新连接需要新的配对" }
        }
    }

    /// Drain the old channel before signing a receipt. Generation invalidation
    /// also prevents an in-flight TLS/grant handshake from creating a bridge.
    private func closeSession() async {
        sessionGeneration = UUID()
        let previousTask = sessionTask
        sessionTask = nil
        previousTask?.cancel()
        let previousBridge = bridge
        bridge = nil
        connectedController = nil
        await previousBridge?.close()
        await previousTask?.value
    }

    private func stopRuntime() {
        generation = UUID()
        sessionGeneration = UUID()
        loopTask?.cancel()
        loopTask = nil
        sessionTask?.cancel()
        sessionTask = nil
        let previous = bridge
        bridge = nil
        connectedController = nil
        Task { await previous?.close() }
    }

    private func scheduleIdentityRetry() {
        guard identityRetryTask == nil, sessionActive, !sleeping else { return }
        identityRetryTask = Task { [weak self] in
            var delay = 2
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(delay)) } catch { break }
                guard let self, self.sessionActive, !self.sleeping else { break }
                self.reload(allowAuthenticationUI: false)
                if self.identityAvailable { break }
                delay = min(delay * 2, 30)
            }
            self?.identityRetryTask = nil
        }
    }

    private func observeLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.sleeping = false
                    self.sessionActive = CompanionPermissions.hasUserDesktopSession
                    if self.configuration == nil || !self.identityAvailable { self.reload(allowAuthenticationUI: false) }
                    else { self.resumeIfNeeded() }
                }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let sleeping = note.name == NSWorkspace.willSleepNotification
                Task { @MainActor in
                    guard let self else { return }
                    self.sleeping = sleeping
                    self.sessionActive = false
                    self.stopRuntime()
                    self.identityRetryTask?.cancel()
                    self.identityRetryTask = nil
                    self.status = "正在等待此 Mac 的桌面用户会话"
                }
            })
        }
    }
}
