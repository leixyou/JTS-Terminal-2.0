#if ENABLE_RDP_2
import AppKit
import CoreGraphics
import RemoteDesktopCore
import SwiftUI

/// Screen coordinates use a top-left origin and include only the fitted image.
enum MacDesktopViewport {
    static func imageRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func normalizedPoint(_ point: CGPoint, imageRect: CGRect, clamp: Bool = false) -> CGPoint? {
        guard imageRect.width > 0, imageRect.height > 0,
              clamp || imageRect.contains(point) else { return nil }
        return CGPoint(
            x: min(1, max(0, (point.x - imageRect.minX) / imageRect.width)),
            y: min(1, max(0, (point.y - imageRect.minY) / imageRect.height))
        )
    }
}

enum MacDesktopKeyboardInput {
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt64 {
        UInt64(flags.rawValue) & 0x00ff0000
    }

    static func heldModifierKeys(flags: NSEvent.ModifierFlags, keyState: (UInt16) -> Bool) -> [UInt16] {
        let physicalKeys: [UInt16] = [54, 55, 56, 60, 58, 61, 59, 62, 63]
        return physicalKeys.filter(keyState) + (flags.contains(.capsLock) ? [57] : [])
    }

    static func modifierIsDown(keyCode: UInt16, flags: NSEvent.ModifierFlags, keyState: (UInt16) -> Bool) -> Bool {
        keyCode == 57 ? flags.contains(.capsLock) : keyState(keyCode)
    }
}

struct MacDesktopSurface: NSViewRepresentable {
    var image: NSImage
    var acceptsInput: Bool
    var onInput: (DesktopInput) -> Void
    var onRelease: () -> Void
    var onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> MacDesktopSurfaceView { MacDesktopSurfaceView() }

    func updateNSView(_ view: MacDesktopSurfaceView, context: Context) {
        view.onInput = onInput
        view.onRelease = onRelease
        view.onFocusChange = onFocusChange
        view.image = image
        view.inputEnabled = acceptsInput
    }

    static func dismantleNSView(_ view: MacDesktopSurfaceView, coordinator: ()) { view.releaseControl() }
}

final class MacDesktopSurfaceView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var inputEnabled = false {
        didSet {
            if !inputEnabled && oldValue { releaseControl() }
            needsDisplay = true
        }
    }
    var onInput: ((DesktopInput) -> Void)?
    var onRelease: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    private var heldKeys = Set<UInt16>()
    private var heldButtons = Set<Int>()
    private var tracking: NSTrackingArea?
    private var lastPointerAt: TimeInterval = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { inputEnabled }
    private var hasControlFocus: Bool { inputEnabled && window?.firstResponder === self && NSApp.isActive && window?.isKeyWindow == true }
    private var fittedImageRect: CGRect { MacDesktopViewport.imageRect(imageSize: image?.size ?? .zero, bounds: bounds) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("远程 Mac 桌面")
        setAccessibilityHelp("点击画面控制对方 Mac，按 Control Option Escape 释放键盘。")
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDeactivated), name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDeactivated(_:)), name: NSWindow.didResignKeyNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window != nil && newWindow !== window { releaseControl() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        image?.draw(in: fittedImageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if hasControlFocus {
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)).stroke()
        }
    }

    override func becomeFirstResponder() -> Bool {
        guard inputEnabled else { return false }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
        for key in MacDesktopKeyboardInput.heldModifierKeys(flags: flags, keyState: { CGEventSource.keyState(.combinedSessionState, key: $0) }) {
            heldKeys.insert(key)
            onInput?(.key(keyCode: key, isDown: true, modifiers: MacDesktopKeyboardInput.modifiers(flags)))
        }
        onFocusChange?(true)
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        releaseHeldInput()
        onFocusChange?(false)
        needsDisplay = true
        return true
    }

    func releaseControl() {
        releaseHeldInput()
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        onFocusChange?(false)
        needsDisplay = true
    }

    private func releaseHeldInput() {
        onRelease?()
        heldKeys.removeAll()
        heldButtons.removeAll()
    }

    @objc private func applicationDeactivated() { releaseControl() }
    @objc private func windowDeactivated(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        releaseControl()
    }

    override func mouseDown(with event: NSEvent) {
        guard inputEnabled, point(for: event) != nil else { return }
        window?.makeFirstResponder(self)
        pointerButton(event, button: .left, isDown: true)
    }
    override func mouseUp(with event: NSEvent) { pointerButton(event, button: .left, isDown: false) }
    override func rightMouseDown(with event: NSEvent) {
        guard inputEnabled, point(for: event) != nil else { return }
        window?.makeFirstResponder(self)
        pointerButton(event, button: .right, isDown: true)
    }
    override func rightMouseUp(with event: NSEvent) { pointerButton(event, button: .right, isDown: false) }
    override func otherMouseDown(with event: NSEvent) {
        guard inputEnabled, point(for: event) != nil else { return }
        window?.makeFirstResponder(self)
        pointerButton(event, button: .center, isDown: true)
    }
    override func otherMouseUp(with event: NSEvent) { pointerButton(event, button: .center, isDown: false) }
    override func mouseDragged(with event: NSEvent) { pointerMove(event, dragging: true) }
    override func rightMouseDragged(with event: NSEvent) { pointerMove(event, dragging: true) }
    override func otherMouseDragged(with event: NSEvent) { pointerMove(event, dragging: true) }
    override func mouseMoved(with event: NSEvent) { pointerMove(event, dragging: false) }

    override func scrollWheel(with event: NSEvent) {
        guard hasControlFocus, let point = point(for: event) else { return }
        onInput?(.scroll(x: point.x, y: point.y, deltaX: Double(event.scrollingDeltaX), deltaY: Double(event.scrollingDeltaY)))
    }

    override func keyDown(with event: NSEvent) {
        guard hasControlFocus else { return }
        if event.keyCode == 53 && event.modifierFlags.contains([.control, .option]) {
            releaseControl()
            return
        }
        heldKeys.insert(event.keyCode)
        onInput?(.key(keyCode: event.keyCode, isDown: true, modifiers: MacDesktopKeyboardInput.modifiers(event.modifierFlags)))
    }

    override func keyUp(with event: NSEvent) {
        guard hasControlFocus, heldKeys.remove(event.keyCode) != nil else { return }
        onInput?(.key(keyCode: event.keyCode, isDown: false, modifiers: MacDesktopKeyboardInput.modifiers(event.modifierFlags)))
    }

    override func flagsChanged(with event: NSEvent) {
        guard hasControlFocus else { return }
        // Physical state handles both modifier sides and focus gained while a
        // modifier is already held. An initial release must remain a release.
        let isDown = MacDesktopKeyboardInput.modifierIsDown(keyCode: event.keyCode, flags: event.modifierFlags) {
            CGEventSource.keyState(.combinedSessionState, key: $0)
        }
        if isDown { heldKeys.insert(event.keyCode) } else { heldKeys.remove(event.keyCode) }
        onInput?(.key(keyCode: event.keyCode, isDown: isDown, modifiers: MacDesktopKeyboardInput.modifiers(event.modifierFlags)))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard hasControlFocus, event.type == .keyDown else { return false }
        keyDown(with: event)
        return true
    }

    private func point(for event: NSEvent, clamp: Bool = false) -> CGPoint? {
        MacDesktopViewport.normalizedPoint(convert(event.locationInWindow, from: nil), imageRect: fittedImageRect, clamp: clamp)
    }

    private func pointerButton(_ event: NSEvent, button: RemoteDesktopCore.DesktopMouseButton, isDown: Bool) {
        guard hasControlFocus, let point = point(for: event, clamp: !isDown) else { return }
        if isDown { heldButtons.insert(event.buttonNumber) }
        else { heldButtons.remove(event.buttonNumber) }
        onInput?(.pointer(x: point.x, y: point.y, button: button, isDown: isDown))
    }

    private func pointerMove(_ event: NSEvent, dragging: Bool) {
        guard hasControlFocus, let point = point(for: event, clamp: dragging) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPointerAt >= 1.0 / 60.0 else { return }
        lastPointerAt = now
        onInput?(.pointer(x: point.x, y: point.y, button: nil, isDown: nil))
    }
}

#endif
