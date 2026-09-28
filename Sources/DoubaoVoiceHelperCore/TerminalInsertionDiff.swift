import Foundation

/// Derives dictated text inside a terminal, whose AX value is the whole
/// read-only screen buffer rather than an editable field.
///
/// The buffer must be unchanged except at a single point on one line: either a
/// pure insertion (shell prompt) or an insertion that consumed blank padding
/// (a fixed-width TUI input box). Any other change, such as program output,
/// a redrawn placeholder or a wrapped line, is rejected so that no keystroke
/// replacement is attempted.
public enum TerminalInsertionDiff {
    public static func compute(
        original: String,
        current: String,
        caretUTF16: Int?
    ) throws -> TextInsertionDiff.Insertion {
        var start = original.startIndex
        var currentStart = current.startIndex
        while start < original.endIndex,
              currentStart < current.endIndex,
              original[start] == current[currentStart]
        {
            original.formIndex(after: &start)
            current.formIndex(after: &currentStart)
        }

        var end = original.endIndex
        var currentEnd = current.endIndex
        while end > start, currentEnd > currentStart {
            let previous = original.index(before: end)
            let currentPrevious = current.index(before: currentEnd)
            guard original[previous] == current[currentPrevious] else { break }
            end = previous
            currentEnd = currentPrevious
        }

        let removed = original[start..<end]
        let added = current[currentStart..<currentEnd]
        // 1. Strict single-line diff across the entire buffer
        if !removed.contains(where: \.isNewline) && !added.contains(where: \.isNewline) {
            guard !added.isEmpty else {
                throw TextInsertionDiff.Failure.noInsertion
            }

            if !removed.allSatisfy(isPadding) {
                let promptIndicators = ["$ ", "% ", "# "]
                if promptIndicators.contains(where: { removed.contains($0) }) {
                    throw TextInsertionDiff.Failure.notUnique
                }
            }

            let startOffset = current.utf16.distance(from: current.startIndex, to: currentStart)
            let endOffset = current.utf16.distance(from: current.startIndex, to: currentEnd)

            var textEnd = currentEnd
            if let caretUTF16, caretUTF16 >= startOffset, caretUTF16 <= endOffset {
                let caret = String.Index(utf16Offset: caretUTF16, in: current)
                guard current[caret..<currentEnd].allSatisfy(isPadding) else {
                    throw TextInsertionDiff.Failure.notUnique
                }
                textEnd = caret
            } else if !removed.isEmpty {
                while textEnd > currentStart, isPadding(current[current.index(before: textEnd)]) {
                    textEnd = current.index(before: textEnd)
                }
            }

            let text = String(current[currentStart..<textEnd])
            guard !text.allSatisfy(isPadding) else {
                throw TextInsertionDiff.Failure.noInsertion
            }
            return TextInsertionDiff.Insertion(
                text: text,
                range: NSRange(location: startOffset, length: text.utf16.count),
                kind: .terminalLine
            )
        }

        // 2. Multiline diff detected: check if this is a single-line prompt input
        // where a status bar, shortcuts footer (e.g. agy), or right-hand timestamp
        // changed elsewhere on the screen.
        let originalLineEnd = original[start...].firstIndex(where: \.isNewline) ?? original.endIndex
        let currentLineEnd = current[currentStart...].firstIndex(where: \.isNewline) ?? current.endIndex

        let lineRemoved = original[start..<originalLineEnd]
        if !lineRemoved.allSatisfy(isPadding) {
            let promptIndicators = ["$ ", "% ", "# "]
            if promptIndicators.contains(where: { lineRemoved.contains($0) }) {
                throw TextInsertionDiff.Failure.notUnique
            }
        }

        let origAfter = original[originalLineEnd...]
        let currAfter = current[currentLineEnd...]
        var nextOrig = origAfter.startIndex
        var nextCurr = currAfter.startIndex
        while nextOrig < origAfter.endIndex,
              nextCurr < currAfter.endIndex,
              origAfter[nextOrig] == currAfter[nextCurr]
        {
            origAfter.formIndex(after: &nextOrig)
            currAfter.formIndex(after: &nextCurr)
        }
        let commonAfter = origAfter[origAfter.startIndex..<nextOrig]

        // Ensure the line framing / boundary is intact (matches across the line break)
        guard commonAfter.contains(where: \.isNewline) || (origAfter.isEmpty && currAfter.isEmpty) else {
            throw TextInsertionDiff.Failure.notUnique
        }

        let startOffset = current.utf16.distance(from: current.startIndex, to: currentStart)
        var textEnd = currentLineEnd
        while textEnd > currentStart, isPadding(current[current.index(before: textEnd)]) {
            textEnd = current.index(before: textEnd)
        }

        let text = String(current[currentStart..<textEnd])
        guard !text.allSatisfy(isPadding), !text.isEmpty else {
            throw TextInsertionDiff.Failure.noInsertion
        }

        return TextInsertionDiff.Insertion(
            text: text,
            range: NSRange(location: startOffset, length: text.utf16.count),
            kind: .terminalLine
        )
    }

    static func isPadding(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\u{00A0}"
    }
}
