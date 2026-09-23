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

    private static func normalize(_ text: String) -> String {
        return text.replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: "、", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

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

        let normalizedInput = Self.normalize(input)

        // 如果输入归一化后未改变，按原始逻辑精确匹配（快速路径）
        if normalizedInput == input {
            return applyExact(input, candidates: candidates)
        }

        // 构建归一化到原始的索引映射：normalizedIndexMap[i] = 归一化字符串第 i 个字符在原始字符串中的索引
        var normalizedChars: [Character] = []
        var normalizedToOriginal: [String.Index] = []
        for idx in input.indices {
            let ch = input[idx]
            if Self.normalize(String(ch)) != "" {
                normalizedChars.append(ch)
                normalizedToOriginal.append(idx)
            }
        }

        let normalizedSources = candidates.map { Self.normalize($0.source) }

        var result = String()
        var nIdx = 0 // 归一化字符串中的位置
        var origConsumedUpTo = input.startIndex // 原始字符串中已消费到的位置
        var matchCount = 0

        while nIdx < normalizedChars.count {
            var matched = false
            for (i, rule) in candidates.enumerated() {
                let ns = normalizedSources[i]
                guard !ns.isEmpty, nIdx + ns.count <= normalizedChars.count else { continue }

                let slice = normalizedChars[nIdx..<(nIdx + ns.count)]
                guard String(slice) == ns else { continue }

                // 匹配成功：先输出原始字符串中从 origConsumedUpTo 到匹配起始位置之间的原始字符
                let matchOrigStart = normalizedToOriginal[nIdx]
                if matchOrigStart > origConsumedUpTo {
                    result.append(contentsOf: input[origConsumedUpTo..<matchOrigStart])
                }

                result.append(contentsOf: rule.replacement)

                // 更新消费位置
                let lastMatchedOrigIdx = normalizedToOriginal[nIdx + ns.count - 1]
                origConsumedUpTo = input.index(after: lastMatchedOrigIdx)
                nIdx += ns.count
                matchCount += 1
                matched = true
                break
            }
            if !matched {
                nIdx += 1
            }
        }

        if matchCount > 0 {
            // 输出剩余的原始字符
            if origConsumedUpTo < input.endIndex {
                result.append(contentsOf: input[origConsumedUpTo...])
            }
            return MacroResult(output: result, matchCount: matchCount)
        }

        return MacroResult(output: input, matchCount: 0)
    }

    private func applyExact(_ input: String, candidates: [MacroRule]) -> MacroResult {
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
