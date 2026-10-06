import AppKit
import Combine
import Network
import RemoteDesktopCore

@MainActor
final class CompanionServer: ObservableObject {
    @Published var host: String { didSet { persistSettings() } }
    @Published var port: Int { didSet { persistSettings() } }
    @Published var allowRemoteControl: Bool {
        didSet {
            persistSettings()
            if !allowRemoteControl { input.releaseAll() }
            sendCapabilities()
        }
    }
    @Published private(set) var isSharing = false
    @Published private(set) var isStarting = false
    @Published private(set) var status = "尚未共享桌面"
    @Published private(set) var error: String?
    @Published private(set) var invitationCode = ""
    @Published private(set) var invitationExpiresAt: Date?
    @Published private(set) var clients: [AuthorizedDesktopClient] = []
    @Published private(set) var identityAvailable = false
    @Published private(set) var pendingClient: DesktopAuthentication?
    @Published private(set) var connectedClientName: String?
    @Published private(set) var screenPermission = CompanionPermissions.canCapture
    @Published private(set) var controlPermission = CompanionPermissions.canControl
    @Published private(set) var startsAtLogin = CompanionPermissions.startsAtLogin
    @Published private(set) var loginStatus = CompanionPermissions.loginStatus
    @Published private(set) var loginError: String?
    @Published private(set) var automaticSharing: Bool
    @Published private(set) var sharingPaused: Bool
    @Published private(set) var automaticSharingDetail = "完成首次授权和配对后，可启用自动共享。"

    private var identity: CompanionIdentity?
    private var invitation: DesktopPairingInvitation?
    private var listener: NWListener?
    private var channels: [UUID: DesktopChannel] = [:]
    private var lastActivity: [UUID: Date] = [:]
    private var pendingChannelID: UUID?
    private var activeChannelID: UUID?
    private var activeClientID: UUID?
    private var sendingFrame = false
    private var pendingDesktopFrame: DesktopFrame?
    private var desktopReady = false
    private var captureStopping = false
    private var captureGeneration = UUID()
    private var monitor: Timer?
    private let settingsStore: CompanionHostSettingsStore
    private var automaticPolicy = CompanionAutoSharePolicy()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var sessionIsActive = CompanionPermissions.hasUserDesktopSession
    private var isSleeping = false
    private var isShuttingDown = false
    private let capture = DesktopCapture()
    private let input = DesktopInputController()

    init(settingsStore: CompanionHostSettingsStore = CompanionHostSettingsStore()) {
        self.settingsStore = settingsStore
        let settings = settingsStore.load(availableAddresses: LocalDesktopAddresses.available())
        host = settings.host
        port = settings.port
        allowRemoteControl = settings.allowRemoteControl
        automaticSharing = settings.automaticSharing
        sharingPaused = settings.sharingPaused
        if sessionIsActive {
            do {
                identity = try CompanionIdentityStore.load()
                clients = identity?.clients ?? []
                identityAvailable = identity != nil
            } catch { self.error = error.localizedDescription; automaticPolicy.failed(at: Date()) }
        } else {
            error = "请在已登录的 Mac 桌面用户中打开程序；不要使用 sudo 运行共享程序。"
        }
        capture.onFrame = { [weak self] frame in self?.broadcast(frame) }
        capture.onFailure = { [weak self] message in
            self?.error = message
            self?.disconnectActive(reason: message, code: .captureFailed)
        }
        monitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        observeDesktopLifecycle()
        attemptAutomaticSharing()
    }

    func start() {
        sharingPaused = false
        persistSettings()
        automaticPolicy.reset()
        startSharing(createInvitation: clients.isEmpty)
    }

    private func startSharing(createInvitation: Bool) {
        guard !isSharing, !isStarting else { return }
        refreshPermissions()
        guard CompanionPermissions.hasUserDesktopSession, sessionIsActive, !isSleeping else {
            error = "请在已登录的 Mac 桌面用户中打开程序；不要使用 sudo 运行共享程序。"
            return
        }
        guard screenPermission else {
            error = "请先允许屏幕录制，再开始共享。系统要求重新打开程序时，请退出并重新打开。"
            return
        }
        guard (1024...65535).contains(port) else { error = "端口必须在 1024–65535 之间。"; return }
        isStarting = true
        error = nil
        do {
            if identity == nil {
                identity = try CompanionIdentityStore.load()
                clients = identity?.clients ?? []
                identityAvailable = identity != nil
            }
            if createInvitation { try makeInvitation() }
            guard createInvitation || !clients.isEmpty else {
                isStarting = false
                error = "请先在此 Mac 完成首次配对。"
                return
            }
            try rebuildListener()
            isSharing = true
            status = "正在等待客户端连接"
        } catch {
            self.error = error.localizedDescription
            invitation = nil
            invitationCode = ""
            invitationExpiresAt = nil
            listener?.cancel()
            listener = nil
        }
        isStarting = false
    }

    func stop() {
        sharingPaused = true
        persistSettings()
        stopSharing(reason: "远端 Mac 已停止共享。", code: .hostStopped)
        automaticSharingDetail = "自动共享已暂停；点击“开始共享”后恢复。"
    }

    func shutdown() {
        isShuttingDown = true
        monitor?.invalidate()
        monitor = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
        stopSharing()
    }

    private func stopSharing(reason: String = "远端 Mac 的桌面服务暂不可用。", code: DesktopSessionEndCode = .shutdown) {
        isSharing = false
        isStarting = false
        listener?.cancel()
        listener = nil
        invitation = nil
        invitationCode = ""
        invitationExpiresAt = nil
        pendingClient = nil
        pendingChannelID = nil
        captureGeneration = UUID()
        input.releaseAll()
        let connections = Array(channels.values)
        channels.removeAll()
        lastActivity.removeAll()
        activeChannelID = nil
        activeClientID = nil
        connectedClientName = nil
        sendingFrame = false
        pendingDesktopFrame = nil
        desktopReady = false
        for channel in connections {
            end(channel, reason: reason, code: code)
        }
        stopCapture()
        status = "桌面共享已停止"
    }

    func renewInvitation() {
        guard isSharing else { return }
        if let pendingChannelID { close(pendingChannelID, reason: "配对邀请已更新，请使用新邀请。", code: .rejected) }
        do { try makeInvitation(); try rebuildListener() }
        catch { self.error = error.localizedDescription; stopSharing(); automaticPolicy.failed(at: Date()) }
    }

    func approvePendingClient() {
        guard let authentication = pendingClient, let channelID = pendingChannelID,
              let invitation, invitation.expiresAt > Date(), var updated = identity else {
            rejectPendingClient()
            return
        }
        do {
            let token = try CompanionIdentity.newCredential()
            let psk = try CompanionIdentity.randomBytes()
            let client = AuthorizedDesktopClient(id: authentication.clientID, name: authentication.clientName,
                credentialHash: CompanionIdentity.hash(token), psk: psk, pairedAt: Date())
            updated.clients.removeAll { $0.id == client.id }
            updated.clients.append(client)
            // Commit authorization before acknowledging it. A Keychain failure grants no access.
            try CompanionIdentityStore.save(updated)
            identity = updated
            clients = updated.clients
            self.invitation = nil
            invitationCode = ""
            invitationExpiresAt = nil
            pendingClient = nil
            pendingChannelID = nil
            try rebuildListener()
            channels[channelID]?.send(.pairingApproved(DesktopPairingApproval(
                hostName: hostName, token: token, psk: psk)))
            beginDesktop(channelID: channelID, client: client)
        } catch {
            self.error = error.localizedDescription
            close(channelID, reason: "无法保存配对授权，请重试。", code: .rejected)
        }
    }

    func rejectPendingClient() {
        guard let pendingChannelID else { return }
        close(pendingChannelID, reason: "远端 Mac 拒绝了配对。", code: .rejected)
    }

    func revoke(_ client: AuthorizedDesktopClient) {
        guard var updated = identity else { return }
        updated.clients.removeAll { $0.id == client.id }
        do {
            try CompanionIdentityStore.save(updated)
            identity = updated
            clients = updated.clients
            if activeClientID == client.id { disconnectActive(reason: "此客户端的授权已被撤销。", code: .revoked) }
            if clients.isEmpty {
                automaticSharing = false
                persistSettings()
                automaticSharingDetail = "已撤销所有电脑；重新配对后才能启用自动共享。"
                if invitation == nil { stopSharing(reason: "已撤销所有电脑。", code: .revoked) }
            }
            if isSharing { try rebuildListener() }
        } catch { self.error = error.localizedDescription; stopSharing(); automaticPolicy.failed(at: Date()) }
    }

    func disconnectActive(reason: String = "远端 Mac 已断开桌面。", code: DesktopSessionEndCode = .hostStopped) {
        if let activeChannelID { close(activeChannelID, reason: reason, code: code) }
    }

    func reloadIdentity() {
        do {
            identity = try CompanionIdentityStore.load(allowAuthenticationUI: true)
            clients = identity?.clients ?? []
            identityAvailable = identity != nil
            error = nil
            automaticPolicy.reset()
            attemptAutomaticSharing()
        } catch { self.error = error.localizedDescription }
    }

    func setStartsAtLogin(_ enabled: Bool) {
        do {
            try CompanionPermissions.setStartsAtLogin(enabled)
            loginError = nil
        } catch { loginError = "无法更新登录项：\(error.localizedDescription)" }
        loginStatus = CompanionPermissions.loginStatus
        startsAtLogin = loginStatus == .enabled
    }

    var canEnableAutomaticSharing: Bool { screenPermission && !clients.isEmpty }

    /// Called only from a visible, explicit confirmation in the host UI.
    func enableAutomaticSharing() {
        refreshPermissions()
        guard canEnableAutomaticSharing else {
            error = "请先允许屏幕录制并确认第一台电脑的配对。"
            return
        }
        automaticSharing = true
        sharingPaused = false
        persistSettings()
        setStartsAtLogin(true)
        automaticPolicy.reset()
        attemptAutomaticSharing()
    }

    func disableAutomaticSharing() {
        automaticSharing = false
        persistSettings()
        automaticPolicy.reset()
        automaticSharingDetail = "自动共享已关闭；可以手动开始共享。"
    }

    func refreshPermissions() {
        let wasControllable = controlPermission
        screenPermission = CompanionPermissions.canCapture
        controlPermission = CompanionPermissions.canControl
        loginStatus = CompanionPermissions.loginStatus
        startsAtLogin = loginStatus == .enabled
        if wasControllable != controlPermission {
            input.releaseAll()
            sendCapabilities()
        }
    }

    private var hostName: String { Host.current().localizedName ?? "Mac" }

    private func makeInvitation() throws {
        guard let identity, let selectedPort = UInt16(exactly: port) else { return }
        let invitation = DesktopPairingInvitation(serverID: identity.serverID, host: host,
            port: selectedPort, psk: try CompanionIdentity.randomBytes(),
            invitationToken: try CompanionIdentity.newCredential(), expiresAt: Date().addingTimeInterval(300))
        invitationCode = try invitation.encodedCode()
        invitationExpiresAt = invitation.expiresAt
        self.invitation = invitation
    }

    private func rebuildListener() throws {
        var keys = (identity?.clients ?? []).map { DesktopPreSharedKey(identity: $0.id.uuidString, key: $0.psk) }
        if let invitation, invitation.expiresAt > Date() {
            keys.append(DesktopPreSharedKey(identity: DesktopProtocol.invitationIdentity, key: invitation.psk))
        }
        listener?.cancel()
        listener = nil
        guard !keys.isEmpty else { return }
        guard let port = NWEndpoint.Port(rawValue: UInt16(self.port)) else { return }
        let listener = try NWListener(using: DesktopTLS.parameters(preSharedKeys: keys), on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    self.automaticPolicy.reset()
                case .failed(let error):
                    self.error = "桌面服务无法监听：\(error.localizedDescription)"
                    self.stopSharing()
                    self.automaticPolicy.failed(at: Date())
                default: break
                }
            }
        }
        listener.start(queue: .main)
    }

    private func accept(_ connection: NWConnection) {
        guard isSharing, channels.count < 4 else { connection.cancel(); return }
        let id = UUID()
        let channel = DesktopChannel(connection: connection)
        channels[id] = channel
        lastActivity[id] = Date()
        channel.onStateChange = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready: self.channels[id]?.send(.hello(DesktopHello(hostName: self.hostName)))
                case .failed, .cancelled: self.remove(id)
                default: break
                }
            }
        }
        channel.onMessage = { [weak self] message in
            MainActor.assumeIsolated { self?.receive(message, from: id) }
        }
        channel.start(queue: .main)
    }

    private func receive(_ message: RemoteDesktopMessage, from id: UUID) {
        guard channels[id] != nil else { return }
        if id == activeChannelID { lastActivity[id] = Date() }
        switch message {
        case .authenticate(let authentication): authenticate(authentication, channelID: id)
        case .ping(let sequence): channels[id]?.send(.pong(sequence))
        case .input(let event):
            guard id == activeChannelID, allowRemoteControl, CompanionPermissions.canControl else { return }
            do { try input.handle(event) }
            catch { self.error = error.localizedDescription; input.releaseAll(); sendCapabilities() }
        case .goodbye: remove(id)
        default: close(id, reason: "收到不支持的桌面消息。", code: .protocolViolation)
        }
    }

    private func authenticate(_ auth: DesktopAuthentication, channelID: UUID) {
        guard !captureStopping, activeChannelID == nil, pendingChannelID == nil else {
            close(channelID, reason: "这台 Mac 已有桌面连接或正在确认配对。", code: .busy)
            return
        }
        if let token = auth.token, let client = identity?.authorizedClient(deviceID: auth.clientID, credential: token) {
            beginDesktop(channelID: channelID, client: client)
            return
        }
        if let supplied = auth.invitationToken, let invitation,
           invitation.expiresAt > Date(), DesktopSecret.matches(supplied, invitation.invitationToken) {
            guard (identity?.clients.count ?? 0) < 64 else {
                close(channelID, reason: "授权设备已满，请先撤销不再使用的电脑。", code: .rejected)
                return
            }
            pendingClient = auth
            pendingChannelID = channelID
            lastActivity[channelID] = Date()
            channels[channelID]?.send(.pairingPending)
            status = "请确认是否允许 \(auth.clientName) 连接"
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        close(channelID, reason: "配对邀请已失效或客户端未授权。", code: .invalidCredentials)
    }

    private func beginDesktop(channelID: UUID, client: AuthorizedDesktopClient) {
        activeChannelID = channelID
        activeClientID = client.id
        connectedClientName = client.name
        desktopReady = false
        pendingDesktopFrame = nil
        captureGeneration = UUID()
        let generation = captureGeneration
        status = "正在启动屏幕共享"
        Task {
            guard captureGeneration == generation, activeChannelID == channelID, isSharing, !captureStopping else { return }
            do {
                try await capture.start()
                // Cancellation already schedules cleanup; an old task must never stop a newer stream.
                guard captureGeneration == generation, activeChannelID == channelID, isSharing else { return }
                input.displayBounds = capture.displayBounds
                desktopReady = true
                sendCapabilities()
                flushPendingFrame()
                status = "正在向 \(client.name) 共享桌面"
            } catch {
                guard captureGeneration == generation else { return }
                self.error = "屏幕共享失败：\(error.localizedDescription)"
                close(channelID, reason: self.error ?? "屏幕共享失败。", code: .captureFailed)
            }
        }
    }

    private func sendCapabilities() {
        guard desktopReady, let id = activeChannelID else { return }
        let bounds = capture.displayBounds
        channels[id]?.send(.ready(DesktopSessionInfo(hostName: hostName,
            width: max(1, Int(bounds.width)), height: max(1, Int(bounds.height)),
            canControl: allowRemoteControl && CompanionPermissions.canControl)))
    }

    private func broadcast(_ frame: DesktopFrame) {
        guard isSharing, let id = activeChannelID, let channel = channels[id] else { return }
        guard desktopReady, !sendingFrame else { pendingDesktopFrame = frame; return }
        sendingFrame = true
        channel.send(.frame(frame)) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, self.activeChannelID == id else { return }
                self.sendingFrame = false
                if error != nil { self.remove(id) }
                else { self.flushPendingFrame() }
            }
        }
    }

    private func flushPendingFrame() {
        guard let frame = pendingDesktopFrame else { return }
        pendingDesktopFrame = nil
        broadcast(frame)
    }

    private func close(_ id: UUID, reason: String, code: DesktopSessionEndCode) {
        let channel = channels[id]
        remove(id, cancel: false)
        if let channel { end(channel, reason: reason, code: code) }
    }

    private func end(_ channel: DesktopChannel, reason: String, code: DesktopSessionEndCode) {
        channel.send(.sessionEnded(DesktopSessionEnd(code: code, message: reason))) { _ in channel.cancel() }
        // A stalled peer cannot retain a connection while a final send waits.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { channel.cancel() }
    }

    private func remove(_ id: UUID, cancel: Bool = true) {
        if cancel { channels[id]?.cancel() }
        channels.removeValue(forKey: id)
        lastActivity.removeValue(forKey: id)
        if id == pendingChannelID { pendingClient = nil; pendingChannelID = nil }
        if id == activeChannelID {
            activeChannelID = nil
            activeClientID = nil
            connectedClientName = nil
            sendingFrame = false
            pendingDesktopFrame = nil
            desktopReady = false
            captureGeneration = UUID()
            input.releaseAll()
            stopCapture()
        }
        if isSharing { status = "正在等待客户端连接" }
    }

    private func tick() {
        refreshPermissions()
        if !screenPermission, isSharing {
            disconnectActive(reason: "屏幕录制权限已被撤销。", code: .permissionRequired)
            stopSharing(reason: "屏幕录制权限已被撤销。", code: .permissionRequired)
        }
        attemptAutomaticSharing()
        if let invitation, invitation.expiresAt <= Date() {
            self.invitation = nil
            invitationCode = ""
            invitationExpiresAt = nil
            if let pendingChannelID { close(pendingChannelID, reason: "配对邀请已过期。", code: .invalidCredentials) }
            do { try rebuildListener() } catch { self.error = error.localizedDescription; stopSharing(); automaticPolicy.failed(at: Date()) }
        }
        for (id, date) in Array(lastActivity) {
            let timeout: TimeInterval = id == pendingChannelID ? 90 : (id == activeChannelID ? 45 : 15)
            if Date().timeIntervalSince(date) > timeout { close(id, reason: "连接超时，请重新连接。", code: .idleTimeout) }
        }
    }

    private var hostSettings: CompanionHostSettings {
        CompanionHostSettings(host: host, port: port, allowRemoteControl: allowRemoteControl,
            automaticSharing: automaticSharing, sharingPaused: sharingPaused)
    }

    private func persistSettings() { settingsStore.save(hostSettings) }

    private func attemptAutomaticSharing() {
        guard !isShuttingDown else { return }
        if identity == nil, sessionIsActive, !isSleeping,
           automaticPolicy.nextAttempt.map({ $0 <= Date() }) ?? true {
            do {
                identity = try CompanionIdentityStore.load()
                clients = identity?.clients ?? []
                identityAvailable = identity != nil
                error = nil
                automaticPolicy.reset()
            } catch {
                self.error = error.localizedDescription
                automaticPolicy.failed(at: Date())
            }
        }
        if identity == nil {
            automaticSharingDetail = "无法读取设备身份；正在自动重试，也可以打开程序重新读取配对信息。"
            return
        }
        let decision = automaticPolicy.decision(settings: hostSettings, canCapture: screenPermission,
            hasPairedClient: !clients.isEmpty, hasUserSession: sessionIsActive && !isSleeping,
            isSharing: isSharing || isStarting, now: Date())
        switch decision {
        case .disabled: automaticSharingDetail = "自动共享已关闭；可以手动开始共享。"
        case .paused: automaticSharingDetail = "自动共享已暂停；点击“开始共享”后恢复。"
        case .userSessionRequired: automaticSharingDetail = "正在等待此 Mac 的用户桌面会话。"
        case .screenPermissionRequired: automaticSharingDetail = "正在等待屏幕录制权限；请从本窗口前往系统设置授权。"
        case .pairingRequired: automaticSharingDetail = "请先手动开始共享并确认第一台电脑的配对。"
        case .alreadySharing: automaticSharingDetail = "打开程序、唤醒或权限恢复后自动接受已授权电脑的连接。"
        case .waitingForRetry: automaticSharingDetail = "桌面服务暂不可用，正在自动重试。"
        case .startAuthorizedDevices:
            startSharing(createInvitation: false)
            if !isSharing { automaticPolicy.failed(at: Date()) }
        }
    }

    private func observeDesktopLifecycle() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.isSleeping = false
                    self.sessionIsActive = CompanionPermissions.hasUserDesktopSession
                    self.refreshPermissions()
                    self.automaticPolicy.reset()
                    self.attemptAutomaticSharing()
                }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let sleeping = note.name == NSWorkspace.willSleepNotification
                Task { @MainActor in
                    guard let self else { return }
                    self.isSleeping = sleeping
                    self.sessionIsActive = false
                    self.disconnectActive(reason: sleeping ? "此 Mac 正在休眠。" : "此 Mac 的桌面会话暂不可用。", code: .shutdown)
                    self.stopSharing()
                }
            })
        }
    }

    private func stopCapture() {
        guard !captureStopping else { return }
        captureStopping = true
        Task {
            await capture.stop()
            captureStopping = false
        }
    }
}
