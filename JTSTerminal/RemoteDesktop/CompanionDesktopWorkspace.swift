#if ENABLE_RDP_2
import AppKit
import SwiftUI
import JTSCompanionClient

struct CompanionDesktopWorkspace: View {
    let target: RemoteSession
    let toggleFullScreen: () -> Void
    @ObservedObject private var runtime = CompanionDesktopRuntime.shared
    @State private var fit = true
    @State private var error: String?
    @Environment(\.appLanguage) private var language
    private var session: CompanionDesktopSession? { runtime.sessions[target.targetID] }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(status, systemImage: session?.image == nil ? "desktopcomputer.trianglebadge.exclamationmark" : "desktopcomputer")
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let session {
                    Menu(language.localized("Session", "Windows 会话")) {
                        Button(language.localized("Refresh", "刷新会话")) { Task { await runtime.refreshSessions(session) } }
                        ForEach(Array(session.availableWindowsSessions.enumerated()), id: \.offset) { _, value in
                            if let id = value["sessionId"]?.integerValue {
                                Button("\(id) · \(value["state"]?.stringValue ?? "")") {
                                    Task { do { try await runtime.selectSession(Int(id), session: session) } catch { self.error = runtime.safeCode(error) } }
                                }
                            }
                        }
                    }
                    if let monitors = session.remoteState["monitors"]?.foundationValue as? [[String: Any]], monitors.count > 1 {
                        Menu(language.localized("Display", "显示器")) {
                            ForEach(Array(monitors.enumerated()), id: \.offset) { index, monitor in
                                if let id = monitor["id"] as? String {
                                    Button(language.localized("Display \(index + 1)", "显示器 \(index + 1)")) {
                                        Task { do { try await runtime.selectMonitor(id, session: session) } catch { self.error = runtime.safeCode(error) } }
                                    }
                                }
                            }
                        }
                    }
                }
                Button(language.localized("Connect", "连接")) {
                    Task { do { _ = try await runtime.open(target: target); error = nil } catch { self.error = runtime.safeCode(error) } }
                }.disabled(session != nil && session?.status != "disconnected")
                Toggle(language.localized("Fit", "适应窗口"), isOn: $fit).toggleStyle(.button)
                Button(language.localized("Full Screen", "全屏"), action: toggleFullScreen)
                Button(language.localized("Stop", "紧急停止")) { Task { await RDPDesktopRuntimeStore.shared.emergencyStop(targetID: target.targetID) } }
                Button(language.localized("Disconnect", "断开")) { Task { await runtime.close(targetID: target.targetID) } }.disabled(session == nil)
            }
            .controlSize(.small).padding(10)
            Divider()
            if let message = error ?? session?.errorCode {
                Text(message).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            GeometryReader { geometry in
                if let session, let image = session.image, let observed = session.latest {
                    CompanionDesktopViewport(image: image, width: observed.width, height: observed.height, fit: fit) { body in
                        runtime.enqueueManualInput(body, session: session)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "desktopcomputer").font(.system(size: 44)).foregroundStyle(.secondary)
                        Text(status).font(.title3)
                        Text(language.localized("Companion desktop uses the encrypted relay. Windows RDP is not required.",
                            "Companion 桌面通过加密中转连接，无需开启 Windows RDP。"))
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    private var status: String {
        let code = session?.status ?? "disconnected"
        let descriptions = ["connecting": "正在连接", "awaitingFrame": "等待画面", "ready": "桌面就绪", "locked": "已锁定",
            "waitingForLogin": "等待登录", "uac": "UAC 安全桌面", "unavailable": "显示输出不可用", "disconnected": "未连接"]
        return language == .simplifiedChinese ? descriptions[code] ?? code : code
    }
}

private struct CompanionDesktopViewport: NSViewRepresentable {
    let image: CGImage
    let width, height: Int
    let fit: Bool
    let input: ([String: DesktopJSONValue]) -> Void
    func makeNSView(context: Context) -> CompanionDesktopInputView { CompanionDesktopInputView() }
    func updateNSView(_ view: CompanionDesktopInputView, context: Context) {
        view.image = image; view.remoteSize = CGSize(width: width, height: height); view.fit = fit
        view.input = input; view.needsDisplay = true
    }
}

private final class CompanionDesktopInputView: NSView, NSTextInputClient {
    var image: CGImage?
    var remoteSize = CGSize.zero
    var fit = true
    var input: (([String: DesktopJSONValue]) -> Void)?
    private var marked = NSAttributedString(string: "")
    private var selection = NSRange(location: 0, length: 0)
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var imageRect: CGRect {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return .zero }
        let scale = fit ? min(bounds.width / remoteSize.width, bounds.height / remoteSize.height) : 1
        let size = CGSize(width: remoteSize.width * scale, height: remoteSize.height * scale)
        return CGRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let image else { return }
        NSImage(cgImage: image, size: remoteSize).draw(in: imageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer(event, kind: "pointerButton", button: "left", pressed: true) }
    override func mouseUp(with event: NSEvent) { pointer(event, kind: "pointerButton", button: "left", pressed: false) }
    override func rightMouseDown(with event: NSEvent) { pointer(event, kind: "pointerButton", button: "right", pressed: true) }
    override func rightMouseUp(with event: NSEvent) { pointer(event, kind: "pointerButton", button: "right", pressed: false) }
    override func mouseDragged(with event: NSEvent) { pointer(event, kind: "pointerMove") }
    override func scrollWheel(with event: NSEvent) {
        pointer(event, kind: "scroll", delta: Int(max(-12000, min(12000, event.scrollingDeltaY * 30))))
    }
    private func pointer(_ event: NSEvent, kind: String, button: String? = nil, pressed: Bool? = nil, delta: Int? = nil) {
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        guard rect.width > 0, rect.height > 0, rect.contains(point) || pressed == false else { return }
        var value: [String: DesktopJSONValue] = ["kind": .string(kind),
            "x": .integer(Int64(max(0, min(remoteSize.width - 1, (point.x-rect.minX)*remoteSize.width/rect.width)))),
            "y": .integer(Int64(max(0, min(remoteSize.height - 1, (point.y-rect.minY)*remoteSize.height/rect.height))))]
        if let button { value["button"] = .string(button) }; if let pressed { value["pressed"] = .bool(pressed) }
        if let delta, delta != 0 { value["delta"] = .integer(Int64(delta)) }
        input?(value)
    }
    override func keyDown(with event: NSEvent) {
        if hasMarkedText() { interpretKeyEvents([event]); return }
        let functional: [UInt16: Int] = [36: 13, 48: 9, 51: 8, 53: 27, 117: 46, 123: 37, 124: 39, 125: 40, 126: 38, 115: 36, 119: 35]
        let modified = event.modifierFlags.intersection([.control, .option, .command])
        if let key = functional[event.keyCode] ?? (!modified.isEmpty ? event.charactersIgnoringModifiers.flatMap(CompanionDesktopKeyMap.virtualKey) : nil) {
            var keys: [Int] = []
            if event.modifierFlags.contains(.control) { keys.append(0x11) }
            if event.modifierFlags.contains(.shift) { keys.append(0x10) }
            if event.modifierFlags.contains(.option) { keys.append(0x12) }
            if event.modifierFlags.contains(.command) { keys.append(0x5B) }
            keys.append(key)
            input?(["kind": .string("keyChord"), "virtualKeys": .array(keys.map { .integer(Int64($0)) })])
        } else { interpretKeyEvents([event]) }
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        guard !text.isEmpty, text.utf16.count <= 4096 else { return }
        input?(["kind": .string("text"), "text": .string(text)])
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        guard text.length <= 4096 else { unmarkText(); return }
        marked = text; selection = selectedRange
    }
    func unmarkText() { marked = NSAttributedString(string: ""); selection = NSRange(location: 0, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { selection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, range.location <= marked.length, range.length <= marked.length - range.location else { return nil }
        actualRange?.pointee = range; return marked.attributedSubstring(from: range)
    }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = markedRange()
        return window?.convertToScreen(convert(NSRect(x: imageRect.minX, y: imageRect.maxY - 24, width: 1, height: 24), to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    override func doCommand(by selector: Selector) {
        let keys = ["insertNewline:": 13, "insertTab:": 9, "deleteBackward:": 8, "deleteForward:": 46,
            "moveLeft:": 37, "moveRight:": 39, "moveUp:": 38, "moveDown:": 40, "cancelOperation:": 27]
        if let key = keys[NSStringFromSelector(selector)] {
            input?(["kind": .string("keyChord"), "virtualKeys": .array([.integer(Int64(key))])])
        }
    }
}
#endif
