import Foundation
import SQLite3

public struct LogiPatchResult: Sendable {
    public let count: Int
    public let backupPath: String
    public let slots: [String]

    public init(count: Int, backupPath: String, slots: [String]) {
        self.count = count
        self.backupPath = backupPath
        self.slots = slots
    }
}

public enum LogiPatcherError: LocalizedError {
    case databaseNotFound(String)
    case databaseOpenFailed(String)
    case queryFailed(String)
    case noDataFound
    case jsonDecodeFailed
    case jsonEncodeFailed
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .databaseNotFound(let path):
            return "未找到 Logi Options+ 配置文件：\(path)"
        case .databaseOpenFailed(let msg):
            return "打开罗技数据库失败：\(msg)"
        case .queryFailed(let msg):
            return "读取罗技数据失败：\(msg)"
        case .noDataFound:
            return "罗技数据库中未找到配置数据"
        case .jsonDecodeFailed:
            return "解析罗技配置 JSON 失败"
        case .jsonEncodeFailed:
            return "生成罗技配置 JSON 失败"
        case .writeFailed(let msg):
            return "写入罗技数据库失败：\(msg)"
        }
    }
}

public final class LogiOptionsPatcher: Sendable {
    public static let shared = LogiOptionsPatcher()

    public var settingsDatabasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/LogiOptionsPlus/settings.db"
    }

    public var agentPath: String {
        "/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app"
    }

    public init() {}

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: settingsDatabasePath)
    }

    public func needsFix() -> Bool {
        guard isInstalled else { return false }
        guard let rawJson = try? readRawSettings() else { return false }
        guard let data = try? JSONSerialization.jsonObject(with: rawJson.data(using: .utf8) ?? Data()) as? [String: Any] else {
            return false
        }

        for (_, val) in data {
            guard let dict = val as? [String: Any],
                  let assigns = dict["assignments"] as? [[String: Any]] else {
                continue
            }
            for item in assigns {
                guard let slotId = item["slotId"] as? String else { continue }
                if slotId.hasSuffix("_c83") {
                    let macro = (item["card"] as? [String: Any])?["macro"] as? [String: Any]
                    let mouse = macro?["mouse"] as? [String: Any]
                    if mouse?["action"] as? String != "BUTTON" || mouse?["hidUsage"] as? Int != 4 {
                        return true
                    }
                } else if slotId.hasSuffix("_c86") {
                    let macro = (item["card"] as? [String: Any])?["macro"] as? [String: Any]
                    let mouse = macro?["mouse"] as? [String: Any]
                    if mouse?["action"] as? String != "BUTTON" || mouse?["hidUsage"] as? Int != 5 {
                        return true
                    }
                }
            }
        }
        return false
    }

    @discardableResult
    public func patch() throws -> LogiPatchResult {
        let dbPath = settingsDatabasePath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw LogiPatcherError.databaseNotFound(dbPath)
        }

        // 1. 停止 Logi 进程
        stopLogiProcesses()

        // 2. 备份数据库
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let backupPath = "\(dbPath).bak-doubao-\(timestamp)"
        try? FileManager.default.copyItem(atPath: dbPath, toPath: backupPath)

        // 3. 读取、修改并回写
        var db: OpaquePointer?
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw LogiPatcherError.databaseOpenFailed(errmsg)
        }
        defer {
            sqlite3_close(db)
            restartLogiAgent()
        }

        var stmt: OpaquePointer?
        let query = "SELECT _id, file FROM data LIMIT 1"
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            throw LogiPatcherError.queryFailed(errmsg)
        }

        var rowId: Int64 = 0
        var rawText: String = ""
        if sqlite3_step(stmt) == SQLITE_ROW {
            rowId = sqlite3_column_int64(stmt, 0)
            if let textPtr = sqlite3_column_text(stmt, 1) {
                rawText = String(cString: textPtr)
            }
        } else {
            sqlite3_finalize(stmt)
            throw LogiPatcherError.noDataFound
        }
        sqlite3_finalize(stmt)

        let (newJsonText, patchedCount, modifiedSlots) = try Self.patchJson(rawText)

        var updateStmt: OpaquePointer?
        let updateQuery = "UPDATE data SET file = ? WHERE _id = ?"
        if sqlite3_prepare_v2(db, updateQuery, -1, &updateStmt, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            throw LogiPatcherError.writeFailed(errmsg)
        }

        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(updateStmt, 1, newJsonText, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(updateStmt, 2, rowId)

        if sqlite3_step(updateStmt) != SQLITE_DONE {
            let errmsg = String(cString: sqlite3_errmsg(db))
            sqlite3_finalize(updateStmt)
            throw LogiPatcherError.writeFailed(errmsg)
        }
        sqlite3_finalize(updateStmt)

        return LogiPatchResult(
            count: patchedCount,
            backupPath: backupPath,
            slots: Array(Set(modifiedSlots)).sorted()
        )
    }

    private func readRawSettings() throws -> String {
        var db: OpaquePointer?
        if sqlite3_open_v2(settingsDatabasePath, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw LogiPatcherError.databaseOpenFailed(errmsg)
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT file FROM data LIMIT 1", -1, &stmt, nil) != SQLITE_OK {
            let errmsg = String(cString: sqlite3_errmsg(db))
            throw LogiPatcherError.queryFailed(errmsg)
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW, let textPtr = sqlite3_column_text(stmt, 0) {
            return String(cString: textPtr)
        }
        throw LogiPatcherError.noDataFound
    }

    public static func patchJson(_ rawText: String) throws -> (newJson: String, count: Int, slots: [String]) {
        guard let jsonData = rawText.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw LogiPatcherError.jsonDecodeFailed
        }

        var patchedCount = 0
        var modifiedSlots: [String] = []

        for (key, val) in root {
            guard var profile = val as? [String: Any],
                  var assigns = profile["assignments"] as? [[String: Any]] else {
                continue
            }

            var profileChanged = false
            for i in 0..<assigns.count {
                guard let slotId = assigns[i]["slotId"] as? String else { continue }
                if slotId.hasSuffix("_c83") {
                    assigns[i] = makeButtonAssignment(slotId: slotId, hidUsage: 4, actionName: "MB4")
                    patchedCount += 1
                    modifiedSlots.append(slotId)
                    profileChanged = true
                } else if slotId.hasSuffix("_c86") {
                    assigns[i] = makeButtonAssignment(slotId: slotId, hidUsage: 5, actionName: "MB5")
                    patchedCount += 1
                    modifiedSlots.append(slotId)
                    profileChanged = true
                }
            }

            if profileChanged {
                profile["assignments"] = assigns
                root[key] = profile
            }
        }

        guard let newJsonData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let newJsonText = String(data: newJsonData, encoding: .utf8) else {
            throw LogiPatcherError.jsonEncodeFailed
        }

        return (newJsonText, patchedCount, Array(Set(modifiedSlots)).sorted())
    }

    private static func makeButtonAssignment(slotId: String, hidUsage: Int, actionName: String) -> [String: Any] {
        [
            "card": [
                "attribute": "MACRO_PLAYBACK",
                "icons": [
                    "icons": ["Shortcut.png", "Shortcut.svg"],
                    "uri": "pipeline://system_actions/",
                ],
                "id": "card_global_presets_keyboard_shortcut",
                "macro": [
                    "actionName": actionName,
                    "mouse": [
                        "action": "BUTTON",
                        "hidUsage": hidUsage,
                    ],
                    "type": "MOUSE",
                ],
                "name": "ASSIGNMENT_NAME_KEYBOARD_SHORTCUT",
                "tags": [
                    "PRESET_TAG_KEY_OR_BUTTON",
                    "PRESET_TAG_MACROS_UNSUPPORTED",
                    "PRESET_KEYBOARD_FUNCTIONS",
                ],
                "taskId": 73,
            ],
            "cardId": "card_global_presets_keyboard_shortcut",
            "slotId": slotId,
            "tags": ["UI_PAGE_BUTTONS"],
        ]
    }

    private func stopLogiProcesses() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["logioptionsplus_agent", "logioptionsplus"]
        try? task.run()
        task.waitUntilExit()
        usleep(1_500_000)
    }

    private func restartLogiAgent() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = [agentPath]
        try? task.run()
    }
}
