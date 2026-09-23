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
    public var physicalKeyCodes: [UInt16]

    public init(
        keyCode: UInt16,
        modifiers: Set<KeyboardModifier> = [],
        physicalKeyCodes: [UInt16] = []
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.physicalKeyCodes = physicalKeyCodes
    }

    public init(physicalKeyCodes: [UInt16]) {
        self.physicalKeyCodes = physicalKeyCodes
        self.keyCode = physicalKeyCodes.last ?? 0
        self.modifiers = Set(
            physicalKeyCodes.compactMap(ShortcutStroke.modifier(forKeyCode:))
        )
    }

    public static let doubaoDefault = KeyboardShortcut(
        keyCode: 59,
        modifiers: [.control],
        physicalKeyCodes: [59]
    )

    public static let leftControl = doubaoDefault

    public static let leftCommandLeftControl = KeyboardShortcut(
        keyCode: 59,
        modifiers: [.command, .control],
        physicalKeyCodes: [55, 59]
    )

    public static let leftControlOption = KeyboardShortcut(
        keyCode: 59,
        modifiers: [.control, .option],
        physicalKeyCodes: [59, 58]
    )

    public static let rightControl = KeyboardShortcut(
        keyCode: 62,
        modifiers: [.control],
        physicalKeyCodes: [62]
    )

    public static let returnKey = KeyboardShortcut(keyCode: 36)

    public var displayName: String {
        let codes = ShortcutStroke.resolvedKeyCodes(for: self)
        if codes.isEmpty {
            return Self.displayName(forKeyCode: keyCode)
        }
        if codes.allSatisfy(ShortcutStroke.isModifierKey) {
            return codes.map(Self.displayName(forKeyCode:)).joined(separator: " + ")
        }
        let modifierPrefix = codes
            .filter(ShortcutStroke.isModifierKey)
            .map(Self.displayName(forKeyCode:))
            .joined(separator: " + ")
        let keyPart = codes.last.map(Self.displayName(forKeyCode:)) ?? Self.displayName(forKeyCode: keyCode)
        if modifierPrefix.isEmpty {
            return keyPart
        }
        return "\(modifierPrefix) + \(keyPart)"
    }

    public static func displayName(forKeyCode keyCode: UInt16) -> String {
        switch keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Escape"
        case 54: return "右 Command"
        case 55: return "左 Command"
        case 56: return "左 Shift"
        case 58: return "左 Option"
        case 59: return "左 Control"
        case 60: return "右 Shift"
        case 61: return "右 Option"
        case 62: return "右 Control"
        case 63: return "fn"
        case 117: return "Forward Delete"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "keyCode \(keyCode)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
        case physicalKeyCodes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifiers = try container.decode(Set<KeyboardModifier>.self, forKey: .modifiers)
        physicalKeyCodes = try container.decodeIfPresent(
            [UInt16].self,
            forKey: .physicalKeyCodes
        ) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(physicalKeyCodes, forKey: .physicalKeyCodes)
    }
}

public struct MouseBinding: Codable, Equatable, Sendable {
    public var button: Int64

    public init(button: Int64 = 4) {
        self.button = button
    }

    public var displayName: String {
        switch button {
        case -1: return "未绑定"
        case 0: return "鼠标左键"
        case 1: return "鼠标右键"
        case 2: return "鼠标中键"
        case 3: return "后退键 (侧键下)"
        case 4: return "前进键 (侧键上)"
        default: return "额外按键 \(button)"
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

public struct AppVersion: Comparable, Equatable, CustomStringConvertible, Sendable {
    public let raw: String
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ string: String) {
        self.raw = string
        let cleaned = string.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n\r"))
        let parts = cleaned.split(separator: ".").compactMap { Int($0) }
        self.major = parts.indices.contains(0) ? parts[0] : 0
        self.minor = parts.indices.contains(1) ? parts[1] : 0
        self.patch = parts.indices.contains(2) ? parts[2] : 0
    }

    public var description: String {
        raw.hasPrefix("v") ? raw : "v\(raw)"
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 10
    public static let bundleIdentifier = "com.jarod.doubao-voice-helper"
    public static let gitHubRepository = "backtomyfuture/doubao-voice-helper"
    public static let gitHubReleasesAPIURL = URL(string: "https://api.github.com/repos/backtomyfuture/doubao-voice-helper/releases/latest")!
    public static let gitHubReleasesPageURL = URL(string: "https://github.com/backtomyfuture/doubao-voice-helper/releases")!
    public static let doubaoClientBundleIDs = [
        "com.bot.pc.doubao",
        "com.work.pc.doubao",
        "com.bytedance.inputmethod.doubaoime",
    ]

    public var schemaVersion: Int
    public var toggleMouseBinding: MouseBinding
    public var holdMouseBinding: MouseBinding
    public var enterMouseBinding: MouseBinding
    public var toggleShortcut: KeyboardShortcut
    public var holdShortcut: KeyboardShortcut
    public var enterShortcut: KeyboardShortcut
    public var excludedBundleIDs: [String]
    public var holdExcludedBundleIDs: [String]
    public var macroRules: [MacroRule]
    public var launchAtLogin: Bool
    public var overlayEnabled: Bool
    public var wechatHoldPreemptEnabled: Bool
    public var onboardingCompleted: Bool

    public var navigationExcludedBundleIDs: [String] {
        get { excludedBundleIDs }
        set { excludedBundleIDs = newValue }
    }

    public init(
        schemaVersion: Int = AppSettings.currentSchemaVersion,
        toggleMouseBinding: MouseBinding = AppSettings.defaultToggleMouseBinding,
        holdMouseBinding: MouseBinding = AppSettings.defaultHoldMouseBinding,
        enterMouseBinding: MouseBinding = AppSettings.defaultEnterMouseBinding,
        toggleShortcut: KeyboardShortcut = AppSettings.defaultToggleShortcut,
        holdShortcut: KeyboardShortcut = AppSettings.defaultHoldShortcut,
        enterShortcut: KeyboardShortcut = AppSettings.defaultEnterShortcut,
        excludedBundleIDs: [String] = AppSettings.defaultNavigationExcludedBundleIDs,
        holdExcludedBundleIDs: [String] = AppSettings.defaultHoldExcludedBundleIDs,
        macroRules: [MacroRule] = AppSettings.defaultMacroRules,
        launchAtLogin: Bool = true,
        overlayEnabled: Bool = true,
        wechatHoldPreemptEnabled: Bool = true,
        onboardingCompleted: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.toggleMouseBinding = toggleMouseBinding
        self.holdMouseBinding = holdMouseBinding
        self.enterMouseBinding = enterMouseBinding
        self.toggleShortcut = toggleShortcut
        self.holdShortcut = holdShortcut
        self.enterShortcut = enterShortcut
        self.excludedBundleIDs = excludedBundleIDs
        self.holdExcludedBundleIDs = holdExcludedBundleIDs
        self.macroRules = macroRules
        self.launchAtLogin = launchAtLogin
        self.overlayEnabled = overlayEnabled
        self.wechatHoldPreemptEnabled = wechatHoldPreemptEnabled
        self.onboardingCompleted = onboardingCompleted
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
            forKey: .navigationExcludedBundleIDs
        ) ?? container.decodeIfPresent(
            [String].self,
            forKey: .excludedBundleIDs
        ) ?? AppSettings.defaultNavigationExcludedBundleIDs
        if decodedSchemaVersion < AppSettings.currentSchemaVersion {
            for bundleIdentifier in AppSettings.defaultNavigationExcludedBundleIDs
                where !decodedExcludedBundleIDs.contains(bundleIdentifier)
            {
                decodedExcludedBundleIDs.append(bundleIdentifier)
            }
        }
        if decodedSchemaVersion < 8 {
            decodedExcludedBundleIDs.removeAll { identifier in
                AppSettings.doubaoClientBundleIDs.contains(identifier)
            }
        }
        if !decodedExcludedBundleIDs.contains(AppSettings.bundleIdentifier) {
            decodedExcludedBundleIDs.append(AppSettings.bundleIdentifier)
        }
        excludedBundleIDs = decodedExcludedBundleIDs
        var decodedHoldExcludedBundleIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .holdExcludedBundleIDs
        ) ?? AppSettings.defaultHoldExcludedBundleIDs
        if !decodedHoldExcludedBundleIDs.contains(AppSettings.bundleIdentifier) {
            decodedHoldExcludedBundleIDs.append(AppSettings.bundleIdentifier)
        }
        holdExcludedBundleIDs = decodedHoldExcludedBundleIDs
        var decodedMacroRules = try container.decodeIfPresent(
            [MacroRule].self,
            forKey: .macroRules
        ) ?? AppSettings.defaultMacroRules
        if decodedSchemaVersion < 9 {
            for defaultRule in AppSettings.defaultMacroRules {
                if !decodedMacroRules.contains(where: { $0.source == defaultRule.source }) {
                    decodedMacroRules.append(defaultRule)
                }
            }
        }
        macroRules = decodedMacroRules
        if decodedSchemaVersion < 10 {
            if holdMouseBinding.button <= 1 {
                holdMouseBinding = AppSettings.defaultHoldMouseBinding
            }
        }
        launchAtLogin = try container.decodeIfPresent(
            Bool.self,
            forKey: .launchAtLogin
        ) ?? true
        overlayEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .overlayEnabled
        ) ?? true
        wechatHoldPreemptEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .wechatHoldPreemptEnabled
        ) ?? true
        onboardingCompleted = try container.decodeIfPresent(
            Bool.self,
            forKey: .onboardingCompleted
        ) ?? false
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
        try container.encode(
            excludedBundleIDs,
            forKey: .navigationExcludedBundleIDs
        )
        try container.encode(
            holdExcludedBundleIDs,
            forKey: .holdExcludedBundleIDs
        )
        try container.encode(macroRules, forKey: .macroRules)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(overlayEnabled, forKey: .overlayEnabled)
        try container.encode(
            wechatHoldPreemptEnabled,
            forKey: .wechatHoldPreemptEnabled
        )
        try container.encode(onboardingCompleted, forKey: .onboardingCompleted)
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
        isNavigationExcluded(bundleIdentifier: bundleIdentifier)
    }

    public func isNavigationExcluded(bundleIdentifier: String?) -> Bool {
        BundleExclusion.matches(bundleIdentifier, in: excludedBundleIDs)
    }

    public func isHoldExcluded(bundleIdentifier: String?) -> Bool {
        BundleExclusion.matches(bundleIdentifier, in: holdExcludedBundleIDs)
    }

    public static let defaultNavigationExcludedBundleIDs = [
        "com.apple.finder",
        "com.apple.Safari",
        "com.apple.Preview",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        "company.thebrowser.Browser",
        "com.stablyai.orca",
        "com.citrolabs.ego",
        "com.citrolabs.ego.lite",
        "com.brave.Browser",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        AppSettings.bundleIdentifier,
    ]

    public static let defaultHoldExcludedBundleIDs = [
        AppSettings.bundleIdentifier,
    ]

    public static let defaultExcludedBundleIDs = defaultNavigationExcludedBundleIDs

    public static let defaultToggleMouseBinding = MouseBinding(button: 4)
    public static let defaultHoldMouseBinding = MouseBinding(button: -1)
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
        MacroRule(source: "approve", replacement: "/approve"),
        MacroRule(source: "Approve", replacement: "/approve"),
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
        case navigationExcludedBundleIDs
        case holdExcludedBundleIDs
        case macroRules
        case launchAtLogin
        case overlayEnabled
        case wechatHoldPreemptEnabled
        case onboardingCompleted
    }
}
