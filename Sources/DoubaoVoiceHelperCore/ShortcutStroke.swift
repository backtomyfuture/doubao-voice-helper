import Foundation

public struct SynthesizedKeyEvent: Equatable, Sendable {
    public var keyCode: UInt16
    public var keyDown: Bool
    public var modifiers: Set<KeyboardModifier>
    public var flagBits: UInt64

    public init(
        keyCode: UInt16,
        keyDown: Bool,
        modifiers: Set<KeyboardModifier>,
        flagBits: UInt64 = 0
    ) {
        self.keyCode = keyCode
        self.keyDown = keyDown
        self.modifiers = modifiers
        self.flagBits = flagBits
    }
}

public enum ShortcutStroke {
    public static func keyDownEvents(
        for shortcut: KeyboardShortcut
    ) -> [SynthesizedKeyEvent] {
        sequence(for: shortcut, keyDown: true)
    }

    public static func keyUpEvents(
        for shortcut: KeyboardShortcut
    ) -> [SynthesizedKeyEvent] {
        sequence(for: shortcut, keyDown: false)
    }

    private static let modifierOrder: [KeyboardModifier] = [
        .command, .option, .control, .shift, .function,
    ]

    public static func resolvedKeyCodes(
        for shortcut: KeyboardShortcut
    ) -> [UInt16] {
        if !shortcut.physicalKeyCodes.isEmpty {
            return shortcut.physicalKeyCodes
        }
        let primaryModifier = modifier(forKeyCode: shortcut.keyCode)
        let extra = modifierOrder.filter {
            shortcut.modifiers.contains($0) && $0 != primaryModifier
        }
        return extra.map { keyCode(for: $0) } + [shortcut.keyCode]
    }

    private static func sequence(
        for shortcut: KeyboardShortcut,
        keyDown: Bool
    ) -> [SynthesizedKeyEvent] {
        let codes = resolvedKeyCodes(for: shortcut)
        guard !codes.isEmpty else { return [] }

        if keyDown {
            var down = Set<KeyboardModifier>()
            var downCodes: [UInt16] = []
            var events: [SynthesizedKeyEvent] = []
            for code in codes {
                if let modifier = modifier(forKeyCode: code) {
                    down.insert(modifier)
                }
                downCodes.append(code)
                events.append(
                    SynthesizedKeyEvent(
                        keyCode: code,
                        keyDown: true,
                        modifiers: down,
                        flagBits: eventFlags(forDownKeyCodes: downCodes)
                    )
                )
            }
            return events
        }

        var remainingCodes = codes
        var remaining = Set(codes.compactMap { modifier(forKeyCode: $0) })
        var events: [SynthesizedKeyEvent] = []
        for code in codes.reversed() {
            remainingCodes.removeAll { $0 == code }
            if let modifier = modifier(forKeyCode: code) {
                remaining.remove(modifier)
            }
            events.append(
                SynthesizedKeyEvent(
                    keyCode: code,
                    keyDown: false,
                    modifiers: remaining,
                    flagBits: eventFlags(forDownKeyCodes: remainingCodes)
                )
            )
        }
        return events
    }

    public static let nonCoalescedFlag: UInt64 = 0x00000100
    public static let leftControlDeviceFlag: UInt64 = 0x00000001
    public static let leftShiftDeviceFlag: UInt64 = 0x00000002
    public static let rightShiftDeviceFlag: UInt64 = 0x00000004
    public static let leftCommandDeviceFlag: UInt64 = 0x00000008
    public static let rightCommandDeviceFlag: UInt64 = 0x00000010
    public static let leftOptionDeviceFlag: UInt64 = 0x00000020
    public static let rightOptionDeviceFlag: UInt64 = 0x00000040
    public static let rightControlDeviceFlag: UInt64 = 0x00002000

    public static func eventFlags(forDownKeyCodes codes: [UInt16]) -> UInt64 {
        var raw = nonCoalescedFlag
        for code in codes {
            if let modifier = modifier(forKeyCode: code) {
                raw |= genericFlag(for: modifier)
            }
            raw |= deviceFlag(forKeyCode: code)
        }
        return raw
    }

    public static func deviceFlag(forKeyCode keyCode: UInt16) -> UInt64 {
        switch keyCode {
        case 59: return leftControlDeviceFlag
        case 56: return leftShiftDeviceFlag
        case 60: return rightShiftDeviceFlag
        case 55: return leftCommandDeviceFlag
        case 54: return rightCommandDeviceFlag
        case 58: return leftOptionDeviceFlag
        case 61: return rightOptionDeviceFlag
        case 62: return rightControlDeviceFlag
        default: return 0
        }
    }

    public static func genericFlag(for modifier: KeyboardModifier) -> UInt64 {
        switch modifier {
        case .command: return 0x00100000
        case .shift: return 0x00020000
        case .control: return 0x00040000
        case .option: return 0x00080000
        case .function: return 0x00800000
        }
    }

    public static func keyCode(for modifier: KeyboardModifier) -> UInt16 {
        switch modifier {
        case .command: return 55
        case .option: return 58
        case .control: return 59
        case .shift: return 56
        case .function: return 63
        }
    }

    public static func modifier(forKeyCode keyCode: UInt16) -> KeyboardModifier? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return nil
        }
    }

    public static func isModifierKey(_ keyCode: UInt16) -> Bool {
        modifier(forKeyCode: keyCode) != nil
    }
}
