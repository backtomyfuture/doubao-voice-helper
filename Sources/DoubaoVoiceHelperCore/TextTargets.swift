import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Foundation

public struct FocusIdentity: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String
    public let role: String
    public let windowHash: Int

    public init(
        processIdentifier: pid_t,
        bundleIdentifier: String,
        role: String,
        windowHash: Int
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.role = role
        self.windowHash = windowHash
    }
}

public struct TextSessionAnchor: @unchecked Sendable {
    public let identity: FocusIdentity
    public let originalText: String
    public let selectedRange: NSRange
    public let element: AXUIElement

    public init(
        identity: FocusIdentity,
        originalText: String,
        selectedRange: NSRange,
        element: AXUIElement
    ) {
        self.identity = identity
        self.originalText = originalText
        self.selectedRange = selectedRange
        self.element = element
    }
}

public struct SettleTiming: Equatable, Sendable {
    /// Seconds from the start of waiting until the value first differed from
    /// the anchor; `nil` when it never changed.
    public let firstChange: TimeInterval?
    /// Seconds from the start of waiting until the value was considered final.
    public let settled: TimeInterval
    /// Value-change notifications delivered by the target app.
    public let notifications: Int

    public init(firstChange: TimeInterval?, settled: TimeInterval, notifications: Int) {
        self.firstChange = firstChange
        self.settled = settled
        self.notifications = notifications
    }
}

public struct InsertedText: @unchecked Sendable {
    public let text: String
    public let range: NSRange
    public let kind: TextInsertionDiff.Kind
    public let currentText: String
    public let anchor: TextSessionAnchor
    public let timing: SettleTiming

    public init(
        text: String,
        range: NSRange,
        kind: TextInsertionDiff.Kind,
        currentText: String,
        anchor: TextSessionAnchor,
        timing: SettleTiming
    ) {
        self.text = text
        self.range = range
        self.kind = kind
        self.currentText = currentText
        self.anchor = anchor
        self.timing = timing
    }
}

public enum ReplacementMethod: String, Sendable {
    case accessibility
    case keystrokes
}

/// How the focused control exposes dictated text.
public enum TextTargetMode: String, Sendable {
    /// An editable field whose AX value and selection describe its content.
    case standard
    /// A terminal whose AX value is the read-only screen buffer.
    case terminal
}

public protocol TextTargetAdapter {
    func beginSession(
        targetProcessIdentifier: pid_t?,
        messagingTimeout: Float
    ) throws -> TextSessionAnchor
    func waitForInsertedText(
        after anchor: TextSessionAnchor,
        timeout: TimeInterval,
        mode: TextTargetMode
    ) throws -> InsertedText
    func replace(
        _ insertion: InsertedText,
        with text: String,
        allowKeystrokeFallback: Bool
    ) throws -> ReplacementMethod
}

public enum TextTargetError: Error, Equatable {
    case noFocusedElement
    case inaccessibleValue
    case inaccessibleSelection
    case focusChanged
    case noInsertion
    case insertionNotUnique
    case notSettled
    case settleTimeout
    case writeFailed
    case keystrokeFallbackDisabled
    case keystrokeFallbackUnsafe
    case verificationFailed
}

public final class AXTextAdapter: TextTargetAdapter, @unchecked Sendable {
    private let detectInterval: TimeInterval
    private let pollInterval: TimeInterval
    private let quietPeriod: TimeInterval
    private let writeVerificationWindow: TimeInterval

    public init(
        detectInterval: TimeInterval = 0.03,
        pollInterval: TimeInterval = 0.05,
        quietPeriod: TimeInterval = SettlePolicy.quietPeriod,
        writeVerificationWindow: TimeInterval = 0.3
    ) {
        self.detectInterval = detectInterval
        self.pollInterval = pollInterval
        self.quietPeriod = quietPeriod
        self.writeVerificationWindow = writeVerificationWindow
    }

    public func beginSession(
        targetProcessIdentifier: pid_t? = nil,
        messagingTimeout: Float = 0.2
    ) throws -> TextSessionAnchor {
        let element = try focusedElement(
            preferredPID: targetProcessIdentifier,
            messagingTimeout: messagingTimeout
        )
        let snapshot = try snapshot(for: element)
        return TextSessionAnchor(
            identity: snapshot.identity,
            originalText: snapshot.text,
            selectedRange: snapshot.selectedRange,
            element: element
        )
    }

    // MARK: - Settle detection

    public func waitForInsertedText(
        after anchor: TextSessionAnchor,
        timeout: TimeInterval,
        mode: TextTargetMode = .standard
    ) throws -> InsertedText {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + max(timeout, 0)
        let observation = ValueChangeObservation(
            element: anchor.element,
            processIdentifier: anchor.identity.processIdentifier
        )
        defer { observation?.invalidate() }

        var lastText = anchor.originalText
        var lastChangeAt: TimeInterval?
        var firstChangeAt: TimeInterval?

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            try verifyFocus(anchor)
            let current = try snapshot(for: anchor.element)
            guard current.identity == anchor.identity else {
                throw TextTargetError.focusChanged
            }

            if current.text != lastText {
                lastChangeAt = now
                if firstChangeAt == nil { firstChangeAt = now }
                lastText = current.text
            }

            let changed = current.text != anchor.originalText
            if changed, let lastChangeAt, now - lastChangeAt >= quietPeriod {
                let timing = SettleTiming(
                    firstChange: firstChangeAt.map { $0 - startedAt },
                    settled: now - startedAt,
                    notifications: observation?.notificationCount ?? 0
                )
                return try makeInsertion(
                    anchor: anchor,
                    current: current,
                    timing: timing,
                    mode: mode
                )
            }

            guard now < deadline else {
                throw changed ? TextTargetError.notSettled : TextTargetError.settleTimeout
            }

            let interval = min(changed ? pollInterval : detectInterval, deadline - now)
            if let observation {
                observation.wait(upTo: interval)
            } else {
                Thread.sleep(forTimeInterval: interval)
            }
        }
    }

    private func makeInsertion(
        anchor: TextSessionAnchor,
        current: Snapshot,
        timing: SettleTiming,
        mode: TextTargetMode
    ) throws -> InsertedText {
        do {
            let insertion: TextInsertionDiff.Insertion
            switch mode {
            case .standard:
                insertion = try TextInsertionDiff.compute(
                    original: anchor.originalText,
                    selectedRange: anchor.selectedRange,
                    current: current.text
                )
            case .terminal:
                // A reported selection with length is a user highlight, not
                // the cursor.
                let caret = current.reportedSelection.flatMap { $0.length == 0 ? $0.location : nil }
                insertion = try TerminalInsertionDiff.compute(
                    original: anchor.originalText,
                    current: current.text,
                    caretUTF16: caret
                )
            }
            return InsertedText(
                text: insertion.text,
                range: insertion.range,
                kind: insertion.kind,
                currentText: current.text,
                anchor: anchor,
                timing: timing
            )
        } catch TextInsertionDiff.Failure.noInsertion {
            throw TextTargetError.noInsertion
        } catch {
            throw TextTargetError.insertionNotUnique
        }
    }

    // MARK: - Replacement

    private enum WriteOutcome {
        case applied
        case unchanged
        case changedElsewhere
    }

    public func replace(
        _ insertion: InsertedText,
        with text: String,
        allowKeystrokeFallback: Bool
    ) throws -> ReplacementMethod {
        let element = insertion.anchor.element
        try verifyFocus(insertion.anchor)
        let current = try snapshot(for: element)
        guard current.identity == insertion.anchor.identity,
              current.text == insertion.currentText
        else {
            throw TextTargetError.focusChanged
        }

        if insertion.kind == .terminalLine {
            try replaceInTerminal(insertion, with: text, element: element)
            return .keystrokes
        }

        let expected = (current.text as NSString).replacingCharacters(
            in: insertion.range,
            with: text
        )

        // Selecting the span and writing kAXSelectedText goes through the
        // host's own editing path, which Chromium-based editors require.
        var targetRange = CFRange(
            location: insertion.range.location,
            length: insertion.range.length
        )
        var wrote = false
        if let rangeValue = AXValueCreate(.cfRange, &targetRange),
           AXUIElementSetAttributeValue(
               element,
               kAXSelectedTextRangeAttribute as CFString,
               rangeValue
           ) == .success,
           AXUIElementSetAttributeValue(
               element,
               kAXSelectedTextAttribute as CFString,
               text as CFTypeRef
           ) == .success
        {
            wrote = true
        }

        if !wrote,
           AXUIElementSetAttributeValue(
               element,
               kAXValueAttribute as CFString,
               expected as CFTypeRef
           ) == .success
        {
            var caret = CFRange(
                location: insertion.range.location + (text as NSString).length,
                length: 0
            )
            if let caretValue = AXValueCreate(.cfRange, &caret) {
                _ = AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextRangeAttribute as CFString,
                    caretValue
                )
            }
        }

        switch awaitWrite(
            element: element,
            expected: expected,
            original: insertion.currentText,
            window: writeVerificationWindow
        ) {
        case .applied:
            return .accessibility
        case .changedElsewhere:
            // Something other than our write changed the text; never touch
            // it again because the inserted range is no longer known.
            throw TextTargetError.verificationFailed
        case .unchanged:
            break
        }

        guard allowKeystrokeFallback else {
            throw TextTargetError.keystrokeFallbackDisabled
        }
        let plan = try keystrokePlan(for: insertion, element: element, replacement: text)
        KeystrokeTyper.run(plan)

        switch awaitWrite(
            element: element,
            expected: expected,
            original: insertion.currentText,
            window: writeVerificationWindow + 0.1
        ) {
        case .applied:
            return .keystrokes
        case .unchanged, .changedElsewhere:
            throw TextTargetError.verificationFailed
        }
    }

    private func awaitWrite(
        element: AXUIElement,
        expected: String,
        original: String,
        window: TimeInterval
    ) -> WriteOutcome {
        let deadline = ProcessInfo.processInfo.systemUptime + window
        var last: String?
        repeat {
            if let value = try? snapshot(for: element).text {
                if value == expected { return .applied }
                last = value
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while ProcessInfo.processInfo.systemUptime < deadline
        guard let last else { return .unchanged }
        return last == original ? .unchanged : .changedElsewhere
    }

    /// Terminal buffers are read-only, so the dictated span is erased with
    /// backspaces at the cursor and the replacement is typed. Success means the
    /// text before the insertion point is intact and directly followed by the
    /// replacement; content after it may change (a TUI can open a menu when
    /// "/" is typed), so it is not compared.
    private func replaceInTerminal(
        _ insertion: InsertedText,
        with text: String,
        element: AXUIElement
    ) throws {
        guard insertion.text.unicodeScalars.count == insertion.text.count else {
            throw TextTargetError.keystrokeFallbackUnsafe
        }
        let prefixEnd = String.Index(utf16Offset: insertion.range.location, in: insertion.currentText)
        let expectedPrefix = String(insertion.currentText[..<prefixEnd]) + text

        KeystrokeTyper.run(
            KeystrokeTyper.Plan(deleteCount: insertion.text.count, text: text)
        )

        let deadline = ProcessInfo.processInfo.systemUptime + writeVerificationWindow + 0.3
        repeat {
            if let value = try? snapshot(for: element).text,
               value != insertion.currentText,
               value.hasPrefix(expectedPrefix)
            {
                return
            }
            Thread.sleep(forTimeInterval: 0.03)
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw TextTargetError.verificationFailed
    }

    /// Only proven spans whose caret or selection sits exactly on the inserted
    /// text may be rewritten with synthetic keystrokes; anything else could
    /// delete text the user already had.
    private func keystrokePlan(
        for insertion: InsertedText,
        element: AXUIElement,
        replacement: String
    ) throws -> KeystrokeTyper.Plan {
        guard insertion.kind == .exact else {
            throw TextTargetError.keystrokeFallbackUnsafe
        }
        // Backspace removes one grapheme; clusters built from several scalars
        // (emoji sequences, combining marks) are deleted inconsistently.
        guard insertion.text.unicodeScalars.count == insertion.text.count else {
            throw TextTargetError.keystrokeFallbackUnsafe
        }
        guard let selection = selectedRange(for: element) else {
            throw TextTargetError.keystrokeFallbackUnsafe
        }
        if selection == insertion.range {
            return KeystrokeTyper.Plan(
                deleteCount: replacement.isEmpty ? 1 : 0,
                text: replacement
            )
        }
        let insertionEnd = insertion.range.location + insertion.range.length
        guard selection.length == 0, selection.location == insertionEnd else {
            throw TextTargetError.keystrokeFallbackUnsafe
        }
        return KeystrokeTyper.Plan(deleteCount: insertion.text.count, text: replacement)
    }

    // MARK: - AX helpers

    private struct Snapshot {
        let identity: FocusIdentity
        let text: String
        /// Falls back to the end of the text when the app reports nothing.
        let selectedRange: NSRange
        /// What the app actually reported, if anything.
        let reportedSelection: NSRange?
    }

    private func verifyFocus(_ anchor: TextSessionAnchor) throws {
        let focused = try focusedElement(preferredPID: anchor.identity.processIdentifier)
        guard CFEqual(focused, anchor.element) else {
            throw TextTargetError.focusChanged
        }
    }

    private func focusedElement(
        preferredPID: pid_t? = nil,
        messagingTimeout: Float = 0.2
    ) throws -> AXUIElement {
        var pidsToTry: [pid_t] = []
        if let preferred = preferredPID, preferred > 0 {
            pidsToTry.append(preferred)
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           !pidsToTry.contains(frontmost.processIdentifier)
        {
            pidsToTry.append(frontmost.processIdentifier)
        }

        for pid in pidsToTry {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, messagingTimeout)
            if let value = copyAttribute(kAXFocusedUIElementAttribute as CFString, from: appElement) {
                return value as! AXUIElement
            }
            if let window = copyAttribute(kAXFocusedWindowAttribute as CFString, from: appElement) {
                let windowElement = window as! AXUIElement
                AXUIElementSetMessagingTimeout(windowElement, messagingTimeout)
                if let value = copyAttribute(kAXFocusedUIElementAttribute as CFString, from: windowElement) {
                    return value as! AXUIElement
                }
            }
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        guard let value = copyAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: system
        ) else {
            throw TextTargetError.noFocusedElement
        }
        return value as! AXUIElement
    }

    private func snapshot(for element: AXUIElement) throws -> Snapshot {
        let rawValue = copyAttribute(kAXValueAttribute as CFString, from: element)
        let text: String
        if let string = rawValue as? String {
            text = string
        } else if let attributed = rawValue as? NSAttributedString {
            text = attributed.string
        } else {
            throw TextTargetError.inaccessibleValue
        }

        let reportedSelection = selectedRange(for: element)
        let selectedRange = reportedSelection ?? NSRange(
            location: (text as NSString).length,
            length: 0
        )

        var processIdentifier: pid_t = 0
        _ = AXUIElementGetPid(element, &processIdentifier)
        let bundleIdentifier = NSRunningApplication(
            processIdentifier: processIdentifier
        )?.bundleIdentifier ?? "unknown"
        let role = copyAttribute(kAXRoleAttribute as CFString, from: element) as? String ?? "unknown"
        let windowHash = copyAttribute(kAXWindowAttribute as CFString, from: element)
            .map { Int(CFHash($0)) } ?? 0

        return Snapshot(
            identity: FocusIdentity(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                role: role,
                windowHash: windowHash
            ),
            text: text,
            selectedRange: selectedRange,
            reportedSelection: reportedSelection
        )
    }

    private func selectedRange(for element: AXUIElement) -> NSRange? {
        guard let value = copyAttribute(
            kAXSelectedTextRangeAttribute as CFString,
            from: element
        ) else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private func copyAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }
}

/// Wakes the settle loop as soon as the target posts a value change, while the
/// loop keeps polling for apps that never post notifications.
private final class ValueChangeObservation {
    private let observer: AXObserver
    private let element: AXUIElement
    private let runLoop: CFRunLoop
    private let source: CFRunLoopSource
    private let counter: Counter

    final class Counter {
        var value = 0
    }

    var notificationCount: Int { counter.value }

    init?(element: AXUIElement, processIdentifier: pid_t) {
        var created: AXObserver?
        let callback: AXObserverCallbackWithInfo = { _, _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<Counter>.fromOpaque(refcon).takeUnretainedValue().value += 1
        }
        guard AXObserverCreateWithInfoCallback(processIdentifier, callback, &created) == .success,
              let created
        else {
            return nil
        }
        let counter = Counter()
        guard AXObserverAddNotification(
            created,
            element,
            kAXValueChangedNotification as CFString,
            Unmanaged.passUnretained(counter).toOpaque()
        ) == .success else {
            return nil
        }
        self.observer = created
        self.element = element
        self.counter = counter
        self.runLoop = CFRunLoopGetCurrent()
        self.source = AXObserverGetRunLoopSource(created)
        CFRunLoopAddSource(runLoop, source, .defaultMode)
    }

    func wait(upTo seconds: TimeInterval) {
        guard seconds > 0 else { return }
        _ = CFRunLoopRunInMode(.defaultMode, seconds, true)
    }

    func invalidate() {
        AXObserverRemoveNotification(observer, element, kAXValueChangedNotification as CFString)
        CFRunLoopRemoveSource(runLoop, source, .defaultMode)
    }
}

/// Synthetic typing used only by the keystroke fallback.
public enum KeystrokeTyper {
    struct Plan: Equatable {
        let deleteCount: Int
        let text: String
    }

    private static let deleteKeyCode: CGKeyCode = 51
    // CGEvent silently truncates longer Unicode payloads.
    public static let maxUTF16PerEvent = 20

    static func run(_ plan: Plan) {
        InputSourceGuard.withASCIICapableInputSource {
            for index in 0..<plan.deleteCount {
                post(keyCode: deleteKeyCode, unicode: nil)
                if index % 5 == 4 { usleep(12_000) }
            }
            if plan.deleteCount > 0 { usleep(15_000) }
            for chunk in chunks(of: plan.text) {
                post(keyCode: 0, unicode: Array(chunk.utf16))
                usleep(8_000)
            }
        }
    }

    /// Splits on character boundaries so no chunk exceeds the per-event limit
    /// or breaks a surrogate pair.
    public static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentLength = 0
        for character in text {
            let length = character.utf16.count
            if currentLength + length > maxUTF16PerEvent, !current.isEmpty {
                result.append(current)
                current = ""
                currentLength = 0
            }
            current.append(character)
            currentLength += length
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func post(keyCode: CGKeyCode, unicode: [UniChar]?) {
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown) else {
                continue
            }
            event.flags = []
            if let unicode {
                event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
            }
            event.post(tap: .cghidEventTap)
        }
    }
}

/// Temporarily selects an ASCII-capable keyboard layout so a Chinese input
/// method (including Doubao's) cannot turn synthetic key events into pinyin.
enum InputSourceGuard {
    static func withASCIICapableInputSource(_ body: () -> Void) {
        let original = onMain { () -> TISInputSource? in
            guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  !isASCIICapable(current)
            else {
                return nil
            }
            return current
        }
        guard let original else {
            body()
            return
        }
        let switched = onMain { () -> Bool in
            guard let ascii = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() else {
                return false
            }
            return TISSelectInputSource(ascii) == noErr
        }
        if switched { usleep(40_000) }
        body()
        if switched {
            usleep(20_000)
            onMain { _ = TISSelectInputSource(original) }
        }
    }

    private static func isASCIICapable(_ source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return false
        }
        let value = Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue()
        return CFBooleanGetValue(value)
    }

    private static func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }
}
