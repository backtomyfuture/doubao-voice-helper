import Foundation

public struct RecentDictationItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let bundleID: String
    public let timestamp: Date
    public let matched: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        bundleID: String,
        timestamp: Date = Date(),
        matched: Bool
    ) {
        self.id = id
        self.text = text
        self.bundleID = bundleID
        self.timestamp = timestamp
        self.matched = matched
    }
}

public struct RecentDictations: Sendable {
    public static let maxCount = 5
    public static let maxCharacterCount = 20

    public private(set) var items: [RecentDictationItem]

    public init(items: [RecentDictationItem] = []) {
        self.items = items
    }

    public mutating func append(
        text: String,
        bundleID: String,
        timestamp: Date = Date(),
        matched: Bool
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxCharacterCount else {
            return
        }

        let item = RecentDictationItem(
            text: trimmed,
            bundleID: bundleID,
            timestamp: timestamp,
            matched: matched
        )
        items.insert(item, at: 0)
        if items.count > Self.maxCount {
            items.removeLast()
        }
    }
}
