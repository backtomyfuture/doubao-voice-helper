import Foundation

public struct MacroResult: Equatable, Sendable {
    public let output: String
    public let matchCount: Int

    public init(output: String, matchCount: Int) {
        self.output = output
        self.matchCount = matchCount
    }

    public var changed: Bool {
        matchCount > 0
    }
}

public struct MacroValidationIssue: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case emptySource
        case duplicateSource
    }

    public let kind: Kind
    public let ruleID: UUID

    public init(kind: Kind, ruleID: UUID) {
        self.kind = kind
        self.ruleID = ruleID
    }
}

public struct MacroEngine: Sendable {
    public init() {}

    public func apply(_ input: String, rules: [MacroRule]) -> MacroResult {
        let candidates = rules
            .enumerated()
            .filter { $0.element.isEnabled && !$0.element.source.isEmpty }
            .sorted {
                if $0.element.source.count != $1.element.source.count {
                    return $0.element.source.count > $1.element.source.count
                }
                return $0.offset < $1.offset
            }
            .map(\.element)

        guard !input.isEmpty, !candidates.isEmpty else {
            return MacroResult(output: input, matchCount: 0)
        }

        var result = String()
        var index = input.startIndex
        var matchCount = 0

        while index < input.endIndex {
            let remainder = input[index...]
            if let rule = candidates.first(where: {
                remainder.hasPrefix($0.source)
            }) {
                result.append(contentsOf: rule.replacement)
                index = input.index(index, offsetBy: rule.source.count)
                matchCount += 1
            } else {
                result.append(input[index])
                index = input.index(after: index)
            }
        }

        return MacroResult(output: result, matchCount: matchCount)
    }

    public func validate(_ rules: [MacroRule]) -> [MacroValidationIssue] {
        var issues: [MacroValidationIssue] = []
        var seenSources = Set<String>()

        for rule in rules {
            if rule.source.isEmpty {
                issues.append(
                    MacroValidationIssue(kind: .emptySource, ruleID: rule.id)
                )
            } else if !seenSources.insert(rule.source).inserted {
                issues.append(
                    MacroValidationIssue(kind: .duplicateSource, ruleID: rule.id)
                )
            }
        }

        return issues
    }
}
