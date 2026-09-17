import Foundation

public enum KeyboardModifier: String, Codable, CaseIterable, Hashable, Sendable {
    case command
    case option
    case control
    case shift
    case function

    public var displayName: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .function: return "fn"
        }
    }
}

public struct KeyboardShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: Set<KeyboardModifier>

    public init(keyCode: UInt16, modifiers: Set<KeyboardModifier> = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let doubaoDefault = KeyboardShortcut(
        keyCode: 59,
        modifiers: [.control]
    )

    public var displayName: String {
        if let modifierName = modifierKeyName {
            return modifierName
        }
        let modifierNames = KeyboardModifier.allCases
            .filter { modifiers.contains($0) }
            .map(\.displayName)
            .joined()
        return "\(modifierNames)\(keyName)"
    }

    private var modifierKeyName: String? {
        switch keyCode {
        case 54: return "右 Command"
        case 55: return "左 Command"
        case 56: return "左 Shift"
        case 58: return "左 Option"
        case 59: return "左 Control"
        case 60: return "右 Shift"
        case 61: return "右 Option"
        case 62: return "右 Control"
        case 63: return "fn"
        default: return nil
        }
    }

    private var keyName: String {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        case 117: return "Forward Delete"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "keyCode \(keyCode)"
        }
    }
}

public struct MouseBinding: Codable, Equatable, Sendable {
    public var button: Int64

    public init(button: Int64 = 4) {
        self.button = button
    }
}

public struct MacroRule: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var source: String
    public var replacement: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        source: String,
        replacement: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.source = source
        self.replacement = replacement
        self.isEnabled = isEnabled
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var mouseBinding: MouseBinding
    public var doubaoShortcut: KeyboardShortcut
    public var excludedBundleIDs: [String]
    public var macroRules: [MacroRule]
    public var launchAtLogin: Bool
    public var overlayEnabled: Bool

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        mouseBinding: MouseBinding = MouseBinding(),
        doubaoShortcut: KeyboardShortcut = .doubaoDefault,
        excludedBundleIDs: [String] = AppSettings.defaultExcludedBundleIDs,
        macroRules: [MacroRule] = AppSettings.defaultMacroRules,
        launchAtLogin: Bool = true,
        overlayEnabled: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.mouseBinding = mouseBinding
        self.doubaoShortcut = doubaoShortcut
        self.excludedBundleIDs = excludedBundleIDs
        self.macroRules = macroRules
        self.launchAtLogin = launchAtLogin
        self.overlayEnabled = overlayEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? AppSettings.currentSchemaVersion
        mouseBinding = try container.decodeIfPresent(
            MouseBinding.self,
            forKey: .mouseBinding
        ) ?? MouseBinding()
        doubaoShortcut = try container.decodeIfPresent(
            KeyboardShortcut.self,
            forKey: .doubaoShortcut
        ) ?? .doubaoDefault
        excludedBundleIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .excludedBundleIDs
        ) ?? AppSettings.defaultExcludedBundleIDs
        macroRules = try container.decodeIfPresent(
            [MacroRule].self,
            forKey: .macroRules
        ) ?? AppSettings.defaultMacroRules
        launchAtLogin = try container.decodeIfPresent(
            Bool.self,
            forKey: .launchAtLogin
        ) ?? true
        overlayEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .overlayEnabled
        ) ?? true
    }

    public func isExcluded(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return false
        }
        return excludedBundleIDs.contains {
            bundleIdentifier == $0 || bundleIdentifier.hasPrefix($0 + ".")
        }
    }

    public static let defaultExcludedBundleIDs = [
        "com.apple.finder",
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.bot.pc.doubao",
        "com.work.pc.doubao",
    ]

    public static let defaultMacroRules = [
        MacroRule(source: "斜杠批准", replacement: "/approve"),
        MacroRule(source: "斜杠任务", replacement: "/missions"),
        MacroRule(source: "斜杠", replacement: "/"),
    ]
}
