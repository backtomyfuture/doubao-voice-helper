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
        guard removed.allSatisfy(isPadding) else {
            throw TextInsertionDiff.Failure.notUnique
        }
        guard !added.isEmpty else {
            throw TextInsertionDiff.Failure.noInsertion
        }
        guard !added.contains(where: \.isNewline) else {
            throw TextInsertionDiff.Failure.notUnique
        }

        let startOffset = current.utf16.distance(from: current.startIndex, to: currentStart)
        let endOffset = current.utf16.distance(from: current.startIndex, to: currentEnd)

        var textEnd = currentEnd
        if let caretUTF16, caretUTF16 >= startOffset, caretUTF16 <= endOffset {
            // A caret inside the changed span tells exactly where typing
            // stopped; everything after it must be padding.
            let caret = String.Index(utf16Offset: caretUTF16, in: current)
            guard current[caret..<currentEnd].allSatisfy(isPadding) else {
                throw TextInsertionDiff.Failure.notUnique
            }
            textEnd = caret
        } else if !removed.isEmpty {
            // Padding was consumed, so the trailing blanks belong to the box.
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

    static func isPadding(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\u{00A0}"
    }
}
