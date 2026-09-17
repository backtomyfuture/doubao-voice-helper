import ApplicationServices
import CoreGraphics
import Foundation
import ServiceManagement

public struct PermissionSnapshot: Equatable, Sendable {
    public let accessibilityTrusted: Bool
    public let inputMonitoringAuthorized: Bool

    public init(
        accessibilityTrusted: Bool,
        inputMonitoringAuthorized: Bool
    ) {
        self.accessibilityTrusted = accessibilityTrusted
        self.inputMonitoringAuthorized = inputMonitoringAuthorized
    }
}

public final class PermissionService {
    public init() {}

    public func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            accessibilityTrusted: AXIsProcessTrusted(),
            inputMonitoringAuthorized: CGPreflightListenEventAccess()
        )
    }

    @discardableResult
    public func requestAccessibility() -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    public func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }
}

public protocol ShortcutEmitting {
    func emit(_ shortcut: KeyboardShortcut) throws
}

public enum ShortcutEmitterError: Error {
    case eventSourceUnavailable
    case keyEventCreationFailed
}

public final class CoreGraphicsShortcutEmitter: ShortcutEmitting {
    private let tapDuration: useconds_t

    public init(tapDurationMilliseconds: UInt32 = 50) {
        tapDuration = useconds_t(tapDurationMilliseconds * 1_000)
    }

    public func emit(_ shortcut: KeyboardShortcut) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ShortcutEmitterError.eventSourceUnavailable
        }

        let flags = flags(for: shortcut)
        guard
            let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(shortcut.keyCode),
                keyDown: true
            ),
            let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(shortcut.keyCode),
                keyDown: false
            )
        else {
            throw ShortcutEmitterError.keyEventCreationFailed
        }

        down.flags = flags
        down.post(tap: .cghidEventTap)
        usleep(tapDuration)
        up.flags = isModifierKey(shortcut.keyCode) ? [] : flags
        up.post(tap: .cghidEventTap)
    }

    private func isModifierKey(_ keyCode: UInt16) -> Bool {
        [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    private func flags(for shortcut: KeyboardShortcut) -> CGEventFlags {
        var flags: CGEventFlags = []
        if shortcut.modifiers.contains(.command) {
            flags.insert(.maskCommand)
        }
        if shortcut.modifiers.contains(.option) {
            flags.insert(.maskAlternate)
        }
        if shortcut.modifiers.contains(.control) {
            flags.insert(.maskControl)
        }
        if shortcut.modifiers.contains(.shift) {
            flags.insert(.maskShift)
        }
        if shortcut.modifiers.contains(.function) {
            flags.insert(.maskSecondaryFn)
        }
        return flags
    }
}

public final class LoginItemService {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }
}
