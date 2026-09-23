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
        // Value of kAXTrustedCheckOptionPrompt; the imported global is a
        // mutable C variable that Swift 6 rejects as shared state.
        let options = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    public func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }
}

public protocol ShortcutEmitting: Sendable {
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

    public init(tapDurationMilliseconds: UInt32 = 35) {
        tapDuration = useconds_t(tapDurationMilliseconds * 1_000)
    }

    public func tap(_ shortcut: KeyboardShortcut) throws {
        try keyDown(shortcut)
        usleep(tapDuration)
        try keyUp(shortcut)
    }

    public func keyDown(_ shortcut: KeyboardShortcut) throws {
        try post(ShortcutStroke.keyDownEvents(for: shortcut))
    }

    public func keyUp(_ shortcut: KeyboardShortcut) throws {
        try post(ShortcutStroke.keyUpEvents(for: shortcut))
    }

    private func eventSource() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ShortcutEmitterError.eventSourceUnavailable
        }
        source.localEventsSuppressionInterval = 0
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        return source
    }

    private func post(_ events: [SynthesizedKeyEvent]) throws {
        let source = try eventSource()
        for (index, event) in events.enumerated() {
            try post(
                source: source,
                keyCode: event.keyCode,
                keyDown: event.keyDown,
                flagBits: event.flagBits
            )
            if index + 1 < events.count {
                usleep(20_000)
            }
        }
    }

    private func post(
        source: CGEventSource,
        keyCode: UInt16,
        keyDown: Bool,
        flagBits: UInt64
    ) throws {
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(keyCode),
            keyDown: keyDown
        ) else {
            throw ShortcutEmitterError.keyEventCreationFailed
        }
        event.flags = CGEventFlags(rawValue: flagBits)
        if ShortcutStroke.isModifierKey(keyCode) {
            event.type = .flagsChanged
        }
        event.post(tap: .cghidEventTap)
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
