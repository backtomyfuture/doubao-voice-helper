import AppKit
import CoreGraphics
import Foundation
import DoubaoVoiceHelperCore

enum MouseEventKind {
    case down
    case up
}

enum MouseBindingRole: Equatable {
    case capture
    case unbound
    case toggle
    case hold
    case enter

    var displayName: String {
        switch self {
        case .capture: return "鼠标键"
        case .unbound: return "未绑定"
        case .toggle: return "切换式语音"
        case .hold: return "按住式语音"
        case .enter: return "回车"
        }
    }

    var logName: String {
        switch self {
        case .capture: return "capture"
        case .unbound: return "unbound"
        case .toggle: return "toggle"
        case .hold: return "hold"
        case .enter: return "enter"
        }
    }
}

struct MouseButtonEvent {
    let button: Int64
    let kind: MouseEventKind
    let role: MouseBindingRole
    let bundleIdentifier: String?
    let processIdentifier: pid_t

    init(
        button: Int64,
        kind: MouseEventKind,
        role: MouseBindingRole,
        bundleIdentifier: String?,
        processIdentifier: pid_t
    ) {
        self.button = button
        self.kind = kind
        self.role = role
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }
}

enum MouseEventMonitorError: Error {
    case alreadyStarted
    case eventTapCreationFailed
}

final class MouseEventMonitor {
    struct Configuration {
        var toggleButton: Int64
        var holdButton: Int64
        var enterButton: Int64
        var excludedBundleIDs: [String]
        var paused: Bool
        var capturing: Bool
    }

    private let callbackHandler: (MouseButtonEvent) -> Void
    private let lock = NSLock()
    private var configuration: Configuration
    private var eventTap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private struct PressState {
        var generation: UInt64 = 0
        var work: DispatchWorkItem?
        var isLong = false
    }
    private var pressStates: [Int64: PressState] = [:]
    private var replayingButton: Int64?

    init(
        configuration: Configuration,
        callbackHandler: @escaping (MouseButtonEvent) -> Void
    ) {
        self.configuration = configuration
        self.callbackHandler = callbackHandler
    }

    deinit {
        stop()
    }

    func update(configuration: Configuration) {
        lock.lock()
        self.configuration = configuration
        lock.unlock()
    }

    func start() throws {
        guard eventTap == nil else {
            throw MouseEventMonitorError.alreadyStarted
        }

        let mask =
            (CGEventMask(1) << CGEventType.otherMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.otherMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.leftMouseUp.rawValue) |
            (CGEventMask(1) << CGEventType.rightMouseDown.rawValue) |
            (CGEventMask(1) << CGEventType.rightMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: UnsafeMutableRawPointer(
                Unmanaged.passUnretained(self).toOpaque()
            )
        ) else {
            throw MouseEventMonitorError.eventTapCreationFailed
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            tap,
            0
        )
        thread = Thread { [weak self] in
            guard let self else { return }
            let currentRunLoop = CFRunLoopGetCurrent()
            self.runLoop = currentRunLoop
            CFRunLoopAddSource(
                currentRunLoop,
                source,
                .commonModes
            )
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread?.name = "com.jarod.doubao-voice-helper.mouse-events"
        thread?.start()
    }

    func stop() {
        lock.lock()
        for button in pressStates.keys {
            pressStates[button]?.generation &+= 1
            pressStates[button]?.work?.cancel()
        }
        pressStates.removeAll()
        replayingButton = nil
        lock.unlock()

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        eventTap = nil
        runLoop = nil
        thread = nil
    }

    private func currentConfiguration() -> Configuration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    private func role(
        for button: Int64,
        configuration: Configuration
    ) -> MouseBindingRole? {
        if button == configuration.holdButton {
            return .hold
        }
        if button == configuration.toggleButton {
            return .toggle
        }
        if button == configuration.enterButton {
            return .enter
        }
        return nil
    }

    private func isReplaying(_ button: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return replayingButton == button
    }

    private func passesThroughPrimaryButton(_ button: Int64) -> Bool {
        button == 0 || button == 1
    }

    private func armPress(
        button: Int64,
        bundleIdentifier: String?,
        processIdentifier: pid_t
    ) {
        lock.lock()
        var state = pressStates[button, default: PressState()]
        state.generation &+= 1
        let generation = state.generation
        state.work?.cancel()
        state.isLong = false
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard var state = self.pressStates[button],
                  state.generation == generation
            else {
                self.lock.unlock()
                return
            }
            state.isLong = true
            state.work = nil
            self.pressStates[button] = state
            self.lock.unlock()
            self.callbackHandler(
                MouseButtonEvent(
                    button: button,
                    kind: .down,
                    role: .hold,
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier
                )
            )
        }
        state.work = work
        pressStates[button] = state
        lock.unlock()
        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + .milliseconds(250),
            execute: work
        )
    }

    private func finishPress(_ button: Int64) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard var state = pressStates[button],
              state.work != nil || state.isLong
        else {
            return nil
        }
        state.generation &+= 1
        state.work?.cancel()
        state.work = nil
        let wasLong = state.isLong
        state.isLong = false
        pressStates[button] = state
        return wasLong
    }

    private func replayClick(button: Int64, at location: CGPoint) {
        lock.lock()
        replayingButton = button
        lock.unlock()
        defer {
            lock.lock()
            replayingButton = nil
            lock.unlock()
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let mouseType: CGEventType
        let mouseUpType: CGEventType
        let mouseButton: CGMouseButton
        switch button {
        case 0:
            mouseType = .leftMouseDown
            mouseUpType = .leftMouseUp
            mouseButton = .left
        case 1:
            mouseType = .rightMouseDown
            mouseUpType = .rightMouseUp
            mouseButton = .right
        default:
            mouseType = .otherMouseDown
            mouseUpType = .otherMouseUp
            mouseButton = CGMouseButton(rawValue: UInt32(button)) ?? .left
        }
        let down = CGEvent(
            mouseEventSource: source,
            mouseType: mouseType,
            mouseCursorPosition: location,
            mouseButton: mouseButton
        )
        let up = CGEvent(
            mouseEventSource: source,
            mouseType: mouseUpType,
            mouseCursorPosition: location,
            mouseButton: mouseButton
        )
        if button >= 2 {
            down?.setIntegerValueField(
                .mouseEventButtonNumber,
                value: button
            )
            up?.setIntegerValueField(
                .mouseEventButtonNumber,
                value: button
            )
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static let eventTapCallback: CGEventTapCallBack = {
        _, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<MouseEventMonitor>
            .fromOpaque(refcon)
            .takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = monitor.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .otherMouseDown || type == .otherMouseUp ||
              type == .leftMouseDown || type == .leftMouseUp ||
              type == .rightMouseDown || type == .rightMouseUp
        else {
            return Unmanaged.passUnretained(event)
        }

        let configuration = monitor.currentConfiguration()
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let passesThrough = monitor.passesThroughPrimaryButton(button)
        if monitor.isReplaying(button) {
            return Unmanaged.passUnretained(event)
        }
        let application = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = application?.bundleIdentifier
        let processIdentifier = application?.processIdentifier ?? 0

        if configuration.capturing {
            let isDown = type == .otherMouseDown ||
                type == .leftMouseDown ||
                type == .rightMouseDown
            if isDown {
                monitor.callbackHandler(
                    MouseButtonEvent(
                        button: button,
                        kind: .down,
                        role: .capture,
                        bundleIdentifier: bundleIdentifier,
                        processIdentifier: processIdentifier
                    )
                )
            }
            return Unmanaged.passUnretained(event)
        }

        guard !configuration.paused else {
            return Unmanaged.passUnretained(event)
        }
        let role = monitor.role(
            for: button,
            configuration: configuration
        )
        guard let role else {
            let isDown = type == .otherMouseDown ||
                type == .leftMouseDown ||
                type == .rightMouseDown
            if isDown {
                monitor.callbackHandler(
                    MouseButtonEvent(
                        button: button,
                        kind: .down,
                        role: .unbound,
                        bundleIdentifier: bundleIdentifier,
                        processIdentifier: processIdentifier
                    )
                )
            }
            return Unmanaged.passUnretained(event)
        }

        let excluded = configuration.excludedBundleIDs.contains {
            guard let bundleIdentifier else { return false }
            return bundleIdentifier == $0 ||
                bundleIdentifier.hasPrefix($0 + ".")
        }
        guard !excluded else {
            return Unmanaged.passUnretained(event)
        }

        let isDown = type == .otherMouseDown ||
            type == .leftMouseDown ||
            type == .rightMouseDown
        if role == .hold {
            if isDown {
                monitor.armPress(
                    button: button,
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier
                )
                return passesThrough
                    ? Unmanaged.passUnretained(event)
                    : nil
            }
            if let wasLong = monitor.finishPress(button) {
                if wasLong {
                    monitor.callbackHandler(
                        MouseButtonEvent(
                            button: button,
                            kind: .up,
                            role: .hold,
                            bundleIdentifier: bundleIdentifier,
                            processIdentifier: processIdentifier
                        )
                    )
                } else if !passesThrough {
                    monitor.replayClick(button: button, at: event.location)
                }
                return passesThrough
                    ? Unmanaged.passUnretained(event)
                    : nil
            }
            return Unmanaged.passUnretained(event)
        }

        if isDown {
            let eventRole: MouseBindingRole = role
            monitor.callbackHandler(
                MouseButtonEvent(
                    button: button,
                    kind: .down,
                    role: eventRole,
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier
                )
            )
        }

        return passesThrough
            ? Unmanaged.passUnretained(event)
            : nil
    }
}
