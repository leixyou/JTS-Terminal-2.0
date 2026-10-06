#if ENABLE_RDP_2
import AppKit
import Combine
import Foundation
import Network
import RemoteDesktopCore
import SwiftData

@MainActor
final class MacDesktopWorkspaceStore: ObservableObject {
    private var workspaces: [PersistentIdentifier: MacDesktopWorkspaceState] = [:]
    private let makeWorkspace: () -> MacDesktopWorkspaceState

    init(makeWorkspace: (() -> MacDesktopWorkspaceState)? = nil) {
        self.makeWorkspace = makeWorkspace ?? { MacDesktopWorkspaceState() }
    }

    func workspace(for sessionID: PersistentIdentifier) -> MacDesktopWorkspaceState {
        if let existing = workspaces[sessionID] { return existing }
        let workspace = makeWorkspace()
        workspaces[sessionID] = workspace
        return workspace
    }

    func disconnectAll() {
        workspaces.values.forEach { $0.disconnect() }
    }

    func remove(for sessionID: PersistentIdentifier) {
        workspaces.removeValue(forKey: sessionID)?.retire()
    }
}

@MainActor
final class MacDesktopWorkspaceState: ObservableObject {
    enum Status: Equatable {
        case disconnected, connecting, authenticating, awaitingApproval, connected, reconnecting, failed

        var title: String {
            switch self {
            case .disconnected: return "未连接"
            case .connecting: return "正在连接 Mac"
            case .authenticating: return "正在验证配对"
            case .awaitingApproval: return "等待对方 Mac 批准"
            case .connected: return "已连接"
            case .reconnecting: return "等待自动重连"
            case .failed: return "连接失败"
            }
        }
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var errorMessage: String?
    @Published private(set) var notice: String?
    @Published private(set) var hostName = "Mac 桌面"
    @Published private(set) var image: NSImage?
    @Published private(set) var frameSize = CGSize.zero
    @Published private(set) var canControl = false
    @Published private(set) var hasSavedPairing = false
    @Published private(set) var isReceivingFrames = false
    @Published private(set) var autoReconnect = true
    @Published var controlsEnabled = true
    @Published var invitationCode = ""

    private var channel: (any MacDesktopTransport)?
    private let dependencies: MacDesktopClientDependencies
    private var retryTask: Task<Void, Never>?
    private var reconnectPolicy = MacDesktopReconnectPolicy()
    private var desiredConnection: Connection?
    private var retired = false

    private struct Connection {
        var host: String
        var port: Int
        var name: String
        var pairing: MacDesktopStoredPairing
    }
    // Codecs stay off the UI thread; ordered callbacks stay on MainActor.
    private let queue = DispatchQueue.main
    private var generation = UUID()
    private var timeoutTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var endpoint: (host: String, port: Int)?
    private var pendingPairing: MacDesktopStoredPairing?
    private var authenticated = false
    private var receivedHello = false
    private var usesInvitation = false
    private var decodingFrame = false
    private var pendingFrame: RemoteDesktopCore.DesktopFrame?
    private var lastReceivedAt = Date()

    init(dependencies: MacDesktopClientDependencies) {
        self.dependencies = dependencies
    }

    convenience init() { self.init(dependencies: MacDesktopClientDependencies()) }

    deinit {
        retryTask?.cancel()
        timeoutTask?.cancel()
        heartbeatTask?.cancel()
    }

    var isBusy: Bool { [.connecting, .authenticating, .awaitingApproval, .reconnecting].contains(status) }
    var isConnected: Bool { status == .connected }
    var acceptsInput: Bool { isConnected && canControl && controlsEnabled && isReceivingFrames }

    func prepare(for session: RemoteSession) {
        guard !retired else { return }
        guard endpoint?.host != session.host || endpoint?.port != session.port else { return }
        disconnect()
        errorMessage = nil
        notice = nil
        endpoint = (session.host, session.port)
        hostName = session.name
        do {
            let pairing = try dependencies.readPairing(session.host, session.port)
            hasSavedPairing = pairing != nil
            autoReconnect = pairing?.autoReconnect ?? true
            if let pairing, autoReconnect, session.isConnectable {
                let connection = Connection(host: session.host, port: session.port, name: session.name, pairing: pairing)
                desiredConnection = connection
                start(connection)
            }
        } catch {
            hasSavedPairing = false
            errorMessage = "无法读取 加密凭据库中的配对：\(error.localizedDescription)"
        }
    }

    func connect(session: RemoteSession, persistEndpoint: (() throws -> Void)? = nil) {
        guard !retired, !isBusy else { return }
        disconnect()
        errorMessage = nil
        notice = nil
        do {
            let pairing: MacDesktopStoredPairing
            let code = invitationCode.trimmingCharacters(in: .whitespacesAndNewlines)
            var invitationToken: String?
            if !code.isEmpty {
                let invitation = try DesktopPairingInvitation(code: code)
                guard invitation.expiresAt > dependencies.now() else {
                    throw MacDesktopClientError.message("配对邀请已过期，请在对方 Mac 重新生成。")
                }
                // Freeze the endpoint before model observers can prepare the updated profile.
                endpoint = (invitation.host, Int(invitation.port))
                session.host = invitation.host
                session.port = Int(invitation.port)
                session.updatedAt = dependencies.now()
                try persistEndpoint?()
                pairing = MacDesktopStoredPairing(
                    serverID: invitation.serverID,
                    psk: invitation.psk,
                    clientID: UUID(),
                    clientName: Host.current().localizedName ?? "JTS Terminal",
                    token: "",
                    autoReconnect: autoReconnect
                )
                invitationToken = invitation.invitationToken
                hasSavedPairing = false
            } else {
                guard session.isConnectable,
                      let stored = try dependencies.readPairing(session.host, session.port) else {
                    throw MacDesktopClientError.message("请粘贴对方 Mac Companion 生成的配对邀请。")
                }
                pairing = stored
                autoReconnect = stored.autoReconnect
                hasSavedPairing = true
            }
            guard (1...65535).contains(session.port) else { throw MacDesktopClientError.message("Mac 桌面端口必须为 1–65535。") }
            let connection = Connection(host: session.host, port: session.port, name: session.name, pairing: pairing)
            // An invitation is single use and must never enter the retry path.
            if invitationToken == nil { desiredConnection = connection }
            start(connection, invitationToken: invitationToken)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func start(_ connection: Connection, invitationToken: String? = nil) {
        guard !retired else { return }
        tearDownConnection()
        notice = nil
        let currentGeneration = generation
        endpoint = (connection.host, connection.port)
        pendingPairing = connection.pairing
        usesInvitation = invitationToken != nil
        authenticated = false
        receivedHello = false
        hostName = connection.name
        status = .connecting
        lastReceivedAt = dependencies.now()
        let pairing = connection.pairing
        let authentication = DesktopAuthentication(clientID: pairing.clientID, clientName: pairing.clientName,
                                                   invitationToken: invitationToken, token: invitationToken == nil ? pairing.token : nil)
        do {
            let channel = try dependencies.makeTransport(connection.host, UInt16(connection.port), pairing.psk,
                                                         invitationToken == nil ? pairing.clientID.uuidString : DesktopProtocol.invitationIdentity)
            self.channel = channel
            channel.onStateChange = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.generation == currentGeneration else { return }
                    switch state {
                    case .ready:
                        guard !self.authenticated else { return }
                        self.authenticated = true
                        self.status = .authenticating
                        self.transmit(.authenticate(authentication))
                    case .failed(let error): self.transportFailed(error, prefix: "连接失败")
                    case .cancelled: self.fail("与对方 Mac 的连接已中断。", retry: .network)
                    default: break
                    }
                }
            }
            channel.onMessage = { [weak self] message in
                MainActor.assumeIsolated {
                    guard let self, self.generation == currentGeneration else { return }
                    self.receive(message)
                }
            }
            channel.onError = { [weak self] error in
                MainActor.assumeIsolated {
                    guard let self, self.generation == currentGeneration else { return }
                    self.transportFailed(error, prefix: "桌面连接中断")
                }
            }
            channel.start(queue: queue)
            let sleep = dependencies.sleep
            timeoutTask = Task { [weak self] in
                do { try await sleep(invitationToken == nil ? 30 : 120) } catch { return }
                guard !Task.isCancelled, let self, !self.retired, self.generation == currentGeneration, !self.isConnected else { return }
                self.fail("连接或批准等待超时。请检查两台 Mac 的网络，并在对方 Mac 确认请求。", retry: invitationToken == nil ? .network : nil)
            }
        } catch {
            transportFailed(error, prefix: "连接失败")
        }
    }

    func disconnect() {
        retryTask?.cancel()
        retryTask = nil
        desiredConnection = nil
        reconnectPolicy.reset()
        tearDownConnection()
        status = .disconnected
        notice = nil
    }

    /// Store removal permanently invalidates references retained by a view or queued action.
    /// A later profile with the same key must obtain a fresh, store-owned workspace.
    func retire() {
        retired = true
        disconnect()
    }

    func setAutoReconnect(_ enabled: Bool) {
        guard !retired, autoReconnect != enabled else { return }
        do {
            if let endpoint, var pairing = try dependencies.readPairing(endpoint.host, endpoint.port) {
                pairing.autoReconnect = enabled
                try dependencies.savePairing(pairing, endpoint.host, endpoint.port)
                desiredConnection?.pairing.autoReconnect = enabled
            }
            autoReconnect = enabled
            pendingPairing?.autoReconnect = enabled
            if !enabled, retryTask != nil {
                disconnect()
                notice = "已停止自动重连。"
            }
        } catch {
            errorMessage = "无法保存自动重连设置：\(error.localizedDescription)"
        }
    }

    private func tearDownConnection() {
        if isConnected { channel?.send(.input(.releaseAll), completion: nil) }
        generation = UUID()
        channel?.cancel()
        channel = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        pendingPairing = nil
        authenticated = false
        receivedHello = false
        usesInvitation = false
        decodingFrame = false
        pendingFrame = nil
        image = nil
        frameSize = .zero
        canControl = false
        isReceivingFrames = false
    }

    func send(_ input: DesktopInput) {
        guard acceptsInput else { return }
        transmit(.input(input))
    }

    func releaseInput() {
        guard isConnected else { return }
        transmit(.input(.releaseAll))
    }

    func forgetPairing(session: RemoteSession) {
        guard !retired else { return }
        disconnect()
        do {
            try dependencies.deletePairing(session.host, session.port)
            hasSavedPairing = false
            notice = "已从此 Mac 的 加密凭据库移除配对。重新连接需要对方生成邀请并批准。"
        } catch {
            errorMessage = "移除配对失败：\(error.localizedDescription)"
        }
    }

    func receive(_ message: RemoteDesktopMessage) {
        guard !retired else { return }
        lastReceivedAt = dependencies.now()
        switch message {
        case .hello(let hello):
            guard !receivedHello, [.connecting, .authenticating].contains(status), hello.protocolVersion == DesktopProtocol.version else {
                fail("两台 Mac 的桌面协议版本或连接状态不同，请更新程序后重新连接。")
                return
            }
            receivedHello = true
            hostName = hello.hostName
        case .pairingPending:
            guard receivedHello, authenticated, usesInvitation, status == .authenticating else { fail("对方 Mac 的配对状态无效。") ; return }
            status = .awaitingApproval
        case .pairingApproved(let approval):
            guard receivedHello, authenticated, usesInvitation, status == .awaitingApproval,
                  var pairing = pendingPairing, let endpoint, !approval.token.isEmpty else { fail("配对批准状态无效或缺少凭证。") ; return }
            pairing.token = approval.token
            pairing.psk = approval.psk
            status = .authenticating
            pendingPairing = pairing
            do {
                try dependencies.savePairing(pairing, endpoint.host, endpoint.port)
                desiredConnection = Connection(host: endpoint.host, port: endpoint.port, name: approval.hostName, pairing: pairing)
                hasSavedPairing = true
                invitationCode = ""
                hostName = approval.hostName
            } catch {
                notice = "当前连接可用，但 加密凭据库保存失败；下次连接需要重新配对。"
            }
        case .ready(let info):
            guard receivedHello, authenticated, [.authenticating, .connected].contains(status),
                  pendingPairing?.token.isEmpty == false else { fail("对方 Mac 尚未完成设备授权。") ; return }
            hostName = info.hostName
            canControl = info.canControl
            frameSize = CGSize(width: info.width, height: info.height)
            status = .connected
            errorMessage = nil
            reconnectPolicy.reset()
            timeoutTask?.cancel()
            startHeartbeat()
        case .frame(let frame):
            guard isConnected, receivedHello else { fail("对方 Mac 在授权前发送了桌面画面。") ; return }
            enqueueFrame(frame)
        case .error(let message): fail(message)
        case .sessionEnded(let end):
            let temporarilyUnavailable = [.busy, .captureFailed].contains(end.code)
            fail(end.message, retry: end.code.allowsReconnect ? (temporarilyUnavailable ? .temporarilyUnavailable : .network) : nil)
        case .goodbye(let message):
            disconnect()
            notice = message
        case .ping(let sequence): transmit(.pong(sequence))
        case .pong: break
        case .authenticate, .input: fail("对方发送了无效的桌面消息。")
        }
    }

    private func enqueueFrame(_ frame: RemoteDesktopCore.DesktopFrame) {
        guard !decodingFrame else {
            pendingFrame = frame
            return
        }
        decodingFrame = true
        let currentGeneration = generation
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try MacDesktopFrameDecoder.decode(frame) }
            }.value
            guard let self, !self.retired, self.generation == currentGeneration, self.isConnected else { return }
            self.decodingFrame = false
            switch result {
            case .success(let decoded):
                let size = CGSize(width: decoded.width, height: decoded.height)
                self.image = NSImage(cgImage: decoded.image, size: size)
                self.frameSize = size
                self.isReceivingFrames = true
            case .failure(let error): self.fail(error.localizedDescription); return
            }
            if let next = self.pendingFrame {
                self.pendingFrame = nil
                self.enqueueFrame(next)
            }
        }
    }

    private func startHeartbeat() {
        guard !retired, heartbeatTask == nil else { return }
        let sleep = dependencies.sleep
        heartbeatTask = Task { [weak self] in
            var sequence: UInt64 = 0
            while !Task.isCancelled {
                do { try await sleep(10) } catch { return }
                guard !Task.isCancelled, let self, !self.retired, self.isConnected else { return }
                guard self.dependencies.now().timeIntervalSince(self.lastReceivedAt) < 35 else {
                    self.fail("与对方 Mac 的心跳连接已中断。", retry: .network)
                    return
                }
                sequence &+= 1
                self.transmit(.ping(sequence))
            }
        }
    }

    private func transmit(_ message: RemoteDesktopMessage) {
        let currentGeneration = generation
        channel?.send(message) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.generation == currentGeneration else { return }
                self.transportFailed(error, prefix: "桌面数据发送失败")
            }
        }
    }

    private func transportFailed(_ error: Error, prefix: String) {
        fail("\(prefix)：\(error.localizedDescription)", retry: MacDesktopReconnectPolicy.cause(for: error))
    }

    private func fail(_ message: String, retry cause: MacDesktopReconnectPolicy.Cause? = nil) {
        guard !retired else { return }
        // Invalidate all callbacks before cancellation can produce a second failure.
        tearDownConnection()
        errorMessage = message
        notice = nil
        guard let cause, autoReconnect, let connection = desiredConnection,
              !connection.pairing.token.isEmpty,
              let delay = reconnectPolicy.nextDelay(cause: cause, now: dependencies.now()) else {
            retryTask?.cancel()
            retryTask = nil
            desiredConnection = nil
            status = .failed
            return
        }
        retryTask?.cancel()
        status = .reconnecting
        notice = "\(Int(delay)) 秒后自动重连（第 \(reconnectPolicy.attempt) 次）；可点击取消停止。"
        let currentGeneration = generation
        let sleep = dependencies.sleep
        retryTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self, !self.retired, self.generation == currentGeneration,
                  self.autoReconnect, self.desiredConnection != nil else { return }
            self.retryTask = nil
            self.start(connection)
        }
    }

}

private enum MacDesktopClientError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message } ; return nil }
}

#endif
