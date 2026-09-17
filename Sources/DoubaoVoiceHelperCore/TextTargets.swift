import ApplicationServices
import AppKit
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

public struct InsertedText: @unchecked Sendable {
    public let text: String
    public let range: NSRange
    public let currentText: String
    public let anchor: TextSessionAnchor

    public init(
        text: String,
        range: NSRange,
        currentText: String,
        anchor: TextSessionAnchor
    ) {
        self.text = text
        self.range = range
        self.currentText = currentText
        self.anchor = anchor
    }
}

public protocol TextTargetAdapter {
    func beginSession() throws -> TextSessionAnchor
    func waitForInsertedText(
        after anchor: TextSessionAnchor,
        timeout: TimeInterval
    ) throws -> InsertedText
    func replace(_ insertion: InsertedText, with text: String) throws
}

public enum TextTargetError: Error {
    case noFocusedElement
    case inaccessibleValue
    case inaccessibleSelection
    case focusChanged
    case noInsertion
    case insertionNotUnique
    case settleTimeout
    case writeFailed
    case verificationFailed
}

public final class AXTextAdapter: TextTargetAdapter, @unchecked Sendable {
    private let sampleInterval: TimeInterval
    private let stableSampleCount: Int

    public init(
        sampleInterval: TimeInterval = 0.08,
        stableSampleCount: Int = 2
    ) {
        self.sampleInterval = sampleInterval
        self.stableSampleCount = max(stableSampleCount, 1)
    }

    public func beginSession() throws -> TextSessionAnchor {
        let element = try focusedElement()
        let snapshot = try snapshot(for: element)
        return TextSessionAnchor(
            identity: snapshot.identity,
            originalText: snapshot.text,
            selectedRange: snapshot.selectedRange,
            element: element
        )
    }

    public func waitForInsertedText(
        after anchor: TextSessionAnchor,
        timeout: TimeInterval
    ) throws -> InsertedText {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        var previousText: String?
        var stableSamples = 0
        var sawChange = false

        while Date() < deadline {
            let focused = try focusedElement()
            guard CFEqual(focused, anchor.element) else {
                throw TextTargetError.focusChanged
            }
            let current = try snapshot(for: anchor.element)
            guard current.identity == anchor.identity else {
                throw TextTargetError.focusChanged
            }

            if current.text != anchor.originalText {
                sawChange = true
            }

            if sawChange, current.text == previousText {
                stableSamples += 1
            } else {
                stableSamples = 0
            }
            previousText = current.text

            if sawChange, stableSamples >= stableSampleCount {
                return try makeInsertion(anchor: anchor, current: current.text)
            }

            Thread.sleep(forTimeInterval: sampleInterval)
        }

        throw sawChange ? TextTargetError.insertionNotUnique : TextTargetError.settleTimeout
    }

    public func replace(_ insertion: InsertedText, with text: String) throws {
        let focused = try focusedElement()
        guard CFEqual(focused, insertion.anchor.element) else {
            throw TextTargetError.focusChanged
        }
        let current = try snapshot(for: insertion.anchor.element)
        guard current.identity == insertion.anchor.identity else {
            throw TextTargetError.focusChanged
        }
        guard current.text == insertion.currentText else {
            throw TextTargetError.focusChanged
        }

        let updated = (current.text as NSString).replacingCharacters(
            in: insertion.range,
            with: text
        )
        let valueResult = AXUIElementSetAttributeValue(
            insertion.anchor.element,
            kAXValueAttribute as CFString,
            updated as CFTypeRef
        )
        guard valueResult == .success else {
            throw TextTargetError.writeFailed
        }

        var newSelection = CFRange(
            location: insertion.range.location + (text as NSString).length,
            length: 0
        )
        guard let selectionValue = AXValueCreate(
            .cfRange,
            &newSelection
        ) else {
            throw TextTargetError.writeFailed
        }
        let selectionResult = AXUIElementSetAttributeValue(
            insertion.anchor.element,
            kAXSelectedTextRangeAttribute as CFString,
            selectionValue
        )
        guard selectionResult == .success else {
            throw TextTargetError.writeFailed
        }

        let verified = try snapshot(for: insertion.anchor.element)
        guard verified.identity == insertion.anchor.identity,
              verified.text == updated,
              verified.selectedRange.location == newSelection.location
        else {
            throw TextTargetError.verificationFailed
        }
    }

    private struct Snapshot {
        let identity: FocusIdentity
        let text: String
        let selectedRange: NSRange
    }

    private func focusedElement() throws -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        guard let value = copyAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: system
        ) else {
            throw TextTargetError.noFocusedElement
        }
        return value as! AXUIElement
    }

    private func snapshot(for element: AXUIElement) throws -> Snapshot {
        guard let text = copyAttribute(
            kAXValueAttribute as CFString,
            from: element
        ) as? String
        else {
            throw TextTargetError.inaccessibleValue
        }
        guard let selectedRange = selectedRange(for: element) else {
            throw TextTargetError.inaccessibleSelection
        }

        var processIdentifier: pid_t = 0
        _ = AXUIElementGetPid(element, &processIdentifier)
        let application = NSRunningApplication(
            processIdentifier: processIdentifier
        )
        let bundleIdentifier = application?.bundleIdentifier ?? "unknown"
        let role = copyAttribute(
            kAXRoleAttribute as CFString,
            from: element
        ) as? String ?? "unknown"
        let windowHash = (
            copyAttribute(kAXWindowAttribute as CFString, from: element)
                .map { Int(CFHash($0)) }
        ) ?? 0

        return Snapshot(
            identity: FocusIdentity(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier,
                role: role,
                windowHash: windowHash
            ),
            text: text,
            selectedRange: selectedRange
        )
    }

    private func selectedRange(for element: AXUIElement) -> NSRange? {
        guard let value = copyAttribute(
            kAXSelectedTextRangeAttribute as CFString,
            from: element
        ) else {
            return nil
        }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private func makeInsertion(
        anchor: TextSessionAnchor,
        current: String
    ) throws -> InsertedText {
        let original = anchor.originalText as NSString
        let currentNSString = current as NSString
        let start = anchor.selectedRange.location
        let selectedLength = anchor.selectedRange.length
        let originalLength = original.length

        guard start >= 0,
              selectedLength >= 0,
              start + selectedLength <= originalLength
        else {
            throw TextTargetError.insertionNotUnique
        }

        let prefix = original.substring(
            with: NSRange(location: 0, length: start)
        )
        let suffix = original.substring(
            from: start + selectedLength
        )
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length

        guard current.hasPrefix(prefix),
              current.hasSuffix(suffix),
              currentNSString.length >= prefixLength + suffixLength
        else {
            throw TextTargetError.insertionNotUnique
        }

        let insertedLength = currentNSString.length - prefixLength - suffixLength
        guard insertedLength > 0 else {
            throw TextTargetError.noInsertion
        }

        let inserted = currentNSString.substring(
            with: NSRange(location: prefixLength, length: insertedLength)
        )
        return InsertedText(
            text: inserted,
            range: NSRange(location: start, length: insertedLength),
            currentText: current,
            anchor: anchor
        )
    }

    private func copyAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            attribute,
            &value
        )
        guard error == .success else {
            return nil
        }
        return value
    }
}

public enum TargetSupportLevel: String, CaseIterable, Sendable {
    case validated
    case triggerOnly
    case unverified
}

public struct TargetCompatibility: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let bundleIdentifier: String
    public let supportLevel: TargetSupportLevel

    public init(
        name: String,
        bundleIdentifier: String,
        supportLevel: TargetSupportLevel
    ) {
        self.id = bundleIdentifier
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.supportLevel = supportLevel
    }

    public static let minimumMatrix = [
        TargetCompatibility(
            name: "Terminal.app",
            bundleIdentifier: "com.apple.Terminal",
            supportLevel: .unverified
        ),
        TargetCompatibility(
            name: "Ghostty",
            bundleIdentifier: "com.mitchellh.ghostty",
            supportLevel: .unverified
        ),
        TargetCompatibility(
            name: "Cursor / VS Code",
            bundleIdentifier: "com.todesktop.230313m46w4u92",
            supportLevel: .unverified
        ),
    ]
}
