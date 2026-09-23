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
}

struct MouseButtonEvent {
    let button: Int64
    let kind: MouseEventKind
    let role: MouseBindingRole
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let location: CGPoint
    let preservesSelection: Bool

    init(
        button: Int64,
        kind: MouseEventKind,
        role: MouseBindingRole,
        bundleIdentifier: String?,
        processIdentifier: pid_t,
        location: CGPoint = .zero,
        preservesSelection: Bool = false
    ) {
        self.button = button
        self.kind = kind
        self.role = role
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.location = location
        self.preservesSelection = preservesSelection
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
        var navigationExcludedBundleIDs: [String]
        var holdExcludedBundleIDs: [String]
        var paused: Bool
        var capturing: Bool
        var wechatHoldPreemptEnabled: Bool
        var swallowEscape: Bool
    }

    private static let syntheticEventTag: Int64 = 0x4442484C5054

    private let callbackHandler: (MouseButtonEvent) -> Void
    private let selectionRestorer: AXSelectionRestorer
    private let lock = NSLock()
    private var configuration: Configuration
    private var eventTap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let probeQueue = DispatchQueue(
        label: "com.jarod.doubao-voice-helper.hold-probe",
        qos: .userInitiated
    )
    private struct PressState {
        var generation: UInt64 = 0
        var work: DispatchWorkItem?
        var preemptWork: DispatchWorkItem?
        var isLong = false
        var tracking = false
        var origin = CGPoint.zero
        var quartzPoint = CGPoint.zero
        var bundleIdentifier: String?
        var processIdentifier: pid_t = 0
        var decision: HoldStartDecision?
        var preempted = false
        var startedAt: TimeInterval = 0
        var deferredDown = false
        var deliveredDown = false
    }
    private var pressStates: [Int64: PressState] = [:]
    private var replayingButton: Int64?
    private var physicalPoller: DispatchSourceTimer?
    private var movePoller: DispatchSourceTimer?
    private let navigationQueue = DispatchQueue(
        label: "com.jarod.doubao-voice-helper.navigation",
        qos: .userInteractive
    )
    private lazy var syntheticSource: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = Self.syntheticEventTag
        return source
    }()

    init(
        configuration: Configuration,
        selectionRestorer: AXSelectionRestorer,
        callbackHandler: @escaping (MouseButtonEvent) -> Void
    ) {
        self.configuration = configuration
        self.selectionRestorer = selectionRestorer
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

        let eventTypes: [CGEventType] = [
            .otherMouseDown,
            .otherMouseUp,
            .otherMouseDragged,
            .keyDown,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { result, type in
            result | (CGEventMask(1) << type.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon in
                MouseEventMonitor.handleTap(
                    proxy,
                    type: type,
                    event: event,
                    refcon: refcon
                )
            },
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
        cancelAllPresses()
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
        guard button > 1 else { return nil }
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
        button <= 1
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
            pressStates[button]?.preemptWork?.cancel()
        }
        pressStates.removeAll()
        replayingButton = nil
        lock.unlock()
        stopPhysicalPoller()
        stopMovePoller()
    }

    private func armPress(
        button: Int64,
        origin: CGPoint,
        quartzPoint: CGPoint,
        bundleIdentifier: String?,
        processIdentifier: pid_t,
        wechatPreemptEnabled: Bool
    ) {
        guard button > 1 else { return }
        lock.lock()
        var state = pressStates[button, default: PressState()]
        if state.work != nil || state.isLong || state.tracking {
            lock.unlock()
            return
        }
        state.generation &+= 1
        let generation = state.generation
        state.work?.cancel()
        state.preemptWork?.cancel()
        state.isLong = false
        state.tracking = true
        state.origin = origin
        state.quartzPoint = quartzPoint
        state.bundleIdentifier = bundleIdentifier
        state.processIdentifier = processIdentifier
        state.decision = nil
        state.preempted = false
        state.startedAt = ProcessInfo.processInfo.systemUptime
        state.deferredDown = false
        state.deliveredDown = true
        let work = DispatchWorkItem { [weak self] in
            self?.fireHoldIfNeeded(
                button: button,
                generation: generation
            )
        }
        state.work = work
        pressStates[button] = state
        lock.unlock()

        selectionRestorer.capture(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier
        )

        let isWeChat = wechatPreemptEnabled &&
            button == 0 &&
            bundleIdentifier == WeChatInputRegion.bundleID
        if isWeChat {
            scheduleWeChatPreempt(
                button: button,
                generation: generation,
                quartzPoint: quartzPoint
            )
        }

        probeQueue.async { [weak self] in
            let decision = HoldTargetProbe.decision(
                point: quartzPoint,
                processIdentifier: processIdentifier,
                bundleIdentifier: bundleIdentifier
            )
            guard let self else { return }
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
                live.preemptWork?.cancel()
                live.preemptWork = nil
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
        if button == 0 {
            startMovePoller(button: button, generation: generation)
        }
    }

    private func scheduleWeChatPreempt(
        button: Int64,
        generation: UInt64,
        quartzPoint: CGPoint
    ) {
        let work = DispatchWorkItem { [weak self] in
            self?.preemptLeftButton(
                button: button,
                generation: generation,
                quartzPoint: quartzPoint
            )
        }
        lock.lock()
        guard var state = pressStates[button],
              state.generation == generation
        else {
            lock.unlock()
            return
        }
        state.preemptWork?.cancel()
        state.preemptWork = work
        let elapsed = ProcessInfo.processInfo.systemUptime - state.startedAt
        pressStates[button] = state
        lock.unlock()
        let delay = max(0, HoldPolicy.wechatPreemptDelay - elapsed)
        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + delay,
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
        let decision = state.decision
        let bundleIdentifier = state.bundleIdentifier
        let processIdentifier = state.processIdentifier
        let origin = state.origin
        let quartzPoint = state.quartzPoint
        let alreadyPreempted = state.preempted
        let deferredDown = state.deferredDown
        if decision == .veto {
            state.work = nil
            pressStates[button] = state
            lock.unlock()
            deliverDeferredDownIfNeeded(button)
            return
        }
        state.isLong = true
        state.work = nil
        pressStates[button] = state
        lock.unlock()
        stopMovePoller()

        if button == 0,
           !alreadyPreempted,
           !deferredDown,
           bundleIdentifier == WeChatInputRegion.bundleID
        {
            preemptLeftButton(
                button: button,
                generation: generation,
                quartzPoint: quartzPoint
            )
        }
        callbackHandler(
            MouseButtonEvent(
                button: button,
                kind: .down,
                role: .hold,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: processIdentifier,
                location: origin,
                preservesSelection: deferredDown
            )
        )
    }

    private func preemptLeftButton(
        button: Int64,
        generation: UInt64,
        quartzPoint: CGPoint
    ) {
        lock.lock()
        guard var state = pressStates[button],
              state.generation == generation,
              !state.preempted
        else {
            lock.unlock()
            return
        }
        guard Self.physicalButtonDown(button) else {
            lock.unlock()
            return
        }
        state.preempted = true
        pressStates[button] = state
        lock.unlock()
        postSyntheticLeftMouseUp(at: quartzPoint)
        startPhysicalPoller(button: button, generation: generation)
    }

    private func postSyntheticLeftMouseUp(
        at quartzPoint: CGPoint,
        tap: CGEventTapLocation = .cgSessionEventTap
    ) {
        guard let source = syntheticSource else { return }
        let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: quartzPoint,
            mouseButton: .left
        )
        up?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        up?.post(tap: tap)
    }

    private func startPhysicalPoller(button: Int64, generation: UInt64) {
        stopPhysicalPoller()
        let poller = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInteractive)
        )
        poller.schedule(
            deadline: .now() + HoldPolicy.physicalPollInterval,
            repeating: HoldPolicy.physicalPollInterval
        )
        poller.setEventHandler { [weak self] in
            guard let self else { return }
            if !Self.physicalButtonDown(button) {
                self.stopPhysicalPoller()
                self.releasePress(button, viaPhysicalPoll: true)
                return
            }
            self.emitHoldDragIfLong(button: button, generation: generation)
        }
        lock.lock()
        physicalPoller = poller
        lock.unlock()
        poller.resume()
    }

    private func stopPhysicalPoller() {
        lock.lock()
        let poller = physicalPoller
        physicalPoller = nil
        lock.unlock()
        poller?.cancel()
    }

    private func emitHoldDragIfLong(button: Int64, generation: UInt64) {
        lock.lock()
        guard let state = pressStates[button],
              state.generation == generation,
              state.isLong
        else {
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
                location: NSEvent.mouseLocation
            )
        )
    }

    private func abortPressIfMoved(_ button: Int64, cursor: CGPoint) -> Bool {
        lock.lock()
        guard var state = pressStates[button], !state.isLong else {
            lock.unlock()
            return false
        }
        let distance = hypot(cursor.x - state.origin.x, cursor.y - state.origin.y)
        guard distance > HoldPolicy.preStartMoveTolerance else {
            lock.unlock()
            return false
        }
        state.generation &+= 1
        state.work?.cancel()
        state.preemptWork?.cancel()
        state.work = nil
        state.preemptWork = nil
        pressStates[button] = state
        lock.unlock()
        selectionRestorer.clear()
        stopMovePoller()
        return true
    }

    private func startMovePoller(button: Int64, generation: UInt64) {
        stopMovePoller()
        let poller = DispatchSource.makeTimerSource(
            queue: DispatchQueue.global(qos: .userInteractive)
        )
        poller.schedule(
            deadline: .now() + HoldPolicy.physicalPollInterval,
            repeating: HoldPolicy.physicalPollInterval
        )
        poller.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let matches = self.pressStates[button]?.generation == generation &&
                self.pressStates[button]?.tracking == true &&
                self.pressStates[button]?.isLong == false
            self.lock.unlock()
            guard matches else {
                self.stopMovePoller()
                return
            }
            if self.abortPressIfMoved(button, cursor: NSEvent.mouseLocation) {
                self.stopMovePoller()
            }
        }
        lock.lock()
        movePoller = poller
        lock.unlock()
        poller.resume()
    }

    private func stopMovePoller() {
        lock.lock()
        let poller = movePoller
        movePoller = nil
        lock.unlock()
        poller?.cancel()
    }

    private func deliverDeferredDownIfNeeded(_ button: Int64) {
        lock.lock()
        guard var state = pressStates[button],
              state.deferredDown,
              !state.isLong
        else {
            lock.unlock()
            return
        }
        state.deferredDown = false
        state.deliveredDown = true
        let origin = state.quartzPoint
        pressStates[button] = state
        lock.unlock()
        postMouseEvent(button: button, isDown: true, at: origin)
        let current = quartzLocation()
        if hypot(current.x - origin.x, current.y - origin.y) > 1 {
            postMouseEvent(button: button, isDown: true, at: current, drag: true)
        }
    }

    private struct PressFinish {
        var wasLong: Bool
        var wasPreempted: Bool
        var deferredDown: Bool
        var deliveredDown: Bool
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
        state.preemptWork?.cancel()
        state.work = nil
        state.preemptWork = nil
        let finish = PressFinish(
            wasLong: state.isLong,
            wasPreempted: state.preempted,
            deferredDown: state.deferredDown,
            deliveredDown: state.deliveredDown,
            bundleIdentifier: state.bundleIdentifier,
            processIdentifier: state.processIdentifier,
            origin: state.origin
        )
        state.isLong = false
        state.tracking = false
        state.preempted = false
        state.deferredDown = false
        pressStates[button] = state
        return finish
    }

    private func releasePress(_ button: Int64, viaPhysicalPoll: Bool) {
        guard let finish = finishPress(button) else { return }
        stopPhysicalPoller()
        stopMovePoller()
        let bundleIdentifier = finish.bundleIdentifier
        let processIdentifier = finish.processIdentifier
        let origin = finish.origin
        if finish.wasPreempted, button == 0, viaPhysicalPoll {
            postSyntheticLeftMouseUp(at: quartzLocation(), tap: .cghidEventTap)
        }
        if !finish.wasLong {
            selectionRestorer.clear()
        }
        if finish.wasLong {
            callbackHandler(
                MouseButtonEvent(
                    button: button,
                    kind: .up,
                    role: .hold,
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier,
                    location: origin
                )
            )
        } else if !passesThroughPrimaryButton(button), !viaPhysicalPoll {
            replayClick(button: button, at: quartzLocation())
        }
    }

    private func quartzLocation() -> CGPoint {
        let appKit = NSEvent.mouseLocation
        let height = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        return CGPoint(x: appKit.x, y: height - appKit.y)
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
        source?.userData = Self.syntheticEventTag
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
        down?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        up?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
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
            // 后退：Cmd + [ (kVK_ANSI_LeftBracket = 33)
            shortcut = KeyboardShortcut(keyCode: 33, modifiers: [.command])
        } else if role == .toggle || (button == 4 && role != .enter) {
            // 前进：Cmd + ] (kVK_ANSI_RightBracket = 30)
            shortcut = KeyboardShortcut(keyCode: 30, modifiers: [.command])
        } else {
            shortcut = nil
        }

        guard let shortcut else {
            return false
        }

        if isDown {
            navigationQueue.async {
                let emitter = CoreGraphicsShortcutEmitter()
                try? emitter.tap(shortcut)
            }
        }

        return true
    }

    private static func physicalButtonDown(_ button: Int64) -> Bool {
        let mouseButton = CGMouseButton(rawValue: UInt32(button)) ?? .left
        return CGEventSource.buttonState(.hidSystemState, button: mouseButton)
    }

    private static func handleTap(
        _ proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent,
        refcon: UnsafeMutableRawPointer?
    ) -> Unmanaged<CGEvent>? {
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<MouseEventMonitor>
            .fromOpaque(refcon)
            .takeUnretainedValue()

        if event.getIntegerValueField(.eventSourceUserData) == MouseEventMonitor.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = monitor.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let configuration = monitor.currentConfiguration()
        if type == .mouseMoved {
            if monitor.hasDeferredHoldTracking() {
                _ = monitor.abortPressIfMoved(0, cursor: NSEvent.mouseLocation)
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if configuration.swallowEscape, keyCode == 53 {
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
                // Do not swallow physical ESC: allow it to pass through to active app / Doubao IME
                // so a single ESC press resets both the Helper and Doubao's UI.
                return Unmanaged.passUnretained(event)
            }
            return Unmanaged.passUnretained(event)
        }

        let isDragged = type == .otherMouseDragged
        let isDown = type == .otherMouseDown
        let isUp = type == .otherMouseUp
        guard isDragged || isDown || isUp else {
            return Unmanaged.passUnretained(event)
        }

        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard button > 1 else {
            return Unmanaged.passUnretained(event)
        }
        let passesThrough = monitor.passesThroughPrimaryButton(button)
        if monitor.isReplaying(button) {
            return Unmanaged.passUnretained(event)
        }
        let application = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = application?.bundleIdentifier
        let processIdentifier = application?.processIdentifier ?? 0
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
        let role = monitor.role(
            for: button,
            configuration: configuration
        )
        guard let role else {
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

        let excluded: Bool
        switch role {
        case .hold:
            excluded = BundleExclusion.matches(
                bundleIdentifier,
                in: configuration.holdExcludedBundleIDs
            )
        case .toggle, .enter:
            excluded = BundleExclusion.matches(
                bundleIdentifier,
                in: configuration.navigationExcludedBundleIDs
            )
        default:
            excluded = false
        }
        guard !excluded else {
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
                _ = monitor.abortPressIfMoved(button, cursor: appKitLocation)
                monitor.emitHoldDragIfLong(
                    button: button,
                    generation: monitor.currentGeneration(for: button)
                )
                if monitor.shouldSwallowHoldMouseTraffic(button) {
                    return nil
                }
                return Unmanaged.passUnretained(event)
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
                    processIdentifier: processIdentifier,
                    wechatPreemptEnabled: configuration.wechatHoldPreemptEnabled
                )
                return passesThrough
                    ? Unmanaged.passUnretained(event)
                    : nil
            }
            if isUp {
                let swallowUp = monitor.shouldSwallowHoldMouseUp(button)
                monitor.releasePress(button, viaPhysicalPoll: false)
                if swallowUp {
                    return nil
                }
                return passesThrough
                    ? Unmanaged.passUnretained(event)
                    : nil
            }
            return Unmanaged.passUnretained(event)
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

        return passesThrough
            ? Unmanaged.passUnretained(event)
            : nil
    }

    private func currentGeneration(for button: Int64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return pressStates[button]?.generation ?? 0
    }

    private func shouldSwallowHoldMouseTraffic(_ button: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let state = pressStates[button], state.tracking else {
            return false
        }
        return state.isLong || state.preempted
    }

    private func shouldSwallowHoldMouseUp(_ button: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pressStates[button]?.preempted == true
    }

    private func hasDeferredHoldTracking() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let state = pressStates[0] else { return false }
        return state.tracking && state.deferredDown && !state.deliveredDown && !state.isLong
    }

    private func postMouseEvent(
        button: Int64,
        isDown: Bool,
        at location: CGPoint,
        drag: Bool = false
    ) {
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
        let mouseType: CGEventType
        let mouseButton: CGMouseButton
        switch button {
        case 0:
            mouseType = drag ? .leftMouseDragged : (isDown ? .leftMouseDown : .leftMouseUp)
            mouseButton = .left
        case 1:
            mouseType = drag ? .rightMouseDragged : (isDown ? .rightMouseDown : .rightMouseUp)
            mouseButton = .right
        default:
            mouseType = drag ? .otherMouseDragged : (isDown ? .otherMouseDown : .otherMouseUp)
            mouseButton = CGMouseButton(rawValue: UInt32(button)) ?? .left
        }
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: mouseType,
            mouseCursorPosition: location,
            mouseButton: mouseButton
        )
        event?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventTag)
        if button >= 2 {
            event?.setIntegerValueField(.mouseEventButtonNumber, value: button)
        }
        event?.post(tap: .cghidEventTap)
    }
}
