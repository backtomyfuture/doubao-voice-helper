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
    func tap(_ shortcut: KeyboardShortcut) throws
    func keyDown(_ shortcut: KeyboardShortcut) throws
    func keyUp(_ shortcut: KeyboardShortcut) throws
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

    public func tap(_ shortcut: KeyboardShortcut) throws {
        try keyDown(shortcut)
        usleep(tapDuration)
        try keyUp(shortcut)
    }

    public func keyDown(_ shortcut: KeyboardShortcut) throws {
        let source = try eventSource()
        if isModifierKey(shortcut.keyCode) {
            try post(
                source: source,
                keyCode: shortcut.keyCode,
                keyDown: true,
                flags: flags(for: shortcut)
            )
            return
        }

        var activeFlags: CGEventFlags = []
        for modifier in modifierOrder where shortcut.modifiers.contains(modifier) {
            activeFlags.formUnion(flags(for: modifier))
            try post(
                source: source,
                keyCode: keyCode(for: modifier),
                keyDown: true,
                flags: activeFlags
            )
        }

        if !isModifierKey(shortcut.keyCode) {
            try post(
                source: source,
                keyCode: shortcut.keyCode,
                keyDown: true,
                flags: flags(for: shortcut)
            )
        }
    }

    public func keyUp(_ shortcut: KeyboardShortcut) throws {
        let source = try eventSource()
        if isModifierKey(shortcut.keyCode) {
            try post(
                source: source,
                keyCode: shortcut.keyCode,
                keyDown: false,
                flags: []
            )
            return
        }

        let modifiers = modifierOrder.filter {
            shortcut.modifiers.contains($0)
        }

        if !isModifierKey(shortcut.keyCode) {
            try post(
                source: source,
                keyCode: shortcut.keyCode,
                keyDown: false,
                flags: flags(for: shortcut)
            )
        }

        var activeFlags = flags(for: shortcut)
        for modifier in modifiers.reversed() {
            activeFlags.subtract(flags(for: modifier))
            try post(
                source: source,
                keyCode: keyCode(for: modifier),
                keyDown: false,
                flags: activeFlags
            )
        }
    }

    private var modifierOrder: [KeyboardModifier] {
        [.command, .option, .control, .shift, .function]
    }

    private func eventSource() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ShortcutEmitterError.eventSourceUnavailable
        }
        return source
    }

    private func post(
        source: CGEventSource,
        keyCode: UInt16,
        keyDown: Bool,
        flags: CGEventFlags
    ) throws {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(keyCode),
            keyDown: keyDown
        ) else {
            throw ShortcutEmitterError.keyEventCreationFailed
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func keyCode(for modifier: KeyboardModifier) -> UInt16 {
        switch modifier {
        case .command: return 55
        case .option: return 58
        case .control: return 59
        case .shift: return 56
        case .function: return 63
        }
    }

    private func isModifierKey(_ keyCode: UInt16) -> Bool {
        [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    private func flags(for shortcut: KeyboardShortcut) -> CGEventFlags {
        var eventFlags: CGEventFlags = []
        for modifier in modifierOrder where shortcut.modifiers.contains(modifier) {
            eventFlags.formUnion(flags(for: modifier))
        }
        return eventFlags
    }

    private func flags(for modifier: KeyboardModifier) -> CGEventFlags {
        switch modifier {
        case .command: return .maskCommand
        case .option: return .maskAlternate
        case .control: return .maskControl
        case .shift: return .maskShift
        case .function: return .maskSecondaryFn
        }
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
