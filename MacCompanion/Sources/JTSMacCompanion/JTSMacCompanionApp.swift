import AppKit
import SwiftUI

struct JTSMacCompanionApp: App {
    @StateObject private var server = CompanionServer()
    @StateObject private var nativeServer = NativeRelayHostRuntime()
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("JTS Mac Companion", id: "companion") {
            CompanionView(server: server, nativeServer: nativeServer)
                .onAppear { appDelegate.server = server; appDelegate.nativeServer = nativeServer }
        }
        .defaultSize(width: 640, height: 640)
        .windowResizability(.contentMinSize)
        MenuBarExtra("JTS Mac Companion", systemImage: server.connectedClientName == nil && nativeServer.connectedController == nil ? "desktopcomputer" : "desktopcomputer.badge.checkmark") {
            CompanionMenu(server: server, nativeServer: nativeServer)
        }
    }
}

@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    weak var server: CompanionServer?
    weak var nativeServer: NativeRelayHostRuntime?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { server?.shutdown(); nativeServer?.shutdown() }
}

private struct CompanionMenu: View {
    @ObservedObject var server: CompanionServer
    @ObservedObject var nativeServer: NativeRelayHostRuntime
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("内嵌桌面：\(server.status)")
        Text("系统共享：\(nativeServer.status)")
        Button("打开 JTS Mac Companion") {
            openWindow(id: "companion")
            NSApp.activate(ignoringOtherApps: true)
        }
        if nativeServer.trust != nil {
            Button(nativeServer.enabled ? "停止系统共享连接" : "恢复系统共享连接") { nativeServer.setEnabled(!nativeServer.enabled) }
        }
        if server.isSharing { Button("停止内嵌共享") { server.stop() } }
        else { Button("开始内嵌共享") { server.start() } }
        Divider()
        Button("退出") { NSApp.terminate(nil) }
    }
}

