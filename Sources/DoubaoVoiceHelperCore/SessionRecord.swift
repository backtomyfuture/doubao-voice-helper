import Foundation

public struct SessionRecord: Codable, Equatable, Sendable {
    public var id: String
    public var startedAt: String
    public var app: String
    public var mode: String
    public var role: String
    public var listenedMs: Int
    public var anchor: String
    public var outcome: String
    public var decision: String
    public var failure: String?
    public var method: String?
    public var firstChangeMs: Int?
    public var decisionMs: Int?
    public var doneMs: Int?
    public var enter: String
    public var enterWaitMs: Int?

    public init(
        id: String,
        startedAt: String,
        app: String,
        mode: String,
        role: String,
        listenedMs: Int,
        anchor: String,
        outcome: String,
        decision: String,
        failure: String? = nil,
        method: String? = nil,
        firstChangeMs: Int? = nil,
        decisionMs: Int? = nil,
        doneMs: Int? = nil,
        enter: String = "none",
        enterWaitMs: Int? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.app = app
        self.mode = mode
        self.role = role
        self.listenedMs = listenedMs
        self.anchor = anchor
        self.outcome = outcome
        self.decision = decision
        self.failure = failure
        self.method = method
        self.firstChangeMs = firstChangeMs
        self.decisionMs = decisionMs
        self.doneMs = doneMs
        self.enter = enter
        self.enterWaitMs = enterWaitMs
    }
}

public final class SessionRecordStore: Sendable {
    public let fileURL: URL
    private let queue = DispatchQueue(label: "com.jarod.doubao-voice-helper.session-store", qos: .utility)

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let logsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DoubaoVoiceHelper", isDirectory: true)
            self.fileURL = logsDir.appendingPathComponent("sessions.jsonl", isDirectory: false)
        }
    }

    public static func defaultStore() -> SessionRecordStore {
        SessionRecordStore()
    }

    public func append(_ record: SessionRecord) {
        queue.async {
            self.performAppend(record)
        }
    }

    public func appendSync(_ record: SessionRecord) {
        queue.sync {
            self.performAppend(record)
        }
    }

    public func pruneOlderThan(days: Int = 30, now: Date = Date()) {
        queue.async {
            self.performPrune(days: days, now: now)
        }
    }

    public func pruneSync(days: Int = 30, now: Date = Date()) {
        queue.sync {
            self.performPrune(days: days, now: now)
        }
    }

    private func performAppend(_ record: SessionRecord) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            let data = try encoder.encode(record)
            guard let line = String(data: data, encoding: .utf8) else { return }
            let lineData = Data((line + "\n").utf8)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
            } else {
                try lineData.write(to: fileURL, options: .atomic)
            }
        } catch {
            // Write failures do not interrupt dictation.
        }
    }

    private func performPrune(days: Int, now: Date) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            let cutoff = now.addingTimeInterval(-Double(days) * 86400)
            let isoFormatter = ISO8601DateFormatter()
            let isoFractionalFormatter = ISO8601DateFormatter()
            isoFractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            var keptLines: [String] = []
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if let data = trimmed.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let startedAtStr = dict["startedAt"] as? String {
                    let date = isoFractionalFormatter.date(from: startedAtStr) ?? isoFormatter.date(from: startedAtStr)
                    if let date, date < cutoff {
                        continue
                    }
                }
                keptLines.append(trimmed)
            }

            let newContent = keptLines.isEmpty ? "" : keptLines.joined(separator: "\n") + "\n"
            try newContent.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
        }
    }
}
