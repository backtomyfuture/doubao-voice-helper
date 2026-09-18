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
    try expectEqual(settings.holdMouseBinding.button, 0, "legacy hold button")
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
    try expectEqual(settings.wechatHoldPreemptEnabled, true, "wechat preempt default")
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
        launchAtLogin: false,
        overlayEnabled: false,
        wechatHoldPreemptEnabled: false,
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
    try expectEqual(loaded.schemaVersion, 9, "schema bumped to 9")
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
    try expectEqual(loaded.schemaVersion, 9, "schema bumped to 9")
    try expect(
        loaded.macroRules.contains(where: { $0.source == "approve" && $0.replacement == "/approve" }),
        "schema 9 adds approve rule"
    )
    try expect(
        loaded.macroRules.contains(where: { $0.source == "Approve" && $0.replacement == "/approve" }),
        "schema 9 adds Approve rule"
    )
    try expect(
        loaded.macroRules.contains(where: { $0.source == "旧规则" }),
        "preserves existing user rules"
    )
}

let tests: [(String, () throws -> Void)] = [
    ("longest rule wins", testLongestRuleWins),
    ("non-recursive replacement", testReplacementIsNotRecursive),
    ("unicode and multiple matches", testUnicodeAndMultipleMatches),
    ("disabled rules", testDisabledRulesAreIgnored),
    ("rule validation", testRuleValidation),
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
