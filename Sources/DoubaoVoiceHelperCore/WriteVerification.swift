import Foundation

public enum WriteVerification {
    /// 校验写回是否生效：
    /// actual == prefix + replacement + [只含可忽略字符的片段] + suffix
    public static func isApplied(
        actual: String,
        prefix: String,
        replacement: String,
        suffix: String
    ) -> Bool {
        guard actual.count >= prefix.count + replacement.count + suffix.count else {
            return false
        }
        guard actual.hasPrefix(prefix) else { return false }
        guard actual.hasSuffix(suffix) else { return false }

        let middleStart = actual.index(actual.startIndex, offsetBy: prefix.count)
        let middleEnd = actual.index(actual.endIndex, offsetBy: -suffix.count)
        guard middleStart <= middleEnd else { return false }

        let middle = String(actual[middleStart..<middleEnd])
        guard middle.hasPrefix(replacement) else { return false }

        let extra = middle.dropFirst(replacement.count)
        return extra.unicodeScalars.allSatisfy { isIgnorable($0) }
    }

    private static func isIgnorable(_ scalar: Unicode.Scalar) -> Bool {
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
