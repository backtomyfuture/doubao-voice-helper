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
        let modifierNames = KeyboardModifier.allCases
            .filter { modifiers.contains($0) }
            .map(\.displayName)
            .joined()
        if let modifierName = modifierKeyName {
            let primaryModifier = modifierForKeyCode
            let extraModifiers = KeyboardModifier.allCases
                .filter {
                    modifiers.contains($0) && $0 != primaryModifier
                }
                .map(\.displayName)
                .joined()
            if extraModifiers.isEmpty {
                return modifierName
            }
            return "\(extraModifiers) + \(modifierName)"
        }
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

    private var modifierForKeyCode: KeyboardModifier? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
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

    public var displayName: String {
        switch button {
        case 0: return "左键"
        case 1: return "右键"
        case 2: return "中键"
        default: return "额外键 \(button)"
        }
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
    public static let currentSchemaVersion = 7
    public static let bundleIdentifier = "com.jarod.doubao-voice-helper"

    public var schemaVersion: Int
    public var toggleMouseBinding: MouseBinding
    public var holdMouseBinding: MouseBinding
    public var enterMouseBinding: MouseBinding
    public var toggleShortcut: KeyboardShortcut
    public var holdShortcut: KeyboardShortcut
    public var enterShortcut: KeyboardShortcut
    public var excludedBundleIDs: [String]
    public var macroRules: [MacroRule]
    public var launchAtLogin: Bool
    public var overlayEnabled: Bool

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        toggleMouseBinding: MouseBinding = AppSettings.defaultToggleMouseBinding,
        holdMouseBinding: MouseBinding = AppSettings.defaultHoldMouseBinding,
        enterMouseBinding: MouseBinding = AppSettings.defaultEnterMouseBinding,
        toggleShortcut: KeyboardShortcut = AppSettings.defaultToggleShortcut,
        holdShortcut: KeyboardShortcut = AppSettings.defaultHoldShortcut,
        enterShortcut: KeyboardShortcut = AppSettings.defaultEnterShortcut,
        excludedBundleIDs: [String] = AppSettings.defaultExcludedBundleIDs,
        macroRules: [MacroRule] = AppSettings.defaultMacroRules,
        launchAtLogin: Bool = true,
        overlayEnabled: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.toggleMouseBinding = toggleMouseBinding
        self.holdMouseBinding = holdMouseBinding
        self.enterMouseBinding = enterMouseBinding
        self.toggleShortcut = toggleShortcut
        self.holdShortcut = holdShortcut
        self.enterShortcut = enterShortcut
        self.excludedBundleIDs = excludedBundleIDs
        self.macroRules = macroRules
        self.launchAtLogin = launchAtLogin
        self.overlayEnabled = overlayEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? AppSettings.currentSchemaVersion
        schemaVersion = max(decodedSchemaVersion, AppSettings.currentSchemaVersion)

        let legacyMouseBinding = try container.decodeIfPresent(
            MouseBinding.self,
            forKey: .legacyMouseBinding
        )
        let legacyShortcut = try container.decodeIfPresent(
            KeyboardShortcut.self,
            forKey: .legacyDoubaoShortcut
        )
        toggleMouseBinding = try container.decodeIfPresent(
            MouseBinding.self,
            forKey: .toggleMouseBinding
        ) ?? AppSettings.defaultToggleMouseBinding
        holdMouseBinding = try container.decodeIfPresent(
            MouseBinding.self,
            forKey: .holdMouseBinding
        ) ?? legacyMouseBinding ?? AppSettings.defaultHoldMouseBinding
        enterMouseBinding = try container.decodeIfPresent(
            MouseBinding.self,
            forKey: .enterMouseBinding
        ) ?? AppSettings.defaultEnterMouseBinding
        var decodedToggleShortcut = try container.decodeIfPresent(
            KeyboardShortcut.self,
            forKey: .toggleShortcut
        ) ?? legacyShortcut ?? AppSettings.defaultToggleShortcut
        var decodedHoldShortcut = try container.decodeIfPresent(
            KeyboardShortcut.self,
            forKey: .holdShortcut
        ) ?? AppSettings.defaultHoldShortcut
        let intermediateHoldShortcut = KeyboardShortcut(
            keyCode: 59,
            modifiers: [.control, .option, .command]
        )
        if decodedSchemaVersion == 2,
           decodedToggleShortcut == intermediateHoldShortcut,
           decodedHoldShortcut == AppSettings.defaultToggleShortcut
        {
            decodedToggleShortcut = AppSettings.defaultToggleShortcut
            decodedHoldShortcut = AppSettings.defaultHoldShortcut
        }
        let brokenSchemaThreeHoldShortcut = KeyboardShortcut(
            keyCode: 58,
            modifiers: [.command, .option]
        )
        if decodedHoldShortcut == brokenSchemaThreeHoldShortcut
        {
            decodedHoldShortcut = AppSettings.defaultHoldShortcut
        }
        if decodedSchemaVersion <= 4,
           decodedHoldShortcut == AppSettings.defaultToggleShortcut
        {
            decodedHoldShortcut = AppSettings.defaultHoldShortcut
        }
        let brokenSchemaFiveHoldShortcut = KeyboardShortcut(
            keyCode: 55,
            modifiers: [.command]
        )
        if decodedHoldShortcut == brokenSchemaFiveHoldShortcut
        {
            decodedHoldShortcut = AppSettings.defaultHoldShortcut
        }
        toggleShortcut = decodedToggleShortcut
        holdShortcut = decodedHoldShortcut
        enterShortcut = try container.decodeIfPresent(
            KeyboardShortcut.self,
            forKey: .enterShortcut
        ) ?? AppSettings.defaultEnterShortcut
        var decodedExcludedBundleIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .excludedBundleIDs
        ) ?? AppSettings.defaultExcludedBundleIDs
        if decodedSchemaVersion < AppSettings.currentSchemaVersion {
            for bundleIdentifier in AppSettings.defaultExcludedBundleIDs
                where !decodedExcludedBundleIDs.contains(bundleIdentifier)
            {
                decodedExcludedBundleIDs.append(bundleIdentifier)
            }
        }
        if !decodedExcludedBundleIDs.contains(AppSettings.bundleIdentifier) {
            decodedExcludedBundleIDs.append(AppSettings.bundleIdentifier)
        }
        decodedExcludedBundleIDs.removeAll {
            $0 == "com.stablyai.orca" ||
                $0 == "com.citrolabs.ego" ||
                $0 == "com.citrolabs.ego.lite"
        }
        excludedBundleIDs = decodedExcludedBundleIDs
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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(
            toggleMouseBinding,
            forKey: .toggleMouseBinding
        )
        try container.encode(
            holdMouseBinding,
            forKey: .holdMouseBinding
        )
        try container.encode(
            enterMouseBinding,
            forKey: .enterMouseBinding
        )
        try container.encode(toggleShortcut, forKey: .toggleShortcut)
        try container.encode(holdShortcut, forKey: .holdShortcut)
        try container.encode(enterShortcut, forKey: .enterShortcut)
        try container.encode(excludedBundleIDs, forKey: .excludedBundleIDs)
        try container.encode(macroRules, forKey: .macroRules)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(overlayEnabled, forKey: .overlayEnabled)
    }

    public var mouseBinding: MouseBinding {
        get { holdMouseBinding }
        set { holdMouseBinding = newValue }
    }

    public var doubaoShortcut: KeyboardShortcut {
        get { holdShortcut }
        set { holdShortcut = newValue }
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
        "com.apple.Preview",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "com.bot.pc.doubao",
        "com.work.pc.doubao",
        AppSettings.bundleIdentifier,
    ]

    public static let defaultToggleMouseBinding = MouseBinding(button: 4)
    public static let defaultHoldMouseBinding = MouseBinding(button: 0)
    public static let defaultEnterMouseBinding = MouseBinding(button: 3)
    public static let defaultToggleShortcut = KeyboardShortcut(
        keyCode: 59,
        modifiers: [.control]
    )
    public static let defaultHoldShortcut = KeyboardShortcut(
        keyCode: 59,
        modifiers: [.control, .option]
    )
    public static let defaultEnterShortcut = KeyboardShortcut(keyCode: 36)

    public static let defaultMacroRules = [
        MacroRule(source: "斜杠批准", replacement: "/approve"),
        MacroRule(source: "斜杠任务", replacement: "/missions"),
        MacroRule(source: "斜杠", replacement: "/"),
    ]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case toggleMouseBinding
        case holdMouseBinding
        case enterMouseBinding
        case toggleShortcut
        case holdShortcut
        case enterShortcut
        case legacyMouseBinding = "mouseBinding"
        case legacyDoubaoShortcut = "doubaoShortcut"
        case excludedBundleIDs
        case macroRules
        case launchAtLogin
        case overlayEnabled
    }
}
