import ApplicationServices
import CoreGraphics
import Foundation

public enum HoldPolicy {
    public static let threshold: TimeInterval = 0.28
    public static let preStartMoveTolerance: CGFloat = 6
    public static let cancelArmDistance: CGFloat = 70
    public static let cancelDisarmDistance: CGFloat = 45
    public static let cancelDeadZone: CGFloat = 15
    public static let wechatPreemptDelay: TimeInterval = 0.25
    public static let physicalPollInterval: TimeInterval = 1.0 / 60.0
    public static let probeTimeout: Float = 0.35
    public static let selectionCaptureTimeout: Float = 0.03
}

public struct HoldCancelState: Equatable, Sendable {
    public var distance: CGFloat
    public var armed: Bool
    public var showsCancelHint: Bool

    public init(distance: CGFloat, armed: Bool, showsCancelHint: Bool) {
        self.distance = distance
        self.armed = armed
        self.showsCancelHint = showsCancelHint
    }

    public static func from(
        origin: CGPoint,
        cursor: CGPoint,
        previouslyArmed: Bool
    ) -> HoldCancelState {
        let distance = hypot(cursor.x - origin.x, cursor.y - origin.y)
        let armed: Bool
        if previouslyArmed {
            armed = distance >= HoldPolicy.cancelDisarmDistance
        } else {
            armed = distance >= HoldPolicy.cancelArmDistance
        }
        return HoldCancelState(
            distance: distance,
            armed: armed,
            showsCancelHint: armed && distance >= HoldPolicy.cancelDeadZone
        )
    }
}

public enum HoldStartDecision: String, Equatable, Sendable {
    case start
    case veto
}

public enum WeChatInputRegion {
    public static let bundleID = "com.tencent.xinWeChat"
    public static let mainWindowTitles: Set<String> = ["微信", "WeChat"]
    public static let chatPaneLeftInset: CGFloat = 220
    public static let inputTopRatio: CGFloat = 0.62
    public static let toolbarHeight: CGFloat = 36
    public static let rightInset: CGFloat = 8

    public static func inputRegion(inWindow frame: CGRect) -> CGRect {
        let top = frame.minY + frame.height * inputTopRatio
        let bottom = frame.maxY - toolbarHeight
        let left = frame.minX + chatPaneLeftInset
        let right = frame.maxX - rightInset
        guard bottom > top, right > left else { return .null }
        return CGRect(
            x: left,
            y: top,
            width: right - left,
            height: bottom - top
        )
    }

    public static func isSidebar(_ point: CGPoint, inWindow frame: CGRect) -> Bool {
        point.x < frame.minX + chatPaneLeftInset && frame.contains(point)
    }

    public static func contains(_ point: CGPoint, inWindow frame: CGRect) -> Bool {
        inputRegion(inWindow: frame).contains(point)
    }
}

public enum HoldStartEvaluator {
    public static let vetoRoles: Set<String> = [
        "AXButton",
        "AXLink",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXMenuButton",
        "AXMenuItem",
        "AXScrollBar",
        "AXSlider",
        "AXDisclosureTriangle",
        "AXIncrementor",
        "AXTab",
    ]

    public static func decision(
        bundleIdentifier: String?,
        wechatContainsPoint: Bool?,
        hitRole: String?,
        ancestorRoles: [String]
    ) -> HoldStartDecision {
        if bundleIdentifier == WeChatInputRegion.bundleID {
            if wechatContainsPoint == false {
                return .veto
            }
            return .start
        }
        if let hitRole, vetoRoles.contains(hitRole) {
            return .veto
        }
        if ancestorRoles.contains(where: { vetoRoles.contains($0) }) {
            return .veto
        }
        return .start
    }
}

public enum HoldTargetProbe {
    public static func decision(
        point: CGPoint,
        processIdentifier: pid_t,
        bundleIdentifier: String?
    ) -> HoldStartDecision {
        if bundleIdentifier == WeChatInputRegion.bundleID {
            switch wechatRegion(point: point, processIdentifier: processIdentifier) {
            case .sidebar:
                return .veto
            case .composer, .unknown:
                return .start
            }
        }

        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, HoldPolicy.probeTimeout)
        guard let hit = element(at: point, app: app) else {
            return .start
        }
        let hitRole = role(of: hit)
        var ancestors: [String] = []
        var current: AXUIElement? = hit
        for _ in 0..<12 {
            guard let element = current else { break }
            var parent: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(
                element,
                kAXParentAttribute as CFString,
                &parent
            )
            guard error == .success, let parent else { break }
            let parentElement = parent as! AXUIElement
            ancestors.append(role(of: parentElement))
            current = parentElement
        }
        return HoldStartEvaluator.decision(
            bundleIdentifier: bundleIdentifier,
            wechatContainsPoint: nil,
            hitRole: hitRole,
            ancestorRoles: ancestors
        )
    }

    public enum WeChatRegion: Equatable {
        case composer
        case sidebar
        case unknown
    }

    public static func wechatRegion(
        point: CGPoint,
        processIdentifier: pid_t
    ) -> WeChatRegion {
        let app = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(app, HoldPolicy.probeTimeout)
        guard let windows = windows(of: app), !windows.isEmpty else {
            return .unknown
        }
        for window in windows {
            guard let frame = axFrame(of: window), frame.contains(point) else {
                continue
            }
            if WeChatInputRegion.isSidebar(point, inWindow: frame) {
                return .sidebar
            }
            return .composer
        }
        return .unknown
    }

    private static func element(at point: CGPoint, app: AXUIElement) -> AXUIElement? {
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(
            app,
            Float(point.x),
            Float(point.y),
            &hit
        )
        guard error == .success else { return nil }
        return hit
    }

    private static func windows(of app: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            app,
            kAXWindowsAttribute as CFString,
            &value
        )
        guard error == .success, let array = value as? [AXUIElement] else {
            return nil
        }
        return array
    }

    private static func role(of element: AXUIElement) -> String {
        stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
    }

    private static func stringAttribute(
        _ element: AXUIElement,
        _ name: CFString
    ) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name, &value)
        guard error == .success else { return nil }
        return value as? String
    }

    private static func axFrame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionRef
        ) == .success,
            AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeRef
            ) == .success,
            let positionValue = positionRef,
            let sizeValue = sizeRef
        else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}

public enum BundleExclusion {
    public static func matches(
        _ bundleIdentifier: String?,
        in list: [String]
    ) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return false
        }
        return list.contains {
            bundleIdentifier == $0 || bundleIdentifier.hasPrefix($0 + ".")
        }
    }
}
