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

private func testSettingsRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("settings.json")
    let repository = SettingsRepository(fileURL: fileURL)
    let settings = AppSettings(
        mouseBinding: MouseBinding(button: 7),
        doubaoShortcut: KeyboardShortcut(
            keyCode: 12,
            modifiers: [.command, .shift]
        ),
        excludedBundleIDs: ["example.app"],
        macroRules: [
            MacroRule(source: "斜杠", replacement: "/"),
        ],
        launchAtLogin: false,
        overlayEnabled: false
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

let tests: [(String, () throws -> Void)] = [
    ("longest rule wins", testLongestRuleWins),
    ("non-recursive replacement", testReplacementIsNotRecursive),
    ("unicode and multiple matches", testUnicodeAndMultipleMatches),
    ("disabled rules", testDisabledRulesAreIgnored),
    ("rule validation", testRuleValidation),
    ("settings round trip", testSettingsRoundTrip),
    ("corrupt settings backup", testCorruptSettingsBackup),
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
