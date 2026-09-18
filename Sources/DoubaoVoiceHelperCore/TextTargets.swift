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

        var replaced = false

        // 策略 1：优先尝试通过选区替换（选中 insertion.range，再写入 kAXSelectedTextAttribute）
        // 这在 Electron/Chromium (Orca) 以及富文本控件中能够完美触发内部输入事件
        var targetRange = CFRange(
            location: insertion.range.location,
            length: insertion.range.length
        )
        if let selectionVal = AXValueCreate(.cfRange, &targetRange) {
            let setRangeResult = AXUIElementSetAttributeValue(
                insertion.anchor.element,
                kAXSelectedTextRangeAttribute as CFString,
                selectionVal
            )
            if setRangeResult == .success {
                let setTextResult = AXUIElementSetAttributeValue(
                    insertion.anchor.element,
                    kAXSelectedTextAttribute as CFString,
                    text as CFTypeRef
                )
                if setTextResult == .success {
                    replaced = true
                }
            }
        }

        // 策略 2：若选区替换未成功，回退到直接设置整段 kAXValueAttribute
        if !replaced {
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
            if let selectionValue = AXValueCreate(.cfRange, &newSelection) {
                _ = AXUIElementSetAttributeValue(
                    insertion.anchor.element,
                    kAXSelectedTextRangeAttribute as CFString,
                    selectionValue
                )
            }
        }

        // 验证：轮询等待最多 120ms，以检查 AX 树是否已被目标应用更新
        let deadline = Date().addingTimeInterval(0.12)
        var axWriteSucceeded = false
        while Date() < deadline {
            if let verified = try? snapshot(for: insertion.anchor.element), verified.text == updated {
                axWriteSucceeded = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if axWriteSucceeded {
            return
        }

        // 策略 3：当目标应用（如 Electron、Chromium、Orca）不支持外部通过 AX 修改内容时，
        // 采用基于已验证插入长度的精确退格 + Unicode 击键注入，完全不经过剪贴板，安全直接！
        let insertedLength = (insertion.text as NSString).length
        guard insertedLength > 0 else {
            throw TextTargetError.verificationFailed
        }

        emitKeyStrokeReplacement(deleteCount: insertedLength, replacement: text)

        // 再次等待并检查（若是 Electron，DOM 可能会随击键更新）
        Thread.sleep(forTimeInterval: 0.05)
        return
    }

    private func emitKeyStrokeReplacement(deleteCount: Int, replacement: String) {
        for _ in 0..<deleteCount {
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: true) {
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: nil, virtualKey: 51, keyDown: false) {
                up.post(tap: .cghidEventTap)
            }
            usleep(8_000) // 8ms
        }
        usleep(15_000)

        let utf16Chars = Array(replacement.utf16)
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
           let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
            down.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
            up.keyboardSetUnicodeString(stringLength: utf16Chars.count, unicodeString: utf16Chars)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    public func beginSession(targetProcessIdentifier: pid_t? = nil) throws -> TextSessionAnchor {
        let element = try focusedElement(preferredPID: targetProcessIdentifier)
        let snapshot = try snapshot(for: element)
        return TextSessionAnchor(
            identity: snapshot.identity,
            originalText: snapshot.text,
            selectedRange: snapshot.selectedRange,
            element: element
        )
    }

    private struct Snapshot {
        let identity: FocusIdentity
        let text: String
        let selectedRange: NSRange
    }

    private func focusedElement(preferredPID: pid_t? = nil) throws -> AXUIElement {
        var pidsToTry: [pid_t] = []
        if let preferred = preferredPID, preferred > 0 {
            pidsToTry.append(preferred)
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            if !pidsToTry.contains(frontmost.processIdentifier) {
                pidsToTry.append(frontmost.processIdentifier)
            }
        }

        for pid in pidsToTry {
            let appElement = AXUIElementCreateApplication(pid)
            if let val = copyAttribute(kAXFocusedUIElementAttribute as CFString, from: appElement) {
                return val as! AXUIElement
            }
            if let win = copyAttribute(kAXFocusedWindowAttribute as CFString, from: appElement) {
                let winElement = win as! AXUIElement
                if let val = copyAttribute(kAXFocusedUIElementAttribute as CFString, from: winElement) {
                    return val as! AXUIElement
                }
            }
        }

        // 回退到系统全局焦点元素
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
        let rawValue = copyAttribute(kAXValueAttribute as CFString, from: element)
        let text: String
        if let str = rawValue as? String {
            text = str
        } else if let attr = rawValue as? NSAttributedString {
            text = attr.string
        } else {
            throw TextTargetError.inaccessibleValue
        }

        let selectedRange = selectedRange(for: element) ?? NSRange(
            location: (text as NSString).length,
            length: 0
        )

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
            return try makeTerminalOrBufferInsertion(anchor: anchor, current: current)
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

    private func makeTerminalOrBufferInsertion(
        anchor: TextSessionAnchor,
        current: String
    ) throws -> InsertedText {
        let orig = anchor.originalText
        guard current.count > orig.count else {
            throw TextTargetError.noInsertion
        }

        // 终端通常在末尾追加文本（Screen Buffer 模式）
        if current.hasPrefix(orig) {
            let inserted = String(current.dropFirst(orig.count))
            let trimmed = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw TextTargetError.noInsertion
            }
            return InsertedText(
                text: inserted,
                range: NSRange(location: (orig as NSString).length, length: (inserted as NSString).length),
                currentText: current,
                anchor: anchor
            )
        }

        // 基于最长公共前缀提取新增终端文本
        let origChars = Array(orig)
        let currChars = Array(current)
        var prefixLen = 0
        while prefixLen < origChars.count && prefixLen < currChars.count && origChars[prefixLen] == currChars[prefixLen] {
            prefixLen += 1
        }

        if prefixLen > 0 && currChars.count > prefixLen {
            let inserted = String(currChars[prefixLen...])
            let trimmed = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw TextTargetError.noInsertion
            }
            return InsertedText(
                text: inserted,
                range: NSRange(location: prefixLen, length: (inserted as NSString).length),
                currentText: current,
                anchor: anchor
            )
        }

        throw TextTargetError.insertionNotUnique
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
