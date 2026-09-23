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

/// Deterministic literal replacement for dictated text.
///
/// - A rule source may list aliases separated by `|` (e.g. `斜杠|写杠`) so that
///   common homophone mis-recognitions map to the same output.
/// - Punctuation and spaces that the recognizer inserts are ignored while
///   matching; those inside a matched span are consumed with it.
/// - When every meaningful character of the utterance is covered by matches,
///   the output is only the concatenated replacements, so `斜杠批准。`
///   becomes `/approve` instead of `/approve。`.
public struct MacroEngine: Sendable {
    public static let aliasSeparator: Character = "|"

    static let ignorableCharacters: Set<Character> = [
        "，", "、", "。", "！", "？", "；", "：",
        ",", ".", "!", "?", ";", ":",
        " ", "\u{3000}", "\t", "\n", "\r",
    ]

    public init() {}

    public static func aliases(of source: String) -> [String] {
        source
            .split(separator: aliasSeparator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func normalizedCharacters(_ text: String) -> [Character] {
        text.filter { !ignorableCharacters.contains($0) }.map { $0 }
    }

    private struct Candidate {
        let pattern: [Character]
        let replacement: String
    }

    private struct Match {
        let start: Int
        let length: Int
        let replacement: String
    }

    public func apply(_ input: String, rules: [MacroRule]) -> MacroResult {
        let candidates = rules
            .filter(\.isEnabled)
            .flatMap { rule in
                Self.aliases(of: rule.source).map {
                    Candidate(
                        pattern: Self.normalizedCharacters($0),
                        replacement: rule.replacement
                    )
                }
            }
            .filter { !$0.pattern.isEmpty }
            .enumerated()
            .sorted {
                if $0.element.pattern.count != $1.element.pattern.count {
                    return $0.element.pattern.count > $1.element.pattern.count
                }
                return $0.offset < $1.offset
            }
            .map(\.element)

        guard !input.isEmpty, !candidates.isEmpty else {
            return MacroResult(output: input, matchCount: 0)
        }

        var characters: [Character] = []
        var originalIndices: [String.Index] = []
        for index in input.indices where !Self.ignorableCharacters.contains(input[index]) {
            characters.append(input[index])
            originalIndices.append(index)
        }

        var matches: [Match] = []
        var position = 0
        while position < characters.count {
            let hit = candidates.first { candidate in
                let end = position + candidate.pattern.count
                return end <= characters.count &&
                    characters[position..<end].elementsEqual(candidate.pattern)
            }
            if let hit {
                matches.append(
                    Match(
                        start: position,
                        length: hit.pattern.count,
                        replacement: hit.replacement
                    )
                )
                position += hit.pattern.count
            } else {
                position += 1
            }
        }

        guard !matches.isEmpty else {
            return MacroResult(output: input, matchCount: 0)
        }

        let covered = matches.reduce(0) { $0 + $1.length }
        if covered == characters.count {
            return MacroResult(
                output: matches.map(\.replacement).joined(),
                matchCount: matches.count
            )
        }

        var output = String()
        var consumedUpTo = input.startIndex
        for match in matches {
            let start = originalIndices[match.start]
            let last = originalIndices[match.start + match.length - 1]
            output.append(contentsOf: input[consumedUpTo..<start])
            output.append(contentsOf: match.replacement)
            consumedUpTo = input.index(after: last)
        }
        output.append(contentsOf: input[consumedUpTo...])
        return MacroResult(output: output, matchCount: matches.count)
    }

    public func validate(_ rules: [MacroRule]) -> [MacroValidationIssue] {
        var issues: [MacroValidationIssue] = []
        var seen = Set<String>()

        for rule in rules {
            let patterns = Self.aliases(of: rule.source)
                .map { String(Self.normalizedCharacters($0)) }
                .filter { !$0.isEmpty }
            if patterns.isEmpty {
                issues.append(MacroValidationIssue(kind: .emptySource, ruleID: rule.id))
                continue
            }
            var duplicate = false
            for pattern in patterns where !seen.insert(pattern).inserted {
                duplicate = true
            }
            if duplicate {
                issues.append(MacroValidationIssue(kind: .duplicateSource, ruleID: rule.id))
            }
        }

        return issues
    }
}
