import AppKit
import Foundation
import DoubaoVoiceHelperCore

/// The settings a dictation session needs, captured from `AppModel` when a
/// trigger arrives.
struct DictationConfiguration {
    var paused: Bool
    var onboardingCompleted: Bool
    var toggleShortcut: KeyboardShortcut
    var holdShortcut: KeyboardShortcut
    var enterShortcut: KeyboardShortcut
    var macroRules: [MacroRule]
    var keystrokeFallbackBundleIDs: [String]
    var terminalMacroBundleIDs: [String]

    init(settings: AppSettings, paused: Bool) {
        self.paused = paused
        onboardingCompleted = settings.onboardingCompleted
        toggleShortcut = settings.toggleShortcut
        holdShortcut = settings.holdShortcut
        enterShortcut = settings.enterShortcut
        macroRules = settings.macroRules
        keystrokeFallbackBundleIDs = settings.keystrokeFallbackBundleIDs
        terminalMacroBundleIDs = settings.terminalMacroBundleIDs
    }

    var hasEnabledMacroRules: Bool {
        macroRules.contains { $0.isEnabled && !$0.source.isEmpty }
    }

    func shortcut(for role: SessionRole) -> KeyboardShortcut {
        role == .hold ? holdShortcut : toggleShortcut
    }
}

enum DictationPhase: Equatable {
    case idle
    case listening
    case processing
}

@MainActor
protocol DictationCoordinatorDelegate: AnyObject {
    var dictationConfiguration: DictationConfiguration { get }
    func dictationPhaseDidChange(_ phase: DictationPhase)
    func dictationShowOverlay(_ message: String, tone: OverlayTone, autoHide: TimeInterval?)
    func dictationHideOverlay()
    func dictationDidFail(_ message: String)
    func dictationDidCapture(text: String, bundleID: String, matched: Bool)
}

private final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class WriteStateToken: @unchecked Sendable {
    private let lock = NSLock()
    private var writing = false

    var isWritingStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return writing
    }

    func setWriting(_ value: Bool) {
        lock.lock()
        writing = value
        lock.unlock()
    }
}

/// One dictation session. Fields marked "main" are only touched on the main
/// actor; `input` is shared with the serial input queue and guarded by a lock.
private final class ActiveSession: @unchecked Sendable {
    struct InputState {
        var anchor: TextSessionAnchor?
        var replacingSelection = false
        var startEmitted = false
    }

    struct PendingEnter {
        let shortcut: KeyboardShortcut
        let requestedAt: TimeInterval
        var timeoutWorkItem: DispatchWorkItem?
    }

    let id = UUID()
    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }
    let role: SessionRole
    let shortcut: KeyboardShortcut
    let cancellation = CancellationToken()
    let writeState = WriteStateToken()
    let startedAtDate = Date()
    let startedAtUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    let pressOrigin: CGPoint

    // main
    var bundleIdentifier: String?
    var processIdentifier: pid_t
    var phase: SessionPhase = .listening
    var cancelArmed = false
    var anchorStatus = "none"
    var mode: TextTargetMode = .standard
    var pendingEnter: PendingEnter?

    private let lock = NSLock()
    private var inputState = InputState()

    init(
        role: SessionRole,
        shortcut: KeyboardShortcut,
        bundleIdentifier: String?,
        processIdentifier: pid_t,
        pressOrigin: CGPoint
    ) {
        self.role = role
        self.shortcut = shortcut
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.pressOrigin = pressOrigin
    }

    var input: InputState {
        lock.lock()
        defer { lock.unlock() }
        return inputState
    }

    func updateInput(_ body: (inout InputState) -> Void) {
        lock.lock()
        body(&inputState)
        lock.unlock()
    }

    var elapsed: TimeInterval {
        ProcessInfo.processInfo.systemUptime - startedAtUptime
    }
}

private enum MacroJobOutcome: Sendable {
    case replaced(method: ReplacementMethod, firstChangeMs: Int?, decisionMs: Int?, doneMs: Int, text: String, settled: Bool)
    case noMatch(firstChangeMs: Int?, decisionMs: Int?, doneMs: Int, text: String)
    case earlyRejected(decisionMs: Int?, doneMs: Int)
    case failed(error: TextTargetError, message: String?, tone: OverlayTone, doneMs: Int)
    case cancelled(stage: String, doneMs: Int)
    case timedOut(stage: String, doneMs: Int)
}

/// Owns the single dictation session: trigger decisions, Doubao shortcuts,
/// anchor capture, settle detection and macro write-back.
@MainActor
final class DictationCoordinator {
    weak var delegate: DictationCoordinatorDelegate?

    private let shortcutEmitter: ShortcutEmitting
    private let textAdapter: AXTextAdapter
    private let selectionRestorer: AXSelectionRestorer
    private let diagnostics: Diagnostics
    private let sessionRecordStore = SessionRecordStore.defaultStore()

    /// Every synthetic key press goes through this queue so the main thread
    /// never blocks on key timing and start/stop/cancel strokes stay ordered.
    private let inputQueue = DispatchQueue(
        label: "com.jarod.doubao-voice-helper.input",
        qos: .userInteractive
    )
    private var activeSession: ActiveSession?
    private var cooldownUntil = Date.distantPast
    private var backgroundObservationToken: CancellationToken?

    private static let anchorMessagingTimeout: Float = 0.1

    init(
        shortcutEmitter: ShortcutEmitting,
        textAdapter: AXTextAdapter,
        selectionRestorer: AXSelectionRestorer,
        diagnostics: Diagnostics
    ) {
        self.shortcutEmitter = shortcutEmitter
        self.textAdapter = textAdapter
        self.selectionRestorer = selectionRestorer
        self.diagnostics = diagnostics
    }

    var isActive: Bool {
        activeSession != nil
    }

    private var configuration: DictationConfiguration? {
        delegate?.dictationConfiguration
    }

    // MARK: - Triggers

    func handleTrigger(_ event: MouseButtonEvent) {
        guard let configuration else { return }
        switch event.role {
        case .hold, .toggle:
            guard let role = event.role.sessionRole else { return }
            let kind: SessionTriggerKind
            switch event.kind {
            case .down: kind = .down
            case .up: kind = .up
            case .dragged:
                updateHoldCancel(event)
                return
            }
            let action = SessionTriggerPolicy.decide(
                role: role,
                kind: kind,
                active: activeSession.map {
                    ActiveSessionState(role: $0.role, phase: $0.phase, elapsed: $0.elapsed)
                },
                context: SessionTriggerContext(
                    paused: configuration.paused,
                    onboardingCompleted: configuration.onboardingCompleted,
                    inCooldown: Date() < cooldownUntil
                )
            )
            perform(action, for: event, role: role, configuration: configuration)
        case .enter:
            guard event.kind == .down, !configuration.paused else { return }
            sendEnter(configuration.enterShortcut)
        case .capture, .unbound, .escape:
            break
        }
    }

    private func perform(
        _ action: SessionTriggerAction,
        for event: MouseButtonEvent,
        role: SessionRole,
        configuration: DictationConfiguration
    ) {
        switch action {
        case .start:
            beginSession(event, role: role, configuration: configuration)
        case .stop:
            endSession(configuration: configuration)
        case .restart:
            cancel(announce: false, emitCancelShortcut: false)
            cooldownUntil = .distantPast
            beginSession(event, role: role, configuration: configuration)
        case .preemptAndStart:
            diagnostics.event("session_preempted_by_hold", bundleIdentifier: event.bundleIdentifier)
            cancel(announce: false)
            beginSession(event, role: role, configuration: configuration)
        case .ignore(let reason):
            guard reason != .noSession else { return }
            diagnostics.event(
                "session_ignored",
                bundleIdentifier: event.bundleIdentifier,
                detail: reason.rawValue
            )
        }
    }

    // MARK: - Return key handling

    private func emitEnter(
        shortcut: KeyboardShortcut,
        sessionID: UUID,
        bundleIdentifier: String?,
        delayMs: UInt32 = 60_000,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) {
        let emitter = shortcutEmitter
        let shortID = String(sessionID.uuidString.prefix(8)).lowercased()
        inputQueue.async { [weak self] in
            if delayMs > 0 { usleep(delayMs) }
            do {
                try emitter.tap(shortcut)
                DispatchQueue.main.async {
                    self?.diagnostics.event(
                        "enter_emitted",
                        session: shortID,
                        bundleIdentifier: bundleIdentifier
                    )
                    completion?(true)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.delegate?.dictationDidFail("发送回车失败")
                    completion?(false)
                }
            }
        }
    }

    private func sendEnter(_ shortcut: KeyboardShortcut) {
        guard let session = activeSession else {
            emitEnter(shortcut: shortcut, sessionID: UUID(), bundleIdentifier: nil, delayMs: 0) { [weak self] success in
                if success {
                    self?.delegate?.dictationShowOverlay("发送", tone: .send, autoHide: 1.2)
                }
            }
            return
        }

        let config = configuration
        let canProcessMacros = !session.cancelArmed && (config?.hasEnabledMacroRules == true) && (session.input.anchor != nil)

        if !canProcessMacros {
            // Cannot run voice macro: cancel and send return after 60ms delay
            cancel(announce: false, emitCancelShortcut: false)
            emitEnter(shortcut: shortcut, sessionID: session.id, bundleIdentifier: session.bundleIdentifier, delayMs: 60_000) { [weak self] success in
                if success {
                    self?.delegate?.dictationShowOverlay("发送", tone: .send, autoHide: 1.2)
                }
            }
            return
        }

        diagnostics.event("enter_deferred", session: session.shortID, bundleIdentifier: session.bundleIdentifier)

        if session.phase == .listening {
            if let config {
                endSession(configuration: config)
            }
        }

        let sessionID = session.id
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let current = self.activeSession, current.id == sessionID else { return }
                guard let pending = current.pendingEnter else { return }
                if current.writeState.isWritingStarted {
                    // Already writing back, continue waiting for result
                    return
                }
                // Not writing yet: cancel macro, send return
                current.pendingEnter = nil
                current.cancellation.cancel()
                self.diagnostics.event("enter_after_timeout", session: current.shortID, bundleIdentifier: current.bundleIdentifier)
                let waitMs = milliseconds(since: pending.requestedAt)
                self.emitEnter(shortcut: pending.shortcut, sessionID: current.id, bundleIdentifier: current.bundleIdentifier, delayMs: 60_000) { [weak self] _ in
                    self?.delegate?.dictationShowOverlay("发送", tone: .send, autoHide: 1.2)
                }
                self.recordAndFinish(
                    session: current,
                    outcome: "timeout",
                    decision: "none",
                    failure: "enter_timeout",
                    enterStatus: "sent",
                    enterWaitMs: waitMs
                )
            }
        }

        session.pendingEnter = ActiveSession.PendingEnter(
            shortcut: shortcut,
            requestedAt: ProcessInfo.processInfo.systemUptime,
            timeoutWorkItem: item
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    // MARK: - Session lifecycle

    private func beginSession(
        _ event: MouseButtonEvent,
        role: SessionRole,
        configuration: DictationConfiguration
    ) {
        // Cancel any pending background observation from previous session
        backgroundObservationToken?.cancel()
        backgroundObservationToken = nil

        let shortcut = configuration.shortcut(for: role)
        let session = ActiveSession(
            role: role,
            shortcut: shortcut,
            bundleIdentifier: event.bundleIdentifier,
            processIdentifier: event.processIdentifier,
            pressOrigin: event.location
        )
        session.mode = BundleExclusion.matches(event.bundleIdentifier, in: configuration.terminalMacroBundleIDs)
            ? .terminal
            : .standard
        activeSession = session
        delegate?.dictationPhaseDidChange(.listening)
        delegate?.dictationShowOverlay(role == .hold ? "松开以停止" : "听写中", tone: .listening, autoHide: nil)

        if role == .toggle {
            let sessionID = session.id
            DispatchQueue.main.asyncAfter(deadline: .now() + SessionTriggerPolicy.toggleTimeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.activeSession?.id == sessionID else { return }
                    self.diagnostics.event(
                        "session_timeout",
                        session: session.shortID,
                        bundleIdentifier: self.activeSession?.bundleIdentifier
                    )
                    self.cancel(announce: true)
                }
            }
        }

        let captureAnchor = configuration.hasEnabledMacroRules
        let anchorTimeout = Self.anchorMessagingTimeout
        let targetPID = event.processIdentifier
        let bundleID = event.bundleIdentifier
        let shortID = session.shortID
        let adapter = textAdapter
        let restorer = selectionRestorer
        let emitter = shortcutEmitter
        let diagnostics = diagnostics

        inputQueue.async { [weak self] in
            guard !session.cancellation.isCancelled else { return }

            let replacingSelection = role == .hold && restorer.restore()

            var anchorFailed = false
            if captureAnchor {
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    let anchor = try adapter.beginSession(
                        targetProcessIdentifier: targetPID,
                        messagingTimeout: anchorTimeout
                    )
                    session.updateInput { $0.anchor = anchor }
                    session.anchorStatus = "captured"
                    diagnostics.event(
                        "anchor_captured",
                        session: shortID,
                        bundleIdentifier: bundleID,
                        detail: "role=\(anchor.identity.role) length=\(anchor.originalText.count) ms=\(milliseconds(since: started))"
                    )
                } catch {
                    anchorFailed = true
                    let errName = (error as? TextTargetError)?.name ?? "\(error)"
                    session.anchorStatus = errName
                    diagnostics.event(
                        "anchor_failed",
                        session: shortID,
                        bundleIdentifier: bundleID,
                        detail: "\(errName) ms=\(milliseconds(since: started))"
                    )
                }
            }

            do {
                if role == .hold {
                    try emitter.keyDown(shortcut)
                } else {
                    try emitter.tap(shortcut)
                }
                session.updateInput {
                    $0.startEmitted = true
                    $0.replacingSelection = replacingSelection
                }
                diagnostics.event("mouse_session_started", session: shortID, bundleIdentifier: bundleID)
            } catch {
                restorer.clear()
                DispatchQueue.main.async {
                    self?.abandonSession(session.id, message: "无法发送豆包快捷键")
                }
                return
            }

            guard replacingSelection || anchorFailed else { return }
            DispatchQueue.main.async {
                guard let self, self.activeSession?.id == session.id else { return }
                if anchorFailed {
                    // 仅当非微信等不支持应用时提示
                    let isWeChat = bundleID == "com.tencent.xinWeChat"
                    if !isWeChat {
                        self.delegate?.dictationShowOverlay("宏替换不可用", tone: .notice, autoHide: 1.5)
                    }
                } else if session.phase == .listening {
                    self.delegate?.dictationShowOverlay("将替换选中文字", tone: .listening, autoHide: nil)
                }
            }
        }
    }

    private func abandonSession(_ id: UUID, message: String) {
        guard let session = activeSession, session.id == id else { return }
        recordAndFinish(
            session: session,
            outcome: "failed",
            decision: "none",
            failure: "shortcut_failed",
            enterStatus: "none"
        )
        delegate?.dictationDidFail(message)
    }

    private func updateHoldCancel(_ event: MouseButtonEvent) {
        guard let session = activeSession,
              session.role == .hold,
              session.phase == .listening
        else {
            return
        }
        let state = HoldCancelState.from(
            origin: session.pressOrigin,
            cursor: event.location,
            previouslyArmed: session.cancelArmed
        )
        session.cancelArmed = state.armed
        if state.showsCancelHint {
            delegate?.dictationShowOverlay("再拖将停止", tone: .cancelArmed, autoHide: nil)
        } else {
            let message = session.input.replacingSelection ? "将替换选中文字" : "松开以停止"
            delegate?.dictationShowOverlay(message, tone: .listening, autoHide: nil)
        }
    }

    private func endSession(configuration: DictationConfiguration) {
        guard let session = activeSession, session.phase == .listening else {
            return
        }
        session.phase = .processing
        let listened = session.elapsed
        let announceStop = session.cancelArmed
        let processMacros = !announceStop && configuration.hasEnabledMacroRules
        let job = MacroJob(
            sessionID: session.id,
            shortID: session.shortID,
            rules: configuration.macroRules,
            listened: listened,
            mode: session.mode,
            allowKeystrokeFallback: BundleExclusion.matches(
                session.bundleIdentifier,
                in: configuration.keystrokeFallbackBundleIDs
            ),
            bundleID: session.bundleIdentifier
        )
        let sessionID = session.id
        let token = session.cancellation
        let writeState = session.writeState
        let adapter = textAdapter
        let restorer = selectionRestorer
        let emitter = shortcutEmitter
        let diagnostics = diagnostics

        if processMacros {
            delegate?.dictationPhaseDidChange(.processing)
            delegate?.dictationShowOverlay("正在处理", tone: .listening, autoHide: nil)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + SettlePolicy.watchdog(forListeningDuration: listened)
            ) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          let current = self.activeSession,
                          current.id == sessionID,
                          current.phase == .processing
                    else { return }
                    self.diagnostics.event("session_timeout", session: current.shortID, bundleIdentifier: job.bundleID, detail: "processing")
                    token.cancel()
                    self.recordAndFinish(
                        session: current,
                        outcome: "timeout",
                        decision: "none",
                        failure: "watchdog_timeout",
                        enterStatus: "none"
                    )
                }
            }
        }

        inputQueue.async { [weak self] in
            let input = session.input
            do {
                if session.role == .hold {
                    if input.replacingSelection {
                        _ = restorer.restore()
                    }
                    try emitter.keyUp(session.shortcut)
                    restorer.clear()
                } else {
                    try emitter.tap(session.shortcut)
                }
                diagnostics.event("shortcut_emitted", session: session.shortID, bundleIdentifier: job.bundleID)
            } catch {
                token.cancel()
                DispatchQueue.main.async {
                    self?.abandonSession(sessionID, message: "无法停止豆包听写")
                }
                return
            }

            guard processMacros, let anchor = input.anchor else {
                if processMacros {
                    diagnostics.event("macro_skipped", session: session.shortID, bundleIdentifier: job.bundleID, detail: "no_anchor")
                }
                DispatchQueue.main.async {
                    guard let self, let current = self.activeSession, current.id == sessionID else { return }
                    let pending = current.pendingEnter
                    current.pendingEnter = nil
                    pending?.timeoutWorkItem?.cancel()

                    let waitMs = pending.map { milliseconds(since: $0.requestedAt) }
                    let enterStatus = pending != nil ? "sent" : "none"

                    if let pending {
                        self.emitEnter(shortcut: pending.shortcut, sessionID: sessionID, bundleIdentifier: current.bundleIdentifier, delayMs: 60_000) { [weak self] _ in
                            self?.delegate?.dictationShowOverlay("发送", tone: .send, autoHide: 1.2)
                        }
                    }
                    self.recordAndFinish(
                        session: current,
                        outcome: processMacros ? "skippedNoAnchor" : "noMatch",
                        decision: "none",
                        enterStatus: enterStatus,
                        enterWaitMs: waitMs,
                        announceStop: announceStop
                    )
                }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = job.run(
                    anchor: anchor,
                    adapter: adapter,
                    token: token,
                    writeState: writeState,
                    diagnostics: diagnostics
                )
                DispatchQueue.main.async {
                    self?.handleMacroOutcome(outcome, sessionID: sessionID, job: job)
                }
            }
        }
    }

    private func handleMacroOutcome(_ outcome: MacroJobOutcome, sessionID: UUID, job: MacroJob) {
        guard let session = activeSession, session.id == sessionID else { return }
        let pending = session.pendingEnter
        session.pendingEnter = nil
        pending?.timeoutWorkItem?.cancel()

        let waitMs = pending.map { milliseconds(since: $0.requestedAt) }
        let bundleID = session.bundleIdentifier ?? ""

        switch outcome {
        case .replaced(let method, let firstChangeMs, let decisionMs, let doneMs, let text, let settled):
            delegate?.dictationDidCapture(text: text, bundleID: bundleID, matched: true)
            let enterStatus = pending != nil ? "sent" : "none"
            if let pending {
                emitEnter(shortcut: pending.shortcut, sessionID: sessionID, bundleIdentifier: session.bundleIdentifier, delayMs: 60_000) { [weak self] _ in
                    self?.delegate?.dictationShowOverlay("已应用语音宏", tone: .send, autoHide: 1.2)
                }
            } else {
                delegate?.dictationShowOverlay("已应用语音宏", tone: .send, autoHide: 1.2)
            }
            recordAndFinish(
                session: session,
                outcome: "replaced",
                decision: settled ? "settled" : "early",
                method: method.rawValue,
                firstChangeMs: firstChangeMs,
                decisionMs: decisionMs,
                doneMs: doneMs,
                enterStatus: enterStatus,
                enterWaitMs: waitMs
            )

        case .noMatch(let firstChangeMs, let decisionMs, let doneMs, let text):
            delegate?.dictationDidCapture(text: text, bundleID: bundleID, matched: false)
            let enterStatus = pending != nil ? "sent" : "none"
            if let pending {
                emitEnter(shortcut: pending.shortcut, sessionID: sessionID, bundleIdentifier: session.bundleIdentifier, delayMs: 60_000) { [weak self] _ in
                    self?.delegate?.dictationShowOverlay("发送", tone: .send, autoHide: 1.2)
                }
            } else {
                delegate?.dictationHideOverlay()
            }
            recordAndFinish(
                session: session,
                outcome: "noMatch",
                decision: "settled",
                firstChangeMs: firstChangeMs,
                decisionMs: decisionMs,
                doneMs: doneMs,
                enterStatus: enterStatus,
                enterWaitMs: waitMs
            )

        case .earlyRejected(let decisionMs, let doneMs):
            // 启动后台补读以支持最近识别
            if let anchor = session.input.anchor {
                let obsToken = CancellationToken()
                self.backgroundObservationToken = obsToken
                let adapter = textAdapter
                let mode = session.mode
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard !obsToken.isCancelled else { return }
                    if let text = adapter.observeFinalText(after: anchor, maxWait: 1.0, mode: mode) {
                        guard !obsToken.isCancelled else { return }
                        DispatchQueue.main.async {
                            self?.delegate?.dictationDidCapture(text: text, bundleID: bundleID, matched: false)
                        }
                    }
                }
            }

            let enterStatus = pending != nil ? "sent" : "none"
            if let pending {
                emitEnter(shortcut: pending.shortcut, sessionID: sessionID, bundleIdentifier: session.bundleIdentifier, delayMs: 60_000) { [weak self] _ in
                    self?.delegate?.dictationShowOverlay("发送", tone: .send, autoHide: 1.2)
                }
            } else {
                delegate?.dictationHideOverlay()
            }
            recordAndFinish(
                session: session,
                outcome: "earlyRejected",
                decision: "early",
                decisionMs: decisionMs,
                doneMs: doneMs,
                enterStatus: enterStatus,
                enterWaitMs: waitMs
            )

        case .failed(let error, let message, let tone, let doneMs):
            let enterStatus: String
            if pending != nil {
                // ADR 0003: 替换失败不发送回车
                diagnostics.event("enter_withheld", session: session.shortID, bundleIdentifier: session.bundleIdentifier)
                enterStatus = "withheld"
            } else {
                enterStatus = "none"
            }

            if let message {
                // 提示完全遵循浮窗开关
                delegate?.dictationShowOverlay(message, tone: tone, autoHide: 2.2)
            } else {
                delegate?.dictationHideOverlay()
            }

            recordAndFinish(
                session: session,
                outcome: "failed",
                decision: "none",
                failure: error.name,
                doneMs: doneMs,
                enterStatus: enterStatus,
                enterWaitMs: waitMs
            )

        case .cancelled(let stage, let doneMs):
            diagnostics.event("macro_cancelled", session: session.shortID, bundleIdentifier: session.bundleIdentifier, detail: stage)
            delegate?.dictationHideOverlay()
            recordAndFinish(
                session: session,
                outcome: "cancelled",
                decision: "none",
                failure: stage,
                doneMs: doneMs,
                enterStatus: "none"
            )

        case .timedOut(let stage, let doneMs):
            delegate?.dictationHideOverlay()
            let enterStatus: String
            if let pending {
                emitEnter(shortcut: pending.shortcut, sessionID: sessionID, bundleIdentifier: session.bundleIdentifier, delayMs: 60_000) { [weak self] _ in
                    self?.delegate?.dictationShowOverlay("发送", tone: .send, autoHide: 1.2)
                }
                enterStatus = "sent"
            } else {
                enterStatus = "none"
            }
            recordAndFinish(
                session: session,
                outcome: "timeout",
                decision: "none",
                failure: stage,
                doneMs: doneMs,
                enterStatus: enterStatus,
                enterWaitMs: waitMs
            )
        }
    }

    private func recordAndFinish(
        session: ActiveSession,
        outcome: String,
        decision: String,
        failure: String? = nil,
        method: String? = nil,
        firstChangeMs: Int? = nil,
        decisionMs: Int? = nil,
        doneMs: Int? = nil,
        enterStatus: String = "none",
        enterWaitMs: Int? = nil,
        announceStop: Bool = false
    ) {
        let formatter = ISO8601DateFormatter()
        let record = SessionRecord(
            id: session.shortID,
            startedAt: formatter.string(from: session.startedAtDate),
            app: session.bundleIdentifier ?? "unknown",
            mode: session.mode.rawValue,
            role: session.role.rawValue,
            listenedMs: Int(session.elapsed * 1000),
            anchor: session.anchorStatus,
            outcome: outcome,
            decision: decision,
            failure: failure,
            method: method,
            firstChangeMs: firstChangeMs,
            decisionMs: decisionMs,
            doneMs: doneMs,
            enter: enterStatus,
            enterWaitMs: enterWaitMs
        )
        sessionRecordStore.append(record)

        if activeSession?.id == session.id {
            finishSession(session.id, announceStop: announceStop)
        }
    }

    private func finishSession(
        _ id: UUID,
        announceStop: Bool,
        noticeMessage: String? = nil,
        noticeTone: OverlayTone = .send
    ) {
        guard let session = activeSession, session.id == id else { return }
        session.pendingEnter?.timeoutWorkItem?.cancel()
        session.pendingEnter = nil
        activeSession = nil
        cooldownUntil = session.role == .hold
            ? Date().addingTimeInterval(SessionTriggerPolicy.holdCooldown)
            : .distantPast
        delegate?.dictationPhaseDidChange(.idle)
        if announceStop {
            delegate?.dictationShowOverlay("已停止", tone: .stopped, autoHide: 1.4)
        } else if let noticeMessage {
            delegate?.dictationShowOverlay(
                noticeMessage,
                tone: noticeTone,
                autoHide: noticeTone == .send ? 1.2 : 2.2
            )
        } else {
            delegate?.dictationHideOverlay()
        }
    }

    /// - Parameter synchronous: waits for the release strokes; used at quit so
    ///   no synthetic modifier is left pressed.
    func cancel(
        announce: Bool = false,
        emitCancelShortcut: Bool = true,
        synchronous: Bool = false
    ) {
        guard let session = activeSession else { return }
        backgroundObservationToken?.cancel()
        backgroundObservationToken = nil
        session.pendingEnter?.timeoutWorkItem?.cancel()
        session.pendingEnter = nil
        session.cancellation.cancel()

        let phase = session.phase
        let restorer = selectionRestorer
        let emitter = shortcutEmitter
        let work: @Sendable () -> Void = {
            let input = session.input
            defer { restorer.clear() }
            guard input.startEmitted, phase == .listening else { return }
            if session.role == .hold {
                if emitCancelShortcut, input.replacingSelection {
                    _ = restorer.restore()
                }
                try? emitter.keyUp(session.shortcut)
            } else if emitCancelShortcut {
                try? emitter.tap(KeyboardShortcut(keyCode: 53))
            }
        }
        if synchronous {
            inputQueue.sync(execute: work)
        } else {
            inputQueue.async(execute: work)
        }

        recordAndFinish(
            session: session,
            outcome: "cancelled",
            decision: "none",
            failure: "user_cancelled",
            enterStatus: "none",
            announceStop: announce
        )
    }

    func applicationDidActivate(_ application: NSRunningApplication) {
        guard let session = activeSession,
              session.phase == .listening
        else {
            return
        }

        let bundleID = application.bundleIdentifier ?? ""
        let isDoubaoOrHelper = AppSettings.doubaoClientBundleIDs.contains(bundleID) ||
            bundleID == AppSettings.bundleIdentifier ||
            bundleID.contains("doubao")
        if isDoubaoOrHelper {
            return
        }

        let sessionBundle = session.bundleIdentifier ?? ""
        let sessionWasDoubao = sessionBundle.contains("doubao") ||
            AppSettings.doubaoClientBundleIDs.contains(sessionBundle)
        if sessionWasDoubao {
            session.bundleIdentifier = application.bundleIdentifier
            session.processIdentifier = application.processIdentifier
            return
        }

        if session.processIdentifier != application.processIdentifier ||
            session.bundleIdentifier != application.bundleIdentifier
        {
            diagnostics.event("focus_changed", session: session.shortID, bundleIdentifier: application.bundleIdentifier)
            // Tell Doubao to abort so it never keeps recording into another app.
            cancel(announce: true, emitCancelShortcut: true)
        }
    }
}

private struct MacroJob: Sendable {
    let sessionID: UUID
    let shortID: String
    let rules: [MacroRule]
    let listened: TimeInterval
    let mode: TextTargetMode
    let allowKeystrokeFallback: Bool
    let bundleID: String?

    func run(
        anchor: TextSessionAnchor,
        adapter: AXTextAdapter,
        token: CancellationToken,
        writeState: WriteStateToken,
        diagnostics: Diagnostics
    ) -> MacroJobOutcome {
        let started = ProcessInfo.processInfo.systemUptime
        let engine = MacroEngine(rules: rules)
        let timeout = SettlePolicy.timeout(forListeningDuration: listened)
        let deadline = started + timeout

        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !token.isCancelled else {
                return .cancelled(stage: "watch_loop", doneMs: milliseconds(since: started))
            }

            let remaining = max(0.1, deadline - ProcessInfo.processInfo.systemUptime)
            let watched: WatchedInsertion?
            do {
                watched = try adapter.watchInsertedText(after: anchor, timeout: remaining, mode: mode) { text in
                    if token.isCancelled { return .stop }
                    switch engine.decide(text) {
                    case .pending: return .keepWaiting
                    case .reject: return .stop
                    case .match: return .accept
                    }
                }
            } catch {
                guard !token.isCancelled else {
                    return .cancelled(stage: "watch_catch", doneMs: milliseconds(since: started))
                }
                if let targetError = error as? TextTargetError {
                    switch targetError {
                    case .settleTimeout, .noInsertion:
                        return .timedOut(stage: "watch_timeout", doneMs: milliseconds(since: started))
                    default:
                        let msg = errorMessage(for: targetError)
                        return .failed(error: targetError, message: msg.message, tone: msg.tone, doneMs: milliseconds(since: started))
                    }
                }
                let err = TextTargetError.unknown
                return .failed(error: err, message: "未应用语音宏，已保留原文", tone: .notice, doneMs: milliseconds(since: started))
            }

            guard !token.isCancelled else {
                return .cancelled(stage: "after_watch", doneMs: milliseconds(since: started))
            }

            guard let watched else {
                // Early rejected
                diagnostics.event("macro_early_reject", session: shortID, bundleIdentifier: bundleID)
                return .earlyRejected(
                    decisionMs: milliseconds(since: started),
                    doneMs: milliseconds(since: started)
                )
            }

            let inserted = watched.insertion
            let timing = inserted.timing
            let firstChangeMs = timing.firstChange.map { Int($0 * 1000) }
            let decisionMs = Int(timing.decided * 1000)

            let decision: MacroEngine.Decision
            if !watched.settled {
                decision = engine.decide(inserted.text)
                diagnostics.event(
                    "macro_early_replace",
                    session: shortID,
                    bundleIdentifier: bundleID,
                    detail: "length=\(inserted.text.count)"
                )
            } else {
                decision = engine.finalDecision(inserted.text)
            }

            guard case let .match(_, replacement) = decision else {
                return .noMatch(
                    firstChangeMs: firstChangeMs,
                    decisionMs: decisionMs,
                    doneMs: milliseconds(since: started),
                    text: inserted.text
                )
            }

            // Match, begin writing
            writeState.setWriting(true)
            do {
                let method = try adapter.replace(
                    inserted,
                    with: replacement,
                    allowKeystrokeFallback: allowKeystrokeFallback
                )
                writeState.setWriting(false)
                diagnostics.event("replace_success", session: shortID, bundleIdentifier: bundleID, detail: method.rawValue)
                return .replaced(
                    method: method,
                    firstChangeMs: firstChangeMs,
                    decisionMs: decisionMs,
                    doneMs: milliseconds(since: started),
                    text: inserted.text,
                    settled: watched.settled
                )
            } catch TextTargetError.textChangedBeforeWrite {
                writeState.setWriting(false)
                diagnostics.event("macro_retry_text_changed", session: shortID, bundleIdentifier: bundleID)
                continue
            } catch {
                writeState.setWriting(false)
                guard !token.isCancelled else {
                    return .cancelled(stage: "replace_catch", doneMs: milliseconds(since: started))
                }
                let targetError = (error as? TextTargetError) ?? .unknown
                diagnostics.event("macro_not_applied", session: shortID, bundleIdentifier: bundleID, detail: targetError.name)
                let msg = errorMessage(for: targetError)
                return .failed(error: targetError, message: msg.message, tone: msg.tone, doneMs: milliseconds(since: started))
            }
        }

        return .timedOut(stage: "loop_deadline", doneMs: milliseconds(since: started))
    }

    private func errorMessage(for error: TextTargetError) -> (message: String?, tone: OverlayTone) {
        switch error {
        case .settleTimeout, .noInsertion:
            return (nil, .send)
        case .keystrokeFallbackDisabled:
            return ("此应用不接受写回，已保留原文", .notice)
        case .verificationFailed:
            return ("语音宏替换未确认，请检查文本", .notice)
        default:
            return ("未应用语音宏，已保留原文", .notice)
        }
    }
}

private func milliseconds(since start: TimeInterval) -> Int {
    Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
}
