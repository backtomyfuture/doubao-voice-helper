import Foundation

/// Derives the text that dictation inserted by comparing the anchor snapshot
/// with the settled control value. All offsets are UTF-16 (`NSString`) units so
/// the resulting range can be passed straight to AX range attributes.
public enum TextInsertionDiff {
    public enum Kind: Equatable, Sendable {
        /// Text before and after the anchored selection is unchanged, so the
        /// inserted span is proven.
        case exact
        /// The control only grew at the end (typical of terminal buffers).
        case appended
        /// Only a common prefix could be established; everything after it is
        /// treated as new. Not safe for keystroke-based replacement.
        case commonPrefix
        /// Produced by `TerminalInsertionDiff`: a single-line insertion at the
        /// terminal cursor, replaceable only with keystrokes.
        case terminalLine
    }

    public struct Insertion: Equatable, Sendable {
        public let text: String
        public let range: NSRange
        public let kind: Kind

        public init(text: String, range: NSRange, kind: Kind) {
            self.text = text
            self.range = range
            self.kind = kind
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case noInsertion
        case notUnique
    }

    public static func compute(
        original: String,
        selectedRange: NSRange,
        current: String
    ) throws -> Insertion {
        let originalNS = original as NSString
        let currentNS = current as NSString
        let start = selectedRange.location
        let selectedLength = selectedRange.length

        guard start >= 0,
              selectedLength >= 0,
              start + selectedLength <= originalNS.length
        else {
            throw Failure.notUnique
        }

        let prefix = originalNS.substring(to: start)
        let suffix = originalNS.substring(from: start + selectedLength)
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length

        // NSString.hasPrefix/hasSuffix return false for an empty argument.
        if prefix.isEmpty || currentNS.hasPrefix(prefix),
           suffix.isEmpty || currentNS.hasSuffix(suffix),
           currentNS.length >= prefixLength + suffixLength
        {
            let insertedLength = currentNS.length - prefixLength - suffixLength
            guard insertedLength > 0 else {
                throw Failure.noInsertion
            }
            let range = NSRange(location: prefixLength, length: insertedLength)
            return Insertion(
                text: currentNS.substring(with: range),
                range: range,
                kind: .exact
            )
        }

        guard currentNS.length > originalNS.length else {
            throw Failure.noInsertion
        }

        if original.isEmpty || currentNS.hasPrefix(original) {
            return try tail(of: currentNS, from: originalNS.length, kind: .appended)
        }

        var prefixLengthUTF16 = (originalNS.commonPrefix(with: current, options: .literal) as NSString).length
        if prefixLengthUTF16 < currentNS.length {
            // Never split a surrogate pair or composed character.
            prefixLengthUTF16 = currentNS.rangeOfComposedCharacterSequence(at: prefixLengthUTF16).location
        }
        guard prefixLengthUTF16 > 0 else {
            throw Failure.notUnique
        }
        return try tail(of: currentNS, from: prefixLengthUTF16, kind: .commonPrefix)
    }

    private static func tail(
        of text: NSString,
        from location: Int,
        kind: Kind
    ) throws -> Insertion {
        let range = NSRange(location: location, length: text.length - location)
        let inserted = text.substring(with: range)
        guard !inserted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.noInsertion
        }
        return Insertion(text: inserted, range: range, kind: kind)
    }
}
