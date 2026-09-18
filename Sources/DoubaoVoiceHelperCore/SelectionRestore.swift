import ApplicationServices
import Foundation

public enum SelectionRestorePolicy {
    public static func shouldCapture(bundleIdentifier: String?) -> Bool {
        bundleIdentifier != WeChatInputRegion.bundleID
    }

    public static func isReplaceable(range: NSRange, textLength: Int) -> Bool {
        range.length > 0 &&
            range.location >= 0 &&
            textLength >= 0 &&
            range.location + range.length <= textLength
    }
}

public final class AXSelectionRestorer: @unchecked Sendable {
    private struct Snapshot {
        var element: AXUIElement
        var range: NSRange
        var fullText: String
    }

    private let lock = NSLock()
    private var snapshot: Snapshot?

    public init() {}

    public var canRestore: Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot != nil
    }

    public func capture(
        processIdentifier: pid_t,
        bundleIdentifier: String?
    ) {
        clear()
        guard SelectionRestorePolicy.shouldCapture(
            bundleIdentifier: bundleIdentifier
        ) else {
            return
        }
        guard let captured = Self.readSnapshot(
            processIdentifier: processIdentifier
        ) else {
            return
        }
        guard SelectionRestorePolicy.isReplaceable(
            range: captured.range,
            textLength: (captured.fullText as NSString).length
        ) else {
            return
        }
        lock.lock()
        snapshot = captured
        lock.unlock()
    }

    @discardableResult
    public func restore() -> Bool {
        lock.lock()
        let snapshot = snapshot
        lock.unlock()
        guard let snapshot else { return false }

        var range = CFRange(
            location: snapshot.range.location,
            length: snapshot.range.length
        )
        guard let value = AXValueCreate(.cfRange, &range) else {
            return false
        }
        let error = AXUIElementSetAttributeValue(
            snapshot.element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
        return error == .success
    }

    public func clear() {
        lock.lock()
        snapshot = nil
        lock.unlock()
    }

    private static func readSnapshot(
        processIdentifier: pid_t
    ) -> Snapshot? {
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, HoldPolicy.selectionCaptureTimeout)
        var focused: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard focusedError == .success, let focused else {
            return nil
        }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(
            element,
            HoldPolicy.selectionCaptureTimeout
        )

        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &textRef
        ) == .success,
            let fullText = textRef as? String
        else {
            return nil
        }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
            let rangeRef
        else {
            return nil
        }
        var cfRange = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) else {
            return nil
        }
        let range = NSRange(location: cfRange.location, length: cfRange.length)
        return Snapshot(element: element, range: range, fullText: fullText)
    }
}
