import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import RemoteDesktopCore

enum DesktopInputError: LocalizedError {
    case accessibilityRequired
    case invalidDisplay
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired: return "需要在系统设置中允许 JTS Mac Companion 使用辅助功能，才能控制桌面。"
        case .invalidDisplay: return "远程显示器坐标无效。"
        case .eventCreationFailed: return "无法创建远程输入事件。"
        }
    }
}

enum DesktopInputCoordinates {
    /// Core Graphics uses global display points with a top-left origin, while
    /// capture resolution may use Retina pixels. Normalization keeps them aligned.
    static func point(x: Double, y: Double, in bounds: CGRect) throws -> CGPoint {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y),
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.width > 0, bounds.height > 0 else {
            throw DesktopInputError.invalidDisplay
        }
        return CGPoint(x: bounds.minX + CGFloat(x) * max(0, bounds.width - 1),
                       y: bounds.minY + CGFloat(y) * max(0, bounds.height - 1))
    }
}

/// Only the explicitly approved desktop session may route input here. Keys and
/// buttons are tracked so disconnect, sleep, or host stop cannot leave them held.
@MainActor
final class DesktopInputController {
    static var isAuthorized: Bool { AXIsProcessTrusted() }
    var displayBounds: CGRect

    private let eventSource = CGEventSource(stateID: .privateState)
    private let permissionCheck: () -> Bool
    private let eventPoster: (CGEvent) -> Void
    private var heldKeys = Set<CGKeyCode>()
    private var heldButtons = Set<DesktopMouseButton>()
    private var lastLocation: CGPoint
    private var modifiers = CGEventFlags()
    private var lastClickButton: DesktopMouseButton?
    private var lastClickTime: TimeInterval = 0
    private var lastClickLocation = CGPoint.zero
    private var clickCount: Int64 = 0

    init(displayBounds: CGRect = CGDisplayBounds(CGMainDisplayID()),
         permissionCheck: @escaping () -> Bool = { AXIsProcessTrusted() },
         eventPoster: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) {
        self.displayBounds = displayBounds
        self.lastLocation = CGPoint(x: displayBounds.midX, y: displayBounds.midY)
        self.permissionCheck = permissionCheck
        self.eventPoster = eventPoster
    }

    func handle(_ input: DesktopInput) throws {
        try input.validate()
        if case .releaseAll = input {
            releaseAll()
            return
        }
        guard permissionCheck() else {
            releaseAll()
            throw DesktopInputError.accessibilityRequired
        }
        switch input {
        case let .pointer(x, y, button, isDown):
            let location = try DesktopInputCoordinates.point(x: x, y: y, in: displayBounds)
            try pointer(at: location, button: button, isDown: isDown)
        case let .scroll(x, y, deltaX, deltaY):
            let location = try DesktopInputCoordinates.point(x: x, y: y, in: displayBounds)
            guard let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel,
                                      wheelCount: 2, wheel1: Int32(deltaY.rounded()),
                                      wheel2: Int32(deltaX.rounded()), wheel3: 0) else {
                throw DesktopInputError.eventCreationFailed
            }
            lastLocation = location
            event.location = location
            event.flags = modifiers
            eventPoster(event)
        case let .key(keyCode, isDown, rawModifiers):
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: isDown) else {
                throw DesktopInputError.eventCreationFailed
            }
            modifiers = CGEventFlags(rawValue: rawModifiers)
            event.flags = modifiers
            event.setIntegerValueField(.keyboardEventAutorepeat, value: isDown && heldKeys.contains(keyCode) ? 1 : 0)
            if isDown { heldKeys.insert(keyCode) } else { heldKeys.remove(keyCode) }
            eventPoster(event)
        case .releaseAll: break
        }
    }

    func releaseAll() {
        if permissionCheck() {
            for key in heldKeys.sorted() {
                let event = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: false)
                event?.flags = []
                if let event { eventPoster(event) }
            }
            for button in heldButtons.sorted(by: { $0.rawValue < $1.rawValue }) {
                let event = CGEvent(mouseEventSource: eventSource, mouseType: Self.mouseType(button, isDown: false),
                                    mouseCursorPosition: lastLocation, mouseButton: Self.cgButton(button))
                event?.flags = []
                if let event { eventPoster(event) }
            }
        }
        heldKeys.removeAll()
        heldButtons.removeAll()
        modifiers = []
        lastClickButton = nil
        clickCount = 0
    }

    private func pointer(at location: CGPoint, button: DesktopMouseButton?, isDown: Bool?) throws {
        let activeButton = button ?? heldButtons.sorted(by: { $0.rawValue < $1.rawValue }).first
        let type: CGEventType
        if let button, let isDown {
            type = Self.mouseType(button, isDown: isDown)
        } else {
            switch activeButton {
            case .left: type = .leftMouseDragged
            case .right: type = .rightMouseDragged
            case .center: type = .otherMouseDragged
            case nil: type = .mouseMoved
            }
        }
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                                  mouseCursorPosition: location,
                                  mouseButton: Self.cgButton(activeButton ?? .left)) else {
            throw DesktopInputError.eventCreationFailed
        }
        lastLocation = location
        event.flags = modifiers
        if let button, let isDown {
            if isDown {
                let now = ProcessInfo.processInfo.systemUptime
                let distance = hypot(location.x - lastClickLocation.x, location.y - lastClickLocation.y)
                let isRepeatedClick = button == lastClickButton && now - lastClickTime <= NSEvent.doubleClickInterval && distance <= 4
                clickCount = isRepeatedClick ? min(clickCount + 1, 3) : 1
                lastClickButton = button
                lastClickTime = now
                lastClickLocation = location
            }
            event.setIntegerValueField(.mouseEventClickState, value: max(1, clickCount))
            if isDown { heldButtons.insert(button) } else { heldButtons.remove(button) }
        }
        eventPoster(event)
    }

    private static func cgButton(_ button: DesktopMouseButton) -> CGMouseButton {
        switch button {
        case .left: return .left
        case .right: return .right
        case .center: return .center
        }
    }

    private static func mouseType(_ button: DesktopMouseButton, isDown: Bool) -> CGEventType {
        switch button {
        case .left: return isDown ? .leftMouseDown : .leftMouseUp
        case .right: return isDown ? .rightMouseDown : .rightMouseUp
        case .center: return isDown ? .otherMouseDown : .otherMouseUp
        }
    }
}
