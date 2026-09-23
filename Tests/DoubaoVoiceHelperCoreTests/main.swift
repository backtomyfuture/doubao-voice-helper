import Foundation
import DoubaoVoiceHelperCore

private enum TestFailure: Error {
    case assertion(String)
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw TestFailure.assertion(message)
    }
}

private func expectEqual<T: Equatable>(
    _ lhs: @autoclosure () -> T,
    _ rhs: @autoclosure () -> T,
    _ message: String
) throws {
    let left = lhs()
    let right = rhs()
    guard left == right else {
        throw TestFailure.assertion(
            "\(message): \(String(describing: left)) != \(String(describing: right))"
        )
    }
}

private func testLongestRuleWins() throws {
    let result = MacroEngine().apply(
        "请执行斜杠批准",
        rules: [
            MacroRule(source: "斜杠", replacement: "/"),
            MacroRule(source: "斜杠批准", replacement: "/approve"),
        ]
    )
    try expectEqual(result.output, "请执行/approve", "longest rule")
    try expectEqual(result.matchCount, 1, "longest rule count")
}

private func testReplacementIsNotRecursive() throws {
    let result = MacroEngine().apply(
        "斜杠批准",
        rules: [
            MacroRule(source: "斜杠批准", replacement: "斜杠"),
            MacroRule(source: "斜杠", replacement: "/"),
        ]
    )
    try expectEqual(result.output, "斜杠", "non-recursive replacement")
    try expectEqual(result.matchCount, 1, "non-recursive count")
}

private func testUnicodeAndMultipleMatches() throws {
    let result = MacroEngine().apply(
        "斜杠任务，然后斜杠",
        rules: [
            MacroRule(source: "斜杠任务", replacement: "/missions"),
            MacroRule(source: "斜杠", replacement: "/"),
        ]
    )
    try expectEqual(result.output, "/missions，然后/", "unicode replacement")
    try expectEqual(result.matchCount, 2, "multiple replacement count")
}

private func testDisabledRulesAreIgnored() throws {
    let result = MacroEngine().apply(
        "斜杠",
        rules: [
            MacroRule(
                source: "斜杠",
                replacement: "/",
                isEnabled: false
            ),
        ]
    )
    try expectEqual(result.output, "斜杠", "disabled rule")
    try expectEqual(result.matchCount, 0, "disabled rule count")
}

private func testNormalizedMatchWithPunctuation() throws {
    let result = MacroEngine().apply(
        "斜杠，批准",
        rules: [
            MacroRule(source: "斜杠批准", replacement: "/approve"),
            MacroRule(source: "斜杠", replacement: "/"),
        ]
    )
    try expectEqual(result.output, "/approve", "normalized match with comma")
    try expectEqual(result.matchCount, 1, "normalized match count")
}

private func testNormalizedMatchWithSpaces() throws {
    let result = MacroEngine().apply(
        "斜杠 批准",
        rules: [
            MacroRule(source: "斜杠批准", replacement: "/approve"),
            MacroRule(source: "斜杠", replacement: "/"),
        ]
    )
    try expectEqual(result.output, "/approve", "normalized match with space")
    try expectEqual(result.matchCount, 1, "normalized match with space count")
}

private func testExactMatchStillPreferred() throws {
    let result = MacroEngine().apply(
        "斜杠批准",
        rules: [
            MacroRule(source: "斜杠批准", replacement: "/approve"),
            MacroRule(source: "斜杠", replacement: "/"),
        ]
    )
    try expectEqual(result.output, "/approve", "exact match preferred")
    try expectEqual(result.matchCount, 1, "exact match count")
}

private func testRuleValidation() throws {
    let empty = MacroRule(source: "", replacement: "/")
    let duplicate = MacroRule(source: "斜杠", replacement: "//")
    let original = MacroRule(source: "斜杠", replacement: "/")
    let issues = MacroEngine().validate([empty, original, duplicate])

    try expect(
        issues.contains { $0.kind == .emptySource && $0.ruleID == empty.id },
        "empty source validation"
    )
    try expect(
        issues.contains {
            $0.kind == .duplicateSource && $0.ruleID == duplicate.id
        },
        "duplicate source validation"
    )
}

private func testHoldShortcutPressesOptionThenControl() throws {
    let down = ShortcutStroke.keyDownEvents(for: AppSettings.defaultHoldShortcut)
    try expectEqual(down.map(\.keyCode), [58, 59], "hold keyDown presses left option then left control")
    try expectEqual(
        down[0].modifiers,
        [.option],
        "option is down before control"
    )
    try expectEqual(
        down[1].modifiers,
        [.option, .control],
        "both modifiers are down for control keyDown"
    )
    try expect(
        down[1].flagBits & ShortcutStroke.leftOptionDeviceFlag != 0,
        "hold chord includes left option device bit"
    )
    try expect(
        down[1].flagBits & ShortcutStroke.leftControlDeviceFlag != 0,
        "hold chord includes left control device bit"
    )

    let up = ShortcutStroke.keyUpEvents(for: AppSettings.defaultHoldShortcut)
    try expectEqual(up.map(\.keyCode), [59, 58], "hold keyUp releases control then option")
    try expectEqual(up[0].modifiers, [.option], "option stays down while control releases")
    try expectEqual(up[1].modifiers, [], "all modifiers released")
}

private func testRightModifierKeysArePreserved() throws {
    let rightCommand = KeyboardShortcut(physicalKeyCodes: [54])
    try expectEqual(rightCommand.displayName, "右 Command", "right command display")
    try expectEqual(
        ShortcutStroke.resolvedKeyCodes(for: rightCommand),
        [54],
        "right command key code"
    )

    let rightOption = KeyboardShortcut(physicalKeyCodes: [61])
    try expectEqual(rightOption.displayName, "右 Option", "right option display")

    let rightChord = KeyboardShortcut(physicalKeyCodes: [54, 61])
    try expectEqual(
        rightChord.displayName,
        "右 Command + 右 Option",
        "right chord display"
    )
    let down = ShortcutStroke.keyDownEvents(for: rightChord)
    try expectEqual(down.map(\.keyCode), [54, 61], "right chord press order")
    try expectEqual(down[0].modifiers, [.command], "right command flags first")
    try expectEqual(
        down[1].modifiers,
        [.command, .option],
        "both flags after right option"
    )
    try expect(
        down[1].flagBits & ShortcutStroke.rightCommandDeviceFlag != 0,
        "right chord includes right command device bit"
    )
    try expect(
        down[1].flagBits & ShortcutStroke.rightOptionDeviceFlag != 0,
        "right chord includes right option device bit"
    )
}

private func testLeftCommandOptionDeviceBits() throws {
    let shortcut = KeyboardShortcut(physicalKeyCodes: [55, 58])
    let down = ShortcutStroke.keyDownEvents(for: shortcut)
    try expectEqual(down.map(\.keyCode), [55, 58], "left command then left option")
    let bits = down[1].flagBits
    try expect(bits & ShortcutStroke.leftCommandDeviceFlag != 0, "left command device bit")
    try expect(bits & ShortcutStroke.leftOptionDeviceFlag != 0, "left option device bit")
    try expect(bits & ShortcutStroke.genericFlag(for: .command) != 0, "generic command flag")
    try expect(bits & ShortcutStroke.genericFlag(for: .option) != 0, "generic option flag")
    try expect(bits & ShortcutStroke.rightCommandDeviceFlag == 0, "not right command")
}

private func testToggleShortcutOnlyPressesControl() throws {
    let down = ShortcutStroke.keyDownEvents(for: AppSettings.defaultToggleShortcut)
    try expectEqual(down.map(\.keyCode), [59], "toggle only presses left control")
    let up = ShortcutStroke.keyUpEvents(for: AppSettings.defaultToggleShortcut)
    try expectEqual(up.map(\.keyCode), [59], "toggle only releases left control")
}

private func testShortcutDisplayName() throws {
    try expectEqual(
        KeyboardShortcut.doubaoDefault.displayName,
        "左 Control",
        "default shortcut display name"
    )
    try expectEqual(
        AppSettings.defaultHoldShortcut.displayName,
        "左 Option + 左 Control",
        "hold shortcut display name"
    )
}

private func testLegacySettingsMigration() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let legacy = """
    {
      "schemaVersion": 1,
      "mouseBinding": { "button": 0 },
      "doubaoShortcut": {
        "keyCode": 59,
        "modifiers": ["control"]
      },
      "excludedBundleIDs": [],
      "macroRules": [],
      "launchAtLogin": false,
      "overlayEnabled": true
    }
    """
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data(legacy.utf8).write(to: fileURL)

    let settings = SettingsRepository(fileURL: fileURL).load()

    try expectEqual(settings.toggleMouseBinding.button, 4, "legacy toggle button")
    try expectEqual(settings.holdMouseBinding.button, -1, "legacy hold button migrated to unbound")
    try expectEqual(settings.enterMouseBinding.button, 3, "legacy enter button")
    try expectEqual(
        settings.toggleShortcut,
        KeyboardShortcut(keyCode: 59, modifiers: [.control]),
        "legacy toggle shortcut"
    )
    try expectEqual(
        settings.holdShortcut,
        AppSettings.defaultHoldShortcut,
        "new hold shortcut default"
    )
    try expectEqual(
        settings.enterShortcut,
        AppSettings.defaultEnterShortcut,
        "new enter shortcut default"
    )
    try expect(
        !settings.excludedBundleIDs.contains("com.bot.pc.doubao"),
        "legacy migration removes doubao client from navigation exclude"
    )
    try expectEqual(
        settings.holdExcludedBundleIDs,
        [AppSettings.bundleIdentifier],
        "hold exclude defaults to this app"
    )
    try expectEqual(
        settings.keystrokeFallbackBundleIDs,
        AppSettings.defaultKeystrokeFallbackBundleIDs,
        "keystroke fallback defaults"
    )
    try expectEqual(settings.onboardingCompleted, false, "onboarding not completed")
}

private func testIntermediateShortcutMigration() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let settings = """
    {
      "schemaVersion": 2,
      "toggleMouseBinding": { "button": 4 },
      "holdMouseBinding": { "button": 0 },
      "enterMouseBinding": { "button": 3 },
      "toggleShortcut": {
        "keyCode": 59,
        "modifiers": ["control", "option", "command"]
      },
      "holdShortcut": {
        "keyCode": 59,
        "modifiers": ["control"]
      },
      "enterShortcut": { "keyCode": 36, "modifiers": [] },
      "excludedBundleIDs": [],
      "macroRules": [],
      "launchAtLogin": false,
      "overlayEnabled": true
    }
    """
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data(settings.utf8).write(to: fileURL)

    let loaded = SettingsRepository(fileURL: fileURL).load()

    try expectEqual(
        loaded.toggleShortcut,
        AppSettings.defaultToggleShortcut,
        "intermediate toggle shortcut repair"
    )
    try expectEqual(
        loaded.holdShortcut,
        AppSettings.defaultHoldShortcut,
        "intermediate hold shortcut repair"
    )
}

private func testBrokenSchemaThreeHoldShortcutMigration() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let settings = """
    {
      "schemaVersion": 3,
      "toggleMouseBinding": { "button": 4 },
      "holdMouseBinding": { "button": 0 },
      "enterMouseBinding": { "button": 3 },
      "toggleShortcut": {
        "keyCode": 59,
        "modifiers": ["control"]
      },
      "holdShortcut": {
        "keyCode": 58,
        "modifiers": ["option", "command"]
      },
      "enterShortcut": { "keyCode": 36, "modifiers": [] },
      "excludedBundleIDs": [],
      "macroRules": [],
      "launchAtLogin": false,
      "overlayEnabled": true
    }
    """
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data(settings.utf8).write(to: fileURL)

    let loaded = SettingsRepository(fileURL: fileURL).load()

    try expectEqual(
        loaded.holdShortcut,
        AppSettings.defaultHoldShortcut,
        "schema three hold shortcut repair"
    )
}

private func testSchemaFourControlOnlyHoldMigration() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let settings = """
    {
      "schemaVersion": 4,
      "toggleMouseBinding": { "button": 4 },
      "holdMouseBinding": { "button": 0 },
      "enterMouseBinding": { "button": 3 },
      "toggleShortcut": {
        "keyCode": 59,
        "modifiers": ["control"]
      },
      "holdShortcut": {
        "keyCode": 59,
        "modifiers": ["control"]
      },
      "enterShortcut": { "keyCode": 36, "modifiers": [] },
      "excludedBundleIDs": [],
      "macroRules": [],
      "launchAtLogin": false,
      "overlayEnabled": true
    }
    """
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data(settings.utf8).write(to: fileURL)

    let loaded = SettingsRepository(fileURL: fileURL).load()

    try expectEqual(
        loaded.holdShortcut,
        AppSettings.defaultHoldShortcut,
        "schema four hold shortcut repair"
    )
}

private func testSchemaFiveCommandOnlyHoldMigration() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let settings = """
    {
      "schemaVersion": 5,
      "toggleMouseBinding": { "button": 4 },
      "holdMouseBinding": { "button": 0 },
      "enterMouseBinding": { "button": 3 },
      "toggleShortcut": {
        "keyCode": 59,
        "modifiers": ["control"]
      },
      "holdShortcut": {
        "keyCode": 55,
        "modifiers": ["command"]
      },
      "enterShortcut": { "keyCode": 36, "modifiers": [] },
      "excludedBundleIDs": [],
      "macroRules": [],
      "launchAtLogin": false,
      "overlayEnabled": true
    }
    """
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data(settings.utf8).write(to: fileURL)

    let loaded = SettingsRepository(fileURL: fileURL).load()

    try expectEqual(
        loaded.holdShortcut,
        AppSettings.defaultHoldShortcut,
        "schema five hold shortcut repair"
    )
}

private func testSettingsRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let repository = SettingsRepository(fileURL: fileURL)
    let settings = AppSettings(
        toggleMouseBinding: MouseBinding(button: 7),
        holdMouseBinding: MouseBinding(button: 0),
        enterMouseBinding: MouseBinding(button: 3),
        toggleShortcut: KeyboardShortcut(
            keyCode: 12,
            modifiers: [.command, .shift]
        ),
        holdShortcut: KeyboardShortcut(
            keyCode: 59,
            modifiers: [.control, .option, .command]
        ),
        enterShortcut: KeyboardShortcut(keyCode: 36),
        excludedBundleIDs: [
            "example.app",
            AppSettings.bundleIdentifier,
        ],
        holdExcludedBundleIDs: [AppSettings.bundleIdentifier],
        macroRules: [
            MacroRule(source: "斜杠", replacement: "/"),
        ],
        keystrokeFallbackBundleIDs: ["example.editor"],
        launchAtLogin: false,
        overlayEnabled: false,
        onboardingCompleted: true
    )

    try repository.save(settings)
    try expectEqual(repository.load(), settings, "settings round trip")
}

private func testCorruptSettingsBackup() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    let fileURL = directory.appendingPathComponent("settings.json")
    try Data("{not-json".utf8).write(to: fileURL)
    let repository = SettingsRepository(fileURL: fileURL)

    try expectEqual(
        repository.load(),
        AppSettings(),
        "corrupt settings defaults"
    )
    let files = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    try expectEqual(files.count, 1, "corrupt settings backup count")
    try expect(
        files[0].lastPathComponent.hasPrefix("settings.corrupt-"),
        "corrupt settings backup name"
    )
}

private func testWeChatInputRegion() throws {
    let window = CGRect(x: 100, y: 50, width: 900, height: 700)
    let region = WeChatInputRegion.inputRegion(inWindow: window)
    try expect(region.width > 480, "wechat composer uses full chat pane width")
    try expect(
        WeChatInputRegion.contains(
            CGPoint(x: 100 + 300 + 10, y: 50 + 700 * 0.78 + 10),
            inWindow: window
        ),
        "point in wechat input region"
    )
    try expect(
        WeChatInputRegion.isSidebar(CGPoint(x: 110, y: 60), inWindow: window),
        "sidebar is detected"
    )
    try expect(
        !WeChatInputRegion.contains(
            CGPoint(x: 110, y: 60),
            inWindow: window
        ),
        "sidebar is not wechat input"
    )
    try expect(
        !WeChatInputRegion.contains(
            CGPoint(x: 500, y: window.maxY - 10),
            inWindow: window
        ),
        "toolbar is not wechat input"
    )
}

private func testHoldCancelArmAndDisarm() throws {
    let origin = CGPoint(x: 100, y: 100)
    let idle = HoldCancelState.from(
        origin: origin,
        cursor: CGPoint(x: 105, y: 105),
        previouslyArmed: false
    )
    try expect(!idle.armed, "small move is not armed")
    let armed = HoldCancelState.from(
        origin: origin,
        cursor: CGPoint(x: 100, y: 180),
        previouslyArmed: false
    )
    try expect(armed.armed, "70pt arms cancel")
    try expect(armed.showsCancelHint, "armed shows hint")
    let stillArmed = HoldCancelState.from(
        origin: origin,
        cursor: CGPoint(x: 100, y: 155),
        previouslyArmed: true
    )
    try expect(stillArmed.armed, "between 45 and 70 stays armed")
    let disarmed = HoldCancelState.from(
        origin: origin,
        cursor: CGPoint(x: 100, y: 130),
        previouslyArmed: true
    )
    try expect(!disarmed.armed, "inside 45pt disarms")
}

private func testSelectionRestorePolicy() throws {
    try expect(
        !SelectionRestorePolicy.shouldCapture(
            bundleIdentifier: WeChatInputRegion.bundleID
        ),
        "wechat skips selection capture"
    )
    try expect(
        SelectionRestorePolicy.shouldCapture(
            bundleIdentifier: "com.google.Chrome"
        ),
        "chrome captures selection"
    )

    try expect(
        SelectionRestorePolicy.isReplaceable(
            range: NSRange(location: 2, length: 4),
            textLength: 10
        ),
        "non-empty in-bounds range is replaceable"
    )
    try expect(
        !SelectionRestorePolicy.isReplaceable(
            range: NSRange(location: 2, length: 0),
            textLength: 10
        ),
        "caret is not replaceable"
    )
    try expect(
        !SelectionRestorePolicy.isReplaceable(
            range: NSRange(location: 8, length: 4),
            textLength: 10
        ),
        "out-of-bounds range is not replaceable"
    )
}

private func testHoldStartEvaluator() throws {
    try expectEqual(
        HoldStartEvaluator.decision(
            bundleIdentifier: WeChatInputRegion.bundleID,
            wechatContainsPoint: true,
            hitRole: nil,
            ancestorRoles: []
        ),
        .start,
        "wechat input starts"
    )
    try expectEqual(
        HoldStartEvaluator.decision(
            bundleIdentifier: WeChatInputRegion.bundleID,
            wechatContainsPoint: false,
            hitRole: "AXTextField",
            ancestorRoles: []
        ),
        .veto,
        "wechat outside input vetoes"
    )
    try expectEqual(
        HoldStartEvaluator.decision(
            bundleIdentifier: WeChatInputRegion.bundleID,
            wechatContainsPoint: nil,
            hitRole: nil,
            ancestorRoles: []
        ),
        .start,
        "wechat unknown starts"
    )
    try expectEqual(
        HoldStartEvaluator.decision(
            bundleIdentifier: "com.google.Chrome",
            wechatContainsPoint: nil,
            hitRole: "AXLink",
            ancestorRoles: []
        ),
        .veto,
        "link vetoes"
    )
    try expectEqual(
        HoldStartEvaluator.decision(
            bundleIdentifier: "com.google.Chrome",
            wechatContainsPoint: nil,
            hitRole: "AXStaticText",
            ancestorRoles: ["AXLink"]
        ),
        .veto,
        "link ancestor vetoes"
    )
    try expectEqual(
        HoldStartEvaluator.decision(
            bundleIdentifier: "com.apple.Terminal",
            wechatContainsPoint: nil,
            hitRole: "AXWindow",
            ancestorRoles: []
        ),
        .veto,
        "window titlebar vetoes"
    )
    try expectEqual(
        HoldStartEvaluator.decision(
            bundleIdentifier: "com.apple.Terminal",
            wechatContainsPoint: nil,
            hitRole: "AXToolbar",
            ancestorRoles: []
        ),
        .veto,
        "toolbar vetoes"
    )
    try expectEqual(
        HoldStartEvaluator.decision(
            bundleIdentifier: "com.apple.Terminal",
            wechatContainsPoint: nil,
            hitRole: nil,
            ancestorRoles: []
        ),
        .start,
        "unknown non-wechat starts"
    )
}

private func testNavigationExcludeDoesNotIncludeDoubao() throws {
    let settings = AppSettings()
    try expect(
        !settings.isNavigationExcluded(bundleIdentifier: "com.bot.pc.doubao"),
        "doubao client is not navigation-excluded"
    )
    try expect(
        settings.isNavigationExcluded(bundleIdentifier: "com.google.Chrome"),
        "chrome is navigation-excluded"
    )
    try expect(
        !settings.isHoldExcluded(bundleIdentifier: "com.google.Chrome"),
        "chrome is not hold-excluded"
    )
    try expect(
        settings.isHoldExcluded(bundleIdentifier: AppSettings.bundleIdentifier),
        "this app is hold-excluded"
    )
}

private func testSchemaEightStripsDoubaoExclude() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let settings = """
    {
      "schemaVersion": 7,
      "toggleMouseBinding": { "button": 4 },
      "holdMouseBinding": { "button": 0 },
      "enterMouseBinding": { "button": 3 },
      "toggleShortcut": { "keyCode": 59, "modifiers": ["control"] },
      "holdShortcut": { "keyCode": 59, "modifiers": ["control", "option"] },
      "enterShortcut": { "keyCode": 36, "modifiers": [] },
      "excludedBundleIDs": [
        "com.google.Chrome",
        "com.bot.pc.doubao",
        "com.jarod.doubao-voice-helper"
      ],
      "macroRules": [],
      "launchAtLogin": false,
      "overlayEnabled": true
    }
    """
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data(settings.utf8).write(to: fileURL)
    let loaded = SettingsRepository(fileURL: fileURL).load()
    try expect(
        !loaded.excludedBundleIDs.contains("com.bot.pc.doubao"),
        "schema 8 strips doubao exclude"
    )
    try expectEqual(loaded.schemaVersion, AppSettings.currentSchemaVersion, "schema bumped")
}

private func testSchemaNineMacroRulesMigration() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let settings = """
    {
      "schemaVersion": 8,
      "toggleMouseBinding": { "button": 4 },
      "holdMouseBinding": { "button": 0 },
      "enterMouseBinding": { "button": 3 },
      "toggleShortcut": { "keyCode": 59, "modifiers": ["control"] },
      "holdShortcut": { "keyCode": 59, "modifiers": ["control", "option"] },
      "enterShortcut": { "keyCode": 36, "modifiers": [] },
      "excludedBundleIDs": ["com.jarod.doubao-voice-helper"],
      "macroRules": [
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "source": "旧规则",
          "replacement": "新文本",
          "isEnabled": true
        }
      ],
      "launchAtLogin": false,
      "overlayEnabled": true
    }
    """
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data(settings.utf8).write(to: fileURL)
    let loaded = SettingsRepository(fileURL: fileURL).load()
    try expectEqual(loaded.schemaVersion, AppSettings.currentSchemaVersion, "schema bumped")
    try expect(
        loaded.macroRules.contains(where: { $0.source == "斜杠批准" && $0.replacement == "/approve" }),
        "schema 9 adds default rules"
    )
    try expect(
        !loaded.macroRules.contains(where: { $0.source == "approve" && $0.isEnabled }),
        "bare approve is no longer a default"
    )
    try expect(
        loaded.macroRules.contains(where: { $0.source == "旧规则" }),
        "preserves existing user rules"
    )
}

private func testSchemaTenHoldButtonMigration() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let settings = """
    {
      "schemaVersion": 9,
      "toggleMouseBinding": { "button": 4 },
      "holdMouseBinding": { "button": 0 },
      "enterMouseBinding": { "button": 3 },
      "toggleShortcut": { "keyCode": 59, "modifiers": ["control"] },
      "holdShortcut": { "keyCode": 59, "modifiers": ["control", "option"] },
      "enterShortcut": { "keyCode": 36, "modifiers": [] },
      "excludedBundleIDs": ["com.jarod.doubao-voice-helper"],
      "launchAtLogin": false,
      "overlayEnabled": true
    }
    """
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try Data(settings.utf8).write(to: fileURL)
    let loaded = SettingsRepository(fileURL: fileURL).load()
    try expectEqual(loaded.schemaVersion, AppSettings.currentSchemaVersion, "schema bumped")
    try expectEqual(loaded.holdMouseBinding.button, -1, "schema 10 unbinds button 0")
}

private func testSchemaElevenDisablesBareApproveRules() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let settings = """
    {
      "schemaVersion": 10,
      "toggleMouseBinding": { "button": 4 },
      "holdMouseBinding": { "button": -1 },
      "enterMouseBinding": { "button": 3 },
      "excludedBundleIDs": ["com.jarod.doubao-voice-helper"],
      "macroRules": [
        { "id": "11111111-1111-1111-1111-111111111111", "source": "approve", "replacement": "/approve", "isEnabled": true },
        { "id": "22222222-2222-2222-2222-222222222222", "source": "Approve", "replacement": "/approve", "isEnabled": true },
        { "id": "33333333-3333-3333-3333-333333333333", "source": "approve", "replacement": "OK", "isEnabled": true },
        { "id": "44444444-4444-4444-4444-444444444444", "source": "斜杠", "replacement": "/", "isEnabled": true }
      ],
      "wechatHoldPreemptEnabled": true
    }
    """
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(settings.utf8).write(to: fileURL)
    let loaded = SettingsRepository(fileURL: fileURL).load()
    let enabled = Dictionary(
        uniqueKeysWithValues: loaded.macroRules.map { ($0.id.uuidString.prefix(1), $0.isEnabled) }
    )
    try expectEqual(loaded.macroRules.count, 4, "rules are kept, not deleted")
    try expectEqual(enabled["1"], false, "approve → /approve disabled")
    try expectEqual(enabled["2"], false, "Approve → /approve disabled")
    try expectEqual(enabled["3"], true, "user-customised approve rule untouched")
    try expectEqual(enabled["4"], true, "other rules untouched")
    try expectEqual(
        loaded.keystrokeFallbackBundleIDs,
        AppSettings.defaultKeystrokeFallbackBundleIDs,
        "keystroke fallback list defaults on upgrade"
    )
}

// MARK: - Macro engine semantics

private func testMacroAliases() throws {
    let rules = [MacroRule(source: "斜杠 | 写杠|鞋杠", replacement: "/")]
    try expectEqual(MacroEngine().apply("写杠", rules: rules).output, "/", "alias 1")
    try expectEqual(MacroEngine().apply("输入鞋杠吧", rules: rules).output, "输入/吧", "alias 2")
    try expectEqual(MacroEngine().apply("斜杠", rules: rules).output, "/", "primary source")
}

private func testWholeUtteranceDropsTrailingPunctuation() throws {
    let rules = [
        MacroRule(source: "斜杠批准", replacement: "/approve"),
        MacroRule(source: "斜杠任务", replacement: "/missions"),
    ]
    try expectEqual(MacroEngine().apply("斜杠批准。", rules: rules).output, "/approve", "trailing 。")
    try expectEqual(MacroEngine().apply(" 斜杠批准！", rules: rules).output, "/approve", "leading space + ！")
    try expectEqual(MacroEngine().apply("斜杠批准?", rules: rules).output, "/approve", "half-width ?")
    try expectEqual(
        MacroEngine().apply("斜杠任务，斜杠批准。", rules: rules).output,
        "/missions/approve",
        "multiple commands"
    )
}

private func testPartialUtteranceKeepsPunctuation() throws {
    let result = MacroEngine().apply(
        "请输入斜杠批准。",
        rules: [MacroRule(source: "斜杠批准", replacement: "/approve")]
    )
    try expectEqual(result.output, "请输入/approve。", "sentence punctuation preserved")
    try expectEqual(result.matchCount, 1, "partial count")
}

private func testEnglishWordsAreNotRewrittenByDefault() throws {
    let result = MacroEngine().apply("I approve this.", rules: AppSettings.defaultMacroRules)
    try expectEqual(result.output, "I approve this.", "default rules leave English alone")
    try expectEqual(result.changed, false, "no default match")
}

private func testValidationDetectsAliasDuplicates() throws {
    let first = MacroRule(source: "斜杠|写杠", replacement: "/")
    let second = MacroRule(source: "写，杠", replacement: "//")
    let empty = MacroRule(source: " | ", replacement: "x")
    let issues = MacroEngine().validate([first, second, empty])
    try expect(
        issues.contains { $0.kind == .duplicateSource && $0.ruleID == second.id },
        "normalized alias duplicate"
    )
    try expect(
        issues.contains { $0.kind == .emptySource && $0.ruleID == empty.id },
        "only separators is empty"
    )
    try expect(!issues.contains { $0.ruleID == first.id }, "first rule is valid")
}

// MARK: - Insertion diff

private func testInsertionDiffExactMiddle() throws {
    let insertion = try TextInsertionDiff.compute(
        original: "前缀后缀",
        selectedRange: NSRange(location: 2, length: 0),
        current: "前缀斜杠批准后缀"
    )
    try expectEqual(insertion.text, "斜杠批准", "middle insertion text")
    try expectEqual(insertion.range, NSRange(location: 2, length: 4), "middle insertion range")
    try expectEqual(insertion.kind, .exact, "middle insertion kind")
}

private func testInsertionDiffReplacesSelection() throws {
    let insertion = try TextInsertionDiff.compute(
        original: "hello world",
        selectedRange: NSRange(location: 6, length: 5),
        current: "hello 斜杠"
    )
    try expectEqual(insertion.text, "斜杠", "selection replaced text")
    try expectEqual(insertion.range, NSRange(location: 6, length: 2), "selection replaced range")
}

private func testInsertionDiffUsesUTF16Offsets() throws {
    let insertion = try TextInsertionDiff.compute(
        original: "😀ab",
        selectedRange: NSRange(location: 4, length: 0),
        current: "😀ab斜杠"
    )
    try expectEqual(insertion.range, NSRange(location: 4, length: 2), "emoji prefix counted as 2 UTF-16 units")
    try expectEqual(insertion.kind, .exact, "emoji exact kind")
}

private func testInsertionDiffCommonPrefixUTF16() throws {
    // Caret was reported at the start, but the buffer changed after an emoji.
    let insertion = try TextInsertionDiff.compute(
        original: "😀 $ ",
        selectedRange: NSRange(location: 0, length: 0),
        current: "😀 $ ls斜杠"
    )
    try expectEqual(insertion.kind, .appended, "buffer append kind")
    try expectEqual(insertion.range.location, 5, "append location in UTF-16")

    let lcp = try TextInsertionDiff.compute(
        original: "😀 $ old",
        selectedRange: NSRange(location: 0, length: 0),
        current: "😀 $ new text"
    )
    try expectEqual(lcp.kind, .commonPrefix, "common prefix kind")
    try expectEqual(lcp.range.location, 5, "common prefix location in UTF-16, not characters")
    try expectEqual(lcp.text, "new text", "common prefix text")
}

private func testInsertionDiffNoInsertion() throws {
    do {
        _ = try TextInsertionDiff.compute(
            original: "abc",
            selectedRange: NSRange(location: 3, length: 0),
            current: "abc"
        )
        throw TestFailure.assertion("expected noInsertion")
    } catch TextInsertionDiff.Failure.noInsertion {
    }
    do {
        _ = try TextInsertionDiff.compute(
            original: "abc",
            selectedRange: NSRange(location: 9, length: 0),
            current: "abcd"
        )
        throw TestFailure.assertion("expected notUnique for out-of-range anchor")
    } catch TextInsertionDiff.Failure.notUnique {
    }
}

private func testKeystrokeChunksRespectLimit() throws {
    let text = String(repeating: "斜", count: 25) + "😀😀"
    let chunks = KeystrokeTyper.chunks(of: text)
    try expectEqual(chunks.joined(), text, "chunks preserve text")
    try expect(
        chunks.allSatisfy { $0.utf16.count <= KeystrokeTyper.maxUTF16PerEvent },
        "chunks within UTF-16 limit"
    )
    try expectEqual(chunks.count, 2, "20 units, then 5 units + two surrogate pairs")
    try expect(chunks[1].hasSuffix("😀😀"), "emoji kept whole")
}

// MARK: - Terminal insertion diff

private func terminalFailure(
    original: String,
    current: String,
    caret: Int? = nil
) -> TextInsertionDiff.Failure? {
    do {
        _ = try TerminalInsertionDiff.compute(original: original, current: current, caretUTF16: caret)
        return nil
    } catch let failure as TextInsertionDiff.Failure {
        return failure
    } catch {
        return nil
    }
}

private func testTerminalShellPrompt() throws {
    let insertion = try TerminalInsertionDiff.compute(
        original: "Last login: today\n~ % ",
        current: "Last login: today\n~ % 斜杠批准",
        caretUTF16: nil
    )
    try expectEqual(insertion.text, "斜杠批准", "shell prompt text")
    try expectEqual(insertion.kind, .terminalLine, "terminal kind")
    try expectEqual(insertion.range.location, 22, "shell prompt location")

    let typed = try TerminalInsertionDiff.compute(
        original: "$ git commit -m ",
        current: "$ git commit -m 斜杠",
        caretUTF16: nil
    )
    try expectEqual(typed.text, "斜杠", "insertion after typed text")
}

private func testTerminalTUIPaddingIsConsumed() throws {
    let insertion = try TerminalInsertionDiff.compute(
        original: "│ > abc      │\n╰────────────╯\n  ? for shortcuts",
        current: "│ > abc斜杠    │\n╰────────────╯\n  ? for shortcuts",
        caretUTF16: nil
    )
    try expectEqual(insertion.text, "斜杠", "TUI box insertion")
}

private func testTerminalRejectsOtherChanges() throws {
    try expectEqual(
        terminalFailure(original: "$ ls\n", current: "$ ls\nfile.txt\n$ 斜杠"),
        .notUnique,
        "program output rejected"
    )
    try expectEqual(
        terminalFailure(original: "$ ", current: "$ 斜杠\n"),
        .notUnique,
        "newline in insertion rejected"
    )
    try expectEqual(
        terminalFailure(original: "│ > Try \"fix it\"   │", current: "│ > 斜杠批准         │"),
        .notUnique,
        "placeholder replacement rejected"
    )
    try expectEqual(
        terminalFailure(original: "10:01 $ ", current: "10:02 $ 斜杠"),
        .notUnique,
        "change elsewhere on screen rejected"
    )
    try expectEqual(
        terminalFailure(original: "$ abc", current: "$ abc"),
        .noInsertion,
        "no change"
    )
}

private func testTerminalCaretDecidesTrailingSpace() throws {
    let withoutCaret = try TerminalInsertionDiff.compute(
        original: "$ \n",
        current: "$ 斜杠 \n",
        caretUTF16: nil
    )
    try expectEqual(withoutCaret.text, "斜杠 ", "pure insertion keeps inserted trailing space")

    let caretBeforeSpace = try TerminalInsertionDiff.compute(
        original: "$ \n",
        current: "$ 斜杠 \n",
        caretUTF16: 4
    )
    try expectEqual(caretBeforeSpace.text, "斜杠", "caret excludes padding after it")

    try expectEqual(
        terminalFailure(original: "$ \n", current: "$ 斜杠 \n", caret: 3),
        .notUnique,
        "caret inside the inserted text rejected"
    )

    let caretOutside = try TerminalInsertionDiff.compute(
        original: "$ \n",
        current: "$ 斜杠 \n",
        caretUTF16: 0
    )
    try expectEqual(caretOutside.text, "斜杠 ", "caret outside the change is ignored")
}

private func testTerminalUTF16Location() throws {
    let insertion = try TerminalInsertionDiff.compute(
        original: "😀 $ ",
        current: "😀 $ 斜杠",
        caretUTF16: nil
    )
    try expectEqual(insertion.range, NSRange(location: 5, length: 2), "emoji counted in UTF-16")
}

private func testTerminalMacroSettings() throws {
    let settings = AppSettings()
    try expectEqual(settings.textTargetMode(bundleIdentifier: "com.apple.Terminal"), .terminal, "Terminal.app")
    try expectEqual(settings.textTargetMode(bundleIdentifier: "com.googlecode.iterm2"), .terminal, "iTerm2")
    try expectEqual(settings.textTargetMode(bundleIdentifier: "com.apple.TextEdit"), .standard, "TextEdit")
    try expect(
        !settings.keystrokeFallbackBundleIDs.contains { settings.terminalMacroBundleIDs.contains($0) },
        "terminals are not in the editor fallback list"
    )

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{ "schemaVersion": 11, "macroRules": [] }"#.utf8).write(to: fileURL)
    let loaded = SettingsRepository(fileURL: fileURL).load()
    try expectEqual(loaded.schemaVersion, 12, "schema 12")
    try expectEqual(
        loaded.terminalMacroBundleIDs,
        AppSettings.defaultTerminalMacroBundleIDs,
        "terminal list defaults on upgrade"
    )
}

// MARK: - Session policy

private let idleContext = SessionTriggerContext(paused: false, onboardingCompleted: true, inCooldown: false)

private func testTriggerPolicyToggle() throws {
    try expectEqual(
        SessionTriggerPolicy.decide(role: .toggle, kind: .down, active: nil, context: idleContext),
        .start,
        "toggle starts"
    )
    let listening = ActiveSessionState(role: .toggle, phase: .listening, elapsed: 2)
    try expectEqual(
        SessionTriggerPolicy.decide(role: .toggle, kind: .down, active: listening, context: idleContext),
        .stop,
        "toggle stops"
    )
    let fresh = ActiveSessionState(role: .toggle, phase: .listening, elapsed: 0.05)
    try expectEqual(
        SessionTriggerPolicy.decide(role: .toggle, kind: .down, active: fresh, context: idleContext),
        .ignore(.debounce),
        "toggle debounce"
    )
    let processing = ActiveSessionState(role: .toggle, phase: .processing, elapsed: 3)
    try expectEqual(
        SessionTriggerPolicy.decide(
            role: .toggle,
            kind: .down,
            active: processing,
            context: SessionTriggerContext(paused: false, onboardingCompleted: true, inCooldown: true)
        ),
        .restart,
        "toggle during processing restarts even in cooldown"
    )
    let holding = ActiveSessionState(role: .hold, phase: .listening, elapsed: 1)
    try expectEqual(
        SessionTriggerPolicy.decide(role: .toggle, kind: .down, active: holding, context: idleContext),
        .ignore(.busy),
        "toggle ignored while holding"
    )
}

private func testTriggerPolicyHold() throws {
    try expectEqual(
        SessionTriggerPolicy.decide(role: .hold, kind: .down, active: nil, context: idleContext),
        .start,
        "hold starts"
    )
    try expectEqual(
        SessionTriggerPolicy.decide(
            role: .hold,
            kind: .down,
            active: nil,
            context: SessionTriggerContext(paused: false, onboardingCompleted: true, inCooldown: true)
        ),
        .ignore(.cooldown),
        "hold cooldown"
    )
    let toggle = ActiveSessionState(role: .toggle, phase: .listening, elapsed: 1)
    try expectEqual(
        SessionTriggerPolicy.decide(role: .hold, kind: .down, active: toggle, context: idleContext),
        .preemptAndStart,
        "hold preempts toggle"
    )
    let holding = ActiveSessionState(role: .hold, phase: .listening, elapsed: 1)
    try expectEqual(
        SessionTriggerPolicy.decide(role: .hold, kind: .up, active: holding, context: idleContext),
        .stop,
        "hold release stops"
    )
    try expectEqual(
        SessionTriggerPolicy.decide(role: .hold, kind: .up, active: toggle, context: idleContext),
        .ignore(.noSession),
        "hold release ignores toggle session"
    )
    try expectEqual(
        SessionTriggerPolicy.decide(
            role: .hold,
            kind: .down,
            active: nil,
            context: SessionTriggerContext(paused: true, onboardingCompleted: true, inCooldown: false)
        ),
        .ignore(.paused),
        "paused blocks start"
    )
    try expectEqual(
        SessionTriggerPolicy.decide(
            role: .toggle,
            kind: .down,
            active: nil,
            context: SessionTriggerContext(paused: false, onboardingCompleted: false, inCooldown: false)
        ),
        .ignore(.onboarding),
        "onboarding blocks start"
    )
}

private func testSettlePolicyScalesWithListeningTime() throws {
    try expectEqual(SettlePolicy.timeout(forListeningDuration: 0), 1.5, "minimum timeout")
    try expectEqual(SettlePolicy.timeout(forListeningDuration: 10), 2.5, "scaled timeout")
    try expectEqual(SettlePolicy.timeout(forListeningDuration: 120), 4.0, "capped timeout")
    try expect(
        SettlePolicy.watchdog(forListeningDuration: 10) > SettlePolicy.timeout(forListeningDuration: 10),
        "watchdog outlasts settle timeout"
    )
}

func testAppVersionComparison() throws {
    try expect(AppVersion("0.1.0") < AppVersion("0.1.1"), "0.1.0 < 0.1.1")
    try expect(AppVersion("0.1.0") < AppVersion("v0.2.0"), "0.1.0 < v0.2.0")
    try expect(AppVersion("v1.0.0") > AppVersion("0.9.9"), "v1.0.0 > 0.9.9")
    try expectEqual(AppVersion("v0.1.0"), AppVersion("0.1.0"), "v0.1.0 == 0.1.0")
    try expect(!(AppVersion("0.1.0") < AppVersion("0.1.0")), "same version not less")
}

private func testLogiOptionsPatchJson() throws {
    let mockJson = """
    {
      "profile-global": {
        "assignments": [
          {
            "slotId": "mx-anywhere-2s-6b01a_c83",
            "card": { "name": "BACK" }
          },
          {
            "slotId": "mx-anywhere-2s-6b01a_c86",
            "card": { "name": "FORWARD" }
          },
          {
            "slotId": "mx-anywhere-2s-6b01a_c82",
            "card": { "name": "GESTURE" }
          }
        ]
      }
    }
    """

    let result = try LogiOptionsPatcher.patchJson(mockJson)
    try expectEqual(result.count, 2, "patch count")
    try expectEqual(result.slots, ["mx-anywhere-2s-6b01a_c83", "mx-anywhere-2s-6b01a_c86"], "patched slots")

    guard let patchedData = result.newJson.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: patchedData) as? [String: Any],
          let profile = root["profile-global"] as? [String: Any],
          let assigns = profile["assignments"] as? [[String: Any]] else {
        throw TestFailure.assertion("Failed to parse patched json")
    }

    let c83 = assigns.first { $0["slotId"] as? String == "mx-anywhere-2s-6b01a_c83" }
    let c86 = assigns.first { $0["slotId"] as? String == "mx-anywhere-2s-6b01a_c86" }

    let c83Usage = ((c83?["card"] as? [String: Any])?["macro"] as? [String: Any])?["mouse"] as? [String: Any]
    let c86Usage = ((c86?["card"] as? [String: Any])?["macro"] as? [String: Any])?["mouse"] as? [String: Any]

    try expectEqual(c83Usage?["hidUsage"] as? Int, 4, "c83 hidUsage 4")
    try expectEqual(c86Usage?["hidUsage"] as? Int, 5, "c86 hidUsage 5")
}

let tests: [(String, () throws -> Void)] = [
    ("longest rule wins", testLongestRuleWins),
    ("non-recursive replacement", testReplacementIsNotRecursive),
    ("unicode and multiple matches", testUnicodeAndMultipleMatches),
    ("disabled rules", testDisabledRulesAreIgnored),
    ("normalized match with punctuation", testNormalizedMatchWithPunctuation),
    ("normalized match with spaces", testNormalizedMatchWithSpaces),
    ("exact match preferred", testExactMatchStillPreferred),
    ("rule validation", testRuleValidation),
    ("app version comparison", testAppVersionComparison),
    ("hold shortcut presses option then control", testHoldShortcutPressesOptionThenControl),
    ("right modifier keys are preserved", testRightModifierKeysArePreserved),
    ("left command option device bits", testLeftCommandOptionDeviceBits),
    ("toggle shortcut only presses control", testToggleShortcutOnlyPressesControl),
    ("shortcut display name", testShortcutDisplayName),
    ("legacy settings migration", testLegacySettingsMigration),
    ("intermediate shortcut migration", testIntermediateShortcutMigration),
    ("schema three shortcut migration", testBrokenSchemaThreeHoldShortcutMigration),
    ("schema four shortcut migration", testSchemaFourControlOnlyHoldMigration),
    ("schema five shortcut migration", testSchemaFiveCommandOnlyHoldMigration),
    ("settings round trip", testSettingsRoundTrip),
    ("corrupt settings backup", testCorruptSettingsBackup),
    ("wechat input region", testWeChatInputRegion),
    ("hold cancel arm and disarm", testHoldCancelArmAndDisarm),
    ("selection restore policy", testSelectionRestorePolicy),
    ("hold start evaluator", testHoldStartEvaluator),
    ("navigation exclude lists", testNavigationExcludeDoesNotIncludeDoubao),
    ("schema eight strips doubao", testSchemaEightStripsDoubaoExclude),
    ("schema nine macro rules migration", testSchemaNineMacroRulesMigration),
    ("schema ten hold button migration", testSchemaTenHoldButtonMigration),
    ("schema eleven disables bare approve rules", testSchemaElevenDisablesBareApproveRules),
    ("macro aliases", testMacroAliases),
    ("whole utterance drops trailing punctuation", testWholeUtteranceDropsTrailingPunctuation),
    ("partial utterance keeps punctuation", testPartialUtteranceKeepsPunctuation),
    ("default rules leave English alone", testEnglishWordsAreNotRewrittenByDefault),
    ("validation detects alias duplicates", testValidationDetectsAliasDuplicates),
    ("insertion diff exact middle", testInsertionDiffExactMiddle),
    ("insertion diff replaces selection", testInsertionDiffReplacesSelection),
    ("insertion diff uses UTF-16 offsets", testInsertionDiffUsesUTF16Offsets),
    ("insertion diff common prefix UTF-16", testInsertionDiffCommonPrefixUTF16),
    ("insertion diff no insertion", testInsertionDiffNoInsertion),
    ("keystroke chunks respect limit", testKeystrokeChunksRespectLimit),
    ("terminal shell prompt", testTerminalShellPrompt),
    ("terminal TUI padding is consumed", testTerminalTUIPaddingIsConsumed),
    ("terminal rejects other changes", testTerminalRejectsOtherChanges),
    ("terminal caret decides trailing space", testTerminalCaretDecidesTrailingSpace),
    ("terminal UTF-16 location", testTerminalUTF16Location),
    ("terminal macro settings", testTerminalMacroSettings),
    ("trigger policy toggle", testTriggerPolicyToggle),
    ("trigger policy hold", testTriggerPolicyHold),
    ("settle policy scales with listening time", testSettlePolicyScalesWithListeningTime),
    ("logi options patch json", testLogiOptionsPatchJson),
]

var failures = 0
for (name, test) in tests {
    do {
        try test()
        print("PASS \(name)")
    } catch {
        failures += 1
        fputs("FAIL \(name): \(error)\n", stderr)
    }
}

if failures > 0 {
    print("\(failures) test(s) failed")
    exit(1)
}

print("All \(tests.count) tests passed")
