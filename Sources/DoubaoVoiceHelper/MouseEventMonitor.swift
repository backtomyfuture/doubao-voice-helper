import AppKit
import CoreGraphics
import Foundation
import DoubaoVoiceHelperCore

enum MouseEventKind {
    case down
    case up
    case dragged
}

enum MouseBindingRole: Equatable {
    case capture
    case unbound
    case toggle
    case hold
    case enter
    case escape

    var displayName: String {
        switch self {
        case .capture: return "鼠标键"
        case .unbound: return "未绑定"
        case .toggle: return "切换式语音"
        case .hold: return "按住式语音"
        case .enter: return "回车"
        case .escape: return "Esc"
        }
    }

    var logName: String {
        switch self {
        case .capture: return "capture"
        case .unbound: return "unbound"
        case .toggle: return "toggle"
        case .hold: return "hold"
        case .enter: return "enter"
        case .escape: return "escape"
        }
    }

    var sessionRole: SessionRole? {
        switch self {
        case .toggle: return .toggle
        case .hold: return .hold
        default: return nil
        }
    }
}

struct MouseButtonEvent {
    let button: Int64
    let kind: MouseEventKind
    let role: MouseBindingRole
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let location: CGPoint

    init(
        button: Int64,
        kind: MouseEventKind,
        role: MouseBindingRole,
        bundleIdentifier: String?,
        processIdentifier: pid_t,
        location: CGPoint = .zero
    ) {
        self.button = button
        self.kind = kind
        self.role = role
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.location = location
    }
}

enum MouseEventMonitorError: Error {
    case alreadyStarted
    case eventTapCreationFailed
}

/// Intercepts the configured extra mouse buttons (button number > 1). Left and
/// right buttons are never observed. Keyboard events are observed only while
/// a dictation session is active, and only to notice Esc.
/// Shared between the main thread, the event-tap thread and helper queues;
/// all mutable state is guarded by `lock`.
final class MouseEventMonitor: @unchecked Sendable {
    struct Configuration {
        var toggleButton: Int64
        var holdButton: Int64
        var enterButton: Int64
        var navigationExcludedBundleIDs: [String]
        var holdExcludedBundleIDs: [String]
        var paused: Bool
        var capturing: Bool
        var listensForEscape: Bool
    }

    private static let syntheticEventTag: Int64 = 0x4442484C5054
    private static let escapeKeyCode: Int64 = 53

    private let callbackHandler: @Sendable (MouseButtonEvent) -> Void
    private let selectionRestorer: AXSelectionRestorer
    private let lock = NSLock()
    private var configuration: Configuration
    private var mouseTap: CFMachPort?
    private var keyTap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var frontmostBundleIdentifier: String?
    private var frontmostProcessIdentifier: pid_t = 0
    private var workspaceObserver: NSObjectProtocol?
    private let probeQueue = DispatchQueue(
        label: "com.jarod.doubao-voice-helper.hold-probe",
        qos: .userInitiated
    )
    private let navigationQueue = DispatchQueue(
        label: "com.jarod.doubao-voice-helper.navigation",
        qos: .userInteractive
    )

    private struct PressState {
        var generation: UInt64 = 0
        var work: DispatchWorkItem?
        var isLong = false
        var tracking = false
        var origin = CGPoint.zero
        var bundleIdentifier: String?
        var processIdentifier: pid_t = 0
        var decision: HoldStartDecision?
    }
    private var pressStates: [Int64: PressState] = [:]
    private var replayingButton: Int64?

    init(
        configuration: Configuration,
        selectionRestorer: AXSelectionRestorer,
        callbackHandler: @escaping @Sendable (MouseButtonEvent) -> Void
    ) {
        self.configuration = configuration
        self.selectionRestorer = selectionRestorer
        self.callbackHandler = callbackHandler
    }

    deinit {
        stop()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    func update(configuration: Configuration) {
        lock.lock()
        self.configuration = configuration
        let keyTap = self.keyTap
        lock.unlock()
        if let keyTap {
            CGEvent.tapEnable(tap: keyTap, enable: configuration.listensForEscape)
        }
    }

    func start() throws {
        guard mouseTap == nil else {
            throw MouseEventMonitorError.alreadyStarted
        }

        trackFrontmostApplication()

        let mouseMask = [CGEventType.otherMouseDown, .otherMouseUp, .otherMouseDragged]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let mouseTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mouseMask,
            callback: { _, type, event, refcon in
                MouseEventMonitor.handleMouseTap(type: type, event: event, refcon: refcon)
            },
            userInfo: refcon
        ) else {
            throw MouseEventMonitorError.eventTapCreationFailed
        }

        // Esc support is optional; the app keeps working if this tap cannot be
        // created.
        let keyTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue,
            callback: { _, type, event, refcon in
                MouseEventMonitor.handleKeyTap(type: type, event: event, refcon: refcon)
            },
            userInfo: refcon
        )

        lock.lock()
        self.mouseTap = mouseTap
        self.keyTap = keyTap
        let listensForEscape = configuration.listensForEscape
        lock.unlock()

        let setup = TapThreadSetup(
            sources: [mouseTap, keyTap].compactMap { $0 }.compactMap {
                CFMachPortCreateRunLoopSource(kCFAllocatorDefault, $0, 0)
            },
            mouseTap: mouseTap,
            keyTap: keyTap
        )
        thread = Thread { [weak self] in
            guard let self else { return }
            let currentRunLoop = CFRunLoopGetCurrent()
            self.lock.lock()
            self.runLoop = currentRunLoop
            self.lock.unlock()
            for source in setup.sources {
                CFRunLoopAddSource(currentRunLoop, source, .commonModes)
            }
            CGEvent.tapEnable(tap: setup.mouseTap, enable: true)
            if let keyTap = setup.keyTap {
                CGEvent.tapEnable(tap: keyTap, enable: listensForEscape)
            }
            CFRunLoopRun()
        }
        thread?.name = "com.jarod.doubao-voice-helper.mouse-events"
        thread?.start()
    }

    func stop() {
        cancelAllPresses()
        lock.lock()
        let taps = [mouseTap, keyTap].compactMap { $0 }
        let runLoop = self.runLoop
        mouseTap = nil
        keyTap = nil
        self.runLoop = nil
        lock.unlock()
        for tap in taps {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop {
            CFRunLoopStop(runLoop)
        }
        thread = nil
    }

    /// CF objects handed to the tap thread once, before it starts.
    private struct TapThreadSetup: @unchecked Sendable {
        let sources: [CFRunLoopSource]
        let mouseTap: CFMachPort
        let keyTap: CFMachPort?
    }

    // MARK: - Frontmost application

    /// Cached so the event tap callback never has to query NSWorkspace.
    private func trackFrontmostApplication() {
        setFrontmost(NSWorkspace.shared.frontmostApplication)
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication
            self?.setFrontmost(application)
        }
    }

    private func setFrontmost(_ application: NSRunningApplication?) {
        lock.lock()
        frontmostBundleIdentifier = application?.bundleIdentifier
        frontmostProcessIdentifier = application?.processIdentifier ?? 0
        lock.unlock()
    }

    private func frontmost() -> (bundleIdentifier: String?, processIdentifier: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        return (frontmostBundleIdentifier, frontmostProcessIdentifier)
    }

    // MARK: - State helpers

    private func currentConfiguration() -> Configuration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    private func role(
        for button: Int64,
        configuration: Configuration
    ) -> MouseBindingRole? {
        guard button > 1 else { return nil }
        if button == configuration.holdButton { return .hold }
        if button == configuration.toggleButton { return .toggle }
        if button == configuration.enterButton { return .enter }
        return nil
    }

    private func isReplaying(_ button: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return replayingButton == button
    }

    private func hasBlockingModifiers(_ event: CGEvent) -> Bool {
        let flags = event.flags
        return flags.contains(.maskCommand) ||
            flags.contains(.maskAlternate) ||
            flags.contains(.maskControl) ||
            flags.contains(.maskShift)
    }

    private func cancelAllPresses() {
        lock.lock()
        for button in pressStates.keys {
            pressStates[button]?.generation &+= 1
            pressStates[button]?.work?.cancel()
        }
        pressStates.removeAll()
        replayingButton = nil
        lock.unlock()
    }

    // MARK: - Hold detection

    private func armPress(
        button: Int64,
        origin: CGPoint,
        quartzPoint: CGPoint,
        bundleIdentifier: String?,
        processIdentifier: pid_t
    ) {
        lock.lock()
        var state = pressStates[button, default: PressState()]
        if state.work != nil || state.isLong || state.tracking {
            lock.unlock()
            return
        }
        state.generation &+= 1
        let generation = state.generation
        state.isLong = false
        state.tracking = true
        state.origin = origin
        state.bundleIdentifier = bundleIdentifier
        state.processIdentifier = processIdentifier
        state.decision = nil
        let work = DispatchWorkItem { [weak self] in
            self?.fireHoldIfNeeded(button: button, generation: generation)
        }
        state.work = work
        pressStates[button] = state
        lock.unlock()

        probeQueue.async { [weak self] in
            guard let self else { return }
            self.selectionRestorer.capture(
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
            let decision = HoldTargetProbe.decision(
                point: quartzPoint,
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
            self.lock.lock()
            guard var live = self.pressStates[button],
                  live.generation == generation
            else {
                self.lock.unlock()
                return
            }
            live.decision = decision
            if decision == .veto {
                live.work?.cancel()
                live.work = nil
            }
            let thresholdAlreadyElapsed = live.work == nil &&
                !live.isLong &&
                live.tracking &&
                decision != .veto
            self.pressStates[button] = live
            self.lock.unlock()
            if thresholdAlreadyElapsed {
                self.fireHoldIfNeeded(button: button, generation: generation)
            }
        }

        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + HoldPolicy.threshold,
            execute: work
        )
    }

    private func fireHoldIfNeeded(button: Int64, generation: UInt64) {
        lock.lock()
        guard var state = pressStates[button],
              state.generation == generation,
              !state.isLong
        else {
            lock.unlock()
            return
        }
        state.work = nil
        // A probe that has not answered yet does not block the hold; slow AX
        // hosts would otherwise delay dictation by seconds.
        guard state.decision != .veto else {
            pressStates[button] = state
            lock.unlock()
            return
        }
        state.isLong = true
        pressStates[button] = state
        let bundleIdentifier = state.bundleIdentifier
        let processIdentifier = state.processIdentifier
        let origin = state.origin
        lock.unlock()

        callbackHandler(
            MouseButtonEvent(
                button: button,
                kind: .down,
                role: .hold,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier,
                location: origin
            )
        )
    }

    private func emitHoldDragIfLong(button: Int64, location: CGPoint) {
        lock.lock()
        guard let state = pressStates[button], state.tracking, state.isLong else {
            lock.unlock()
            return
        }
        let bundleIdentifier = state.bundleIdentifier
        let processIdentifier = state.processIdentifier
        lock.unlock()
        callbackHandler(
            MouseButtonEvent(
                button: button,
                kind: .dragged,
                role: .hold,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier,
                location: location
            )
        )
    }

    private func abortPressIfMoved(_ button: Int64, cursor: CGPoint) {
        lock.lock()
        guard var state = pressStates[button], state.tracking, !state.isLong else {
            lock.unlock()
            return
        }
        let distance = hypot(cursor.x - state.origin.x, cursor.y - state.origin.y)
        guard distance > HoldPolicy.preStartMoveTolerance else {
            lock.unlock()
            return
        }
        state.generation &+= 1
        state.work?.cancel()
        state.work = nil
        state.decision = .veto
        pressStates[button] = state
        lock.unlock()
        selectionRestorer.clear()
    }

    private struct PressFinish {
        var wasLong: Bool
        var bundleIdentifier: String?
        var processIdentifier: pid_t
        var origin: CGPoint
    }

    private func finishPress(_ button: Int64) -> PressFinish? {
        lock.lock()
        defer { lock.unlock() }
        guard var state = pressStates[button], state.tracking else {
            return nil
        }
        state.generation &+= 1
        state.work?.cancel()
        state.work = nil
        let finish = PressFinish(
            wasLong: state.isLong,
            bundleIdentifier: state.bundleIdentifier,
            processIdentifier: state.processIdentifier,
            origin: state.origin
        )
        state.isLong = false
        state.tracking = false
        pressStates[button] = state
        return finish
    }

    private func releasePress(_ button: Int64, at location: CGPoint) {
        guard let finish = finishPress(button) else { return }
        if finish.wasLong {
            callbackHandler(
                MouseButtonEvent(
                    button: button,
                    kind: .up,
                    role: .hold,
                    bundleIdentifier: finish.bundleIdentifier,
                    processIdentifier: finish.processIdentifier,
                    location: finish.origin
                )
            )
        } else {
            selectionRestorer.clear()
            replayClick(button: button, at: location)
        }
    }

    private func isLongPress(_ button: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let state = pressStates[button] else { return false }
        return state.tracking && state.isLong
    }

    /// Short presses of the hold button were swallowed on the way down, so
    /// the original click is replayed to keep its native meaning.
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
        source?.userData = Self.syntheticEventTag
        let mouseButton = CGMouseButton(rawValue: UInt32(button)) ?? .center
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: mouseButton
            )
            event?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
            event?.setIntegerValueField(.mouseEventButtonNumber, value: button)
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Finder

    /// Finder ignores the raw side buttons, so they are translated into its
    /// navigation shortcuts.
    private func handleFinderNavigation(
        role: MouseBindingRole,
        button: Int64,
        bundleIdentifier: String?,
        isDown: Bool
    ) -> Bool {
        guard BundleExclusion.matches(bundleIdentifier, in: ["com.apple.finder"]) else {
            return false
        }

        let shortcut: KeyboardShortcut?
        if role == .enter || (button == 3 && role != .toggle) {
            shortcut = KeyboardShortcut(keyCode: 33, modifiers: [.command])
        } else if role == .toggle || (button == 4 && role != .enter) {
            shortcut = KeyboardShortcut(keyCode: 30, modifiers: [.command])
        } else {
            shortcut = nil
        }

        guard let shortcut else {
            return false
        }

        if isDown {
            navigationQueue.async {
                try? CoreGraphicsShortcutEmitter().tap(shortcut)
            }
        }
        return true
    }

    // MARK: - Tap callbacks

    private func reenableTapsIfNeeded() {
        lock.lock()
        let mouseTap = self.mouseTap
        let keyTap = self.keyTap
        let listensForEscape = configuration.listensForEscape
        lock.unlock()
        if let mouseTap {
            CGEvent.tapEnable(tap: mouseTap, enable: true)
        }
        if let keyTap {
            CGEvent.tapEnable(tap: keyTap, enable: listensForEscape)
        }
    }

    private static func monitor(from refcon: UnsafeMutableRawPointer?) -> MouseEventMonitor? {
        guard let refcon else { return nil }
        return Unmanaged<MouseEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
    }

    private static func handleKeyTap(
        type: CGEventType,
        event: CGEvent,
        refcon: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        guard let monitor = monitor(from: refcon) else {
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            monitor.reenableTapsIfNeeded()
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventKeycode) == escapeKeyCode,
              monitor.currentConfiguration().listensForEscape
        else {
            return Unmanaged.passUnretained(event)
        }
        // Esc still reaches the focused app and Doubao, so a single press
        // resets both.
        monitor.callbackHandler(
            MouseButtonEvent(
                button: -1,
                kind: .down,
                role: .escape,
                bundleIdentifier: nil,
                processIdentifier: 0,
                location: NSEvent.mouseLocation
            )
        )
        return Unmanaged.passUnretained(event)
    }

    private static func handleMouseTap(
        type: CGEventType,
        event: CGEvent,
        refcon: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        guard let monitor = monitor(from: refcon) else {
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            monitor.reenableTapsIfNeeded()
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        let isDragged = type == .otherMouseDragged
        let isDown = type == .otherMouseDown
        let isUp = type == .otherMouseUp
        guard isDragged || isDown || isUp else {
            return Unmanaged.passUnretained(event)
        }

        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard button > 1, !monitor.isReplaying(button) else {
            return Unmanaged.passUnretained(event)
        }

        let configuration = monitor.currentConfiguration()
        let (bundleIdentifier, processIdentifier) = monitor.frontmost()
        let appKitLocation = NSEvent.mouseLocation
        let quartzPoint = event.location

        if configuration.capturing {
            if isDown {
                monitor.callbackHandler(
                    MouseButtonEvent(
                        button: button,
                        kind: .down,
                        role: .capture,
                        bundleIdentifier: bundleIdentifier,
                        processIdentifier: processIdentifier,
                        location: appKitLocation
                    )
                )
            }
            return Unmanaged.passUnretained(event)
        }

        guard !configuration.paused else {
            return Unmanaged.passUnretained(event)
        }

        guard let role = monitor.role(for: button, configuration: configuration) else {
            if isDown {
                monitor.callbackHandler(
                    MouseButtonEvent(
                        button: button,
                        kind: .down,
                        role: .unbound,
                        bundleIdentifier: bundleIdentifier,
                        processIdentifier: processIdentifier,
                        location: appKitLocation
                    )
                )
            }
            return Unmanaged.passUnretained(event)
        }

        let excludedList = role == .hold
            ? configuration.holdExcludedBundleIDs
            : configuration.navigationExcludedBundleIDs
        if BundleExclusion.matches(bundleIdentifier, in: excludedList) {
            if monitor.handleFinderNavigation(
                role: role,
                button: button,
                bundleIdentifier: bundleIdentifier,
                isDown: isDown
            ) {
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if role == .hold {
            if isDragged {
                monitor.abortPressIfMoved(button, cursor: appKitLocation)
                monitor.emitHoldDragIfLong(button: button, location: appKitLocation)
                return monitor.isLongPress(button) ? nil : Unmanaged.passUnretained(event)
            }
            if isDown {
                let clickCount = event.getIntegerValueField(.mouseEventClickState)
                if clickCount > 1 || monitor.hasBlockingModifiers(event) {
                    return Unmanaged.passUnretained(event)
                }
                monitor.armPress(
                    button: button,
                    origin: appKitLocation,
                    quartzPoint: quartzPoint,
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier
                )
                return nil
            }
            monitor.releasePress(button, at: quartzPoint)
            return nil
        }

        if isDown {
            monitor.callbackHandler(
                MouseButtonEvent(
                    button: button,
                    kind: .down,
                    role: role,
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier,
                    location: appKitLocation
                )
            )
        }
        return nil
    }
}
