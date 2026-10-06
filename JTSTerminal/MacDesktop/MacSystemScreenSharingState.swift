#if ENABLE_RDP_2
import AppKit
import Combine
import Foundation
import JTSCompanionIPC
import JTSCompanionDevices
import JTSCompanionClient

@MainActor
final class MacSystemScreenSharingStore {
    static let shared = MacSystemScreenSharingStore()
    private var states: [UUID: MacSystemScreenSharingState] = [:]
    func state(for targetID: UUID) -> MacSystemScreenSharingState {
        if let state = states[targetID] { return state }
        let state = MacSystemScreenSharingState(targetID: targetID)
        states[targetID] = state
        return state
    }
    func remove(targetID: UUID) { states.removeValue(forKey: targetID)?.retire() }
    func disconnectAll() { states.values.forEach { $0.stop() } }
}

/// App lifetime owns the bridge; leaving the panel cannot terminate the viewer.
@MainActor
final class MacSystemScreenSharingState: ObservableObject {
    @Published private(set) var status = "尚未连接"
    @Published private(set) var active = false
    @Published var autoReconnect: Bool { didSet { UserDefaults.standard.set(autoReconnect, forKey: preferenceKey) } }
    private let targetID: UUID
    private var preferenceKey: String { "jts.mac-screen-sharing.autoreconnect.\(targetID.uuidString)" }
    private var bridge: NativeScreenSharingLoopbackBridge?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var observation: AnyCancellable?
    private var trustObservers: [NSObjectProtocol] = []
    private var retired = false

    init(targetID: UUID) {
        self.targetID = targetID
        self.autoReconnect = UserDefaults.standard.bool(forKey: "jts.mac-screen-sharing.autoreconnect.\(targetID.uuidString)")
    }

    func connect(targetBinding: String, authorize: @escaping @MainActor @Sendable () throws -> Void) {
        guard !retired else { return }
        stop()
        generation = UUID()
        let token = generation
        active = true
        // Register before the route lookup can suspend and return a stale snapshot.
        watchTrust(deviceID: nil)
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == token {
                    bridge?.stop(); bridge = nil; observation = nil
                    clearTrustObservers(); active = false; task = nil
                }
            }
            var failures = 0
            while !Task.isCancelled, generation == token {
                guard failures == 0 || autoReconnect else { break }
                do {
                    status = failures == 0 ? "正在连接加密中继…" : "正在重连…"
                    guard let route = try await CompanionTargetRouteStore.shared.binding(targetID: targetID, targetBinding: targetBinding),
                          let grantID = route.rdpGrantID else { throw CompanionTargetRouteError.invalid }
                    guard generation == token, !Task.isCancelled else { return }
                    try authorize()
                    watchTrust(deviceID: route.deviceID)
                    let config = try await CompanionDevicesModel.shared.relayConfiguration(deviceID: route.deviceID, grantID: grantID)
                    try authorize()
                    guard generation == token, !Task.isCancelled else { return }
                    let next = try await NativeScreenSharingLoopbackBridge.open(configuration: config, grantID: grantID)
                    do { try authorize() } catch { next.stop(); throw error }
                    guard generation == token, !Task.isCancelled else { next.stop(); return }
                    bridge = next
                    next.watchTrust(targetID: targetID, deviceID: route.deviceID)
                    observation = next.$phase.sink { [weak self] phase in
                        switch phase {
                        case .opening: self?.status = "正在建立通道…"
                        case .waitingForViewer: self?.status = "等待系统屏幕共享连接"
                        case .connected: self?.status = "系统屏幕共享已连接"
                        case .stopped: self?.status = "连接已结束"
                        case .failed: self?.status = "通道中断"
                        }
                    }
                    guard let url = next.viewerURL, NSWorkspace.shared.open(url) else {
                        next.stop(); throw CompanionTargetRouteError.invalid
                    }
                    while !Task.isCancelled, generation == token,
                          next.phase != .failed, next.phase != .stopped {
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    let endedByTrustChange = next.phase == .stopped
                    let viewerEnded = next.error == .viewerDisconnected || next.error == .viewerTimedOut
                    let retryableEnd = next.error.map(Self.canRetry) ?? false
                    next.stop(); bridge = nil; observation = nil
                    guard !endedByTrustChange, !viewerEnded, retryableEnd, autoReconnect, generation == token else { break }
                } catch {
                    guard !Task.isCancelled, generation == token else { return }
                    status = "无法连接，请检查配对、网络和被控 Mac 的系统屏幕共享设置。"
                    guard Self.canRetry(error), autoReconnect else { break }
                }
                failures += 1
                do { try await Task.sleep(for: .seconds(min(30, pow(2, Double(min(failures - 1, 5)))))) }
                catch { return }
            }

        }
    }

    private func watchTrust(deviceID: UUID?) {
        clearTrustObservers()
        var watched = [(Notification.Name.jtsCompanionTargetRouteChanged, targetID)]
        if let deviceID { watched.append((.jtsCompanionDeviceTrustChanged, deviceID)) }
        for (name, expected) in watched {
            trustObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard notification.object as? UUID == expected else { return }
                MainActor.assumeIsolated { self?.stop() }
            })
        }
    }
    private func clearTrustObservers() {
        trustObservers.forEach { NotificationCenter.default.removeObserver($0) }
        trustObservers.removeAll()
    }

    static func canRetry(_ error: Error) -> Bool {
        if error is CancellationError || error is CompanionDeviceError || error is CompanionTargetRouteError { return false }
        if let failure = error as? CompanionClientError {
            switch failure {
            case .remote(let code): return ["DEVICE_OFFLINE", "CHANNEL_CLOSED", "CONNECTION_UNAVAILABLE"].contains(code)
            case .notConnected, .timedOut, .interrupted, .unavailable: return true
            default: return false
            }
        }
        return error is URLError || (error as? NativeScreenSharingBridgeError) == .transportFailed
    }

    func stop() {
        generation = UUID(); task?.cancel(); task = nil
        clearTrustObservers()
        observation = nil; bridge?.stop(); bridge = nil
        active = false; status = "已断开"
    }

    /// A removed profile must not reconnect through a retained view or queued action.
    func retire() {
        retired = true
        stop()
    }
}
#endif
