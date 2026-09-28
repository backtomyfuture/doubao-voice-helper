import Foundation

public enum MacroNormalizer {
    /// Unicode NFKC → 小写 → 删除标点(P*)、分隔符(Z*)、空白、格式字符(Cf)；符号(S*)保留
    public static func normalize(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping.lowercased()
        return String(nfkc.unicodeScalars.filter { !isIgnored($0) })
    }

    private static func isIgnored(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .spaceSeparator, .lineSeparator, .paragraphSeparator,
             .format:
            return true
        case .control:
            return scalar == "\t" || scalar == "\n" || scalar == "\r"
        default:
            return false
        }
    }
}

public struct MacroValidationIssue: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case emptySource
        case duplicateSource
        case prefixConflict
    }

    public let kind: Kind
    public let ruleID: UUID

    public init(kind: Kind, ruleID: UUID) {
        self.kind = kind
        self.ruleID = ruleID
    }
}

/// 纯本地的整句匹配引擎：判断一次听写的 Inserted Text 是否整句等于某条 Macro Rule 的触发词。
public struct MacroEngine: Sendable {
    public static let aliasSeparator: Character = "|"

    public enum Decision: Equatable, Sendable {
        case pending
        case reject
        case match(ruleID: UUID, replacement: String)
    }

    private struct CompiledRule: Sendable {
        let ruleID: UUID
        let normalizedPattern: String
        let replacement: String
    }

    private let compiledRules: [CompiledRule]

    public init(rules: [MacroRule] = []) {
        var compiled: [CompiledRule] = []
        var seen = Set<String>()
        for rule in rules where rule.isEnabled {
            for alias in Self.aliases(of: rule.source) {
                let norm = MacroNormalizer.normalize(alias)
                guard !norm.isEmpty else { continue }
                if seen.insert(norm).inserted {
                    compiled.append(CompiledRule(
                        ruleID: rule.id,
                        normalizedPattern: norm,
                        replacement: rule.replacement
                    ))
                }
            }
        }
        self.compiledRules = compiled
    }

    public var isEmpty: Bool {
        compiledRules.isEmpty
    }

    public static func aliases(of source: String) -> [String] {
        source
            .split(separator: aliasSeparator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 边读边判断：归一化为空或是某个触发词的开头时返回 .pending
    public func decide(_ insertedText: String) -> Decision {
        guard !isEmpty else { return .reject }
        let norm = MacroNormalizer.normalize(insertedText)
        if norm.isEmpty {
            return .pending
        }
        if let hit = compiledRules.first(where: { $0.normalizedPattern == norm }) {
            return .match(ruleID: hit.ruleID, replacement: hit.replacement)
        }
        if compiledRules.contains(where: { $0.normalizedPattern.hasPrefix(norm) }) {
            return .pending
        }
        return .reject
    }

    /// 最终判断：不会返回 .pending
    public func finalDecision(_ insertedText: String) -> Decision {
        guard !isEmpty else { return .reject }
        let norm = MacroNormalizer.normalize(insertedText)
        guard !norm.isEmpty else { return .reject }
        if let hit = compiledRules.first(where: { $0.normalizedPattern == norm }) {
            return .match(ruleID: hit.ruleID, replacement: hit.replacement)
        }
        return .reject
    }

    public func validate(_ rules: [MacroRule]) -> [MacroValidationIssue] {
        var issues: [MacroValidationIssue] = []
        var seenPatterns = Set<String>()
        var allValidPatterns: [String] = []

        for rule in rules {
            let patterns = Self.aliases(of: rule.source)
                .map { MacroNormalizer.normalize($0) }
                .filter { !$0.isEmpty }
            if patterns.isEmpty {
                issues.append(MacroValidationIssue(kind: .emptySource, ruleID: rule.id))
                continue
            }
            var duplicate = false
            for pattern in patterns {
                if !seenPatterns.insert(pattern).inserted {
                    duplicate = true
                }
            }
            if duplicate {
                issues.append(MacroValidationIssue(kind: .duplicateSource, ruleID: rule.id))
                continue
            }

            var hasPrefixConflict = false
            for pattern in patterns {
                for seen in allValidPatterns {
                    if pattern != seen && (pattern.hasPrefix(seen) || seen.hasPrefix(pattern)) {
                        hasPrefixConflict = true
                        break
                    }
                }
                if hasPrefixConflict { break }
            }
            if hasPrefixConflict {
                issues.append(MacroValidationIssue(kind: .prefixConflict, ruleID: rule.id))
            }
            allValidPatterns.append(contentsOf: patterns)
        }

        return issues
    }
}
