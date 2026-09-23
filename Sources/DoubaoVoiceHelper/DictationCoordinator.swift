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

/// One dictation session. Fields marked "main" are only touched on the main
/// actor; `input` is shared with the serial input queue and guarded by a lock.
private final class ActiveSession: @unchecked Sendable {
    struct InputState {
        var anchor: TextSessionAnchor?
        var replacingSelection = false
        var startEmitted = false
    }

    let id = UUID()
    let role: SessionRole
    let shortcut: KeyboardShortcut
    let cancellation = CancellationToken()
    let startedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    let pressOrigin: CGPoint

    // main
    var bundleIdentifier: String?
    var processIdentifier: pid_t
    var phase: SessionPhase = .listening
    var cancelArmed = false

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
        ProcessInfo.processInfo.systemUptime - startedAt
    }
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
    /// Every synthetic key press goes through this queue so the main thread
    /// never blocks on key timing and start/stop/cancel strokes stay ordered.
    private let inputQueue = DispatchQueue(
        label: "com.jarod.doubao-voice-helper.input",
        qos: .userInteractive
    )
    private var activeSession: ActiveSession?
    private var cooldownUntil = Date.distantPast

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

    private func sendEnter(_ shortcut: KeyboardShortcut) {
        let hadSession = isActive
        if hadSession {
            cancel(announce: false, emitCancelShortcut: false)
        }
        let emitter = shortcutEmitter
        inputQueue.async { [weak self] in
            // Give Doubao time to commit the dictated text before Return.
            if hadSession { usleep(60_000) }
            do {
                try emitter.tap(shortcut)
                DispatchQueue.main.async {
                    self?.diagnostics.event("enter_emitted")
                    self?.delegate?.dictationShowOverlay("发送", tone: .send, autoHide: 1.2)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.delegate?.dictationDidFail("发送回车失败")
                }
            }
        }
    }

    // MARK: - Session lifecycle

    private func beginSession(
        _ event: MouseButtonEvent,
        role: SessionRole,
        configuration: DictationConfiguration
    ) {
        let shortcut = configuration.shortcut(for: role)
        let session = ActiveSession(
            role: role,
            shortcut: shortcut,
            bundleIdentifier: event.bundleIdentifier,
            processIdentifier: event.processIdentifier,
            pressOrigin: event.location
        )
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
        let adapter = textAdapter
        let restorer = selectionRestorer
        let emitter = shortcutEmitter
        let diagnostics = diagnostics

        inputQueue.async { [weak self] in
            guard !session.cancellation.isCancelled else { return }

            let replacingSelection = role == .hold && restorer.restore()

            // The anchor must be taken before Doubao starts, otherwise it can
            // already contain part of the dictation.
            var anchorFailed = false
            if captureAnchor {
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    let anchor = try adapter.beginSession(
                        targetProcessIdentifier: targetPID,
                        messagingTimeout: anchorTimeout
                    )
                    session.updateInput { $0.anchor = anchor }
                    diagnostics.event(
                        "anchor_captured",
                        bundleIdentifier: bundleID,
                        detail: "role=\(anchor.identity.role) length=\(anchor.originalText.count) ms=\(milliseconds(since: started))"
                    )
                } catch {
                    anchorFailed = true
                    diagnostics.event(
                        "anchor_failed",
                        bundleIdentifier: bundleID,
                        detail: "\(error) ms=\(milliseconds(since: started))"
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
                diagnostics.event("mouse_session_started", bundleIdentifier: bundleID)
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
                    self.delegate?.dictationShowOverlay("宏替换不可用", tone: .notice, autoHide: 1.5)
                } else if session.phase == .listening {
                    self.delegate?.dictationShowOverlay("将替换选中文字", tone: .listening, autoHide: nil)
                }
            }
        }
    }

    private func abandonSession(_ id: UUID, message: String) {
        guard activeSession?.id == id else { return }
        activeSession = nil
        delegate?.dictationPhaseDidChange(.idle)
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
            rules: configuration.macroRules,
            listened: listened,
            mode: BundleExclusion.matches(session.bundleIdentifier, in: configuration.terminalMacroBundleIDs)
                ? .terminal
                : .standard,
            allowKeystrokeFallback: BundleExclusion.matches(
                session.bundleIdentifier,
                in: configuration.keystrokeFallbackBundleIDs
            ),
            bundleID: session.bundleIdentifier
        )
        let sessionID = session.id
        let token = session.cancellation
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
                    self.diagnostics.event("session_timeout", bundleIdentifier: job.bundleID, detail: "processing")
                    token.cancel()
                    self.finishSession(sessionID, announceStop: false)
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
                diagnostics.event("shortcut_emitted", bundleIdentifier: job.bundleID)
            } catch {
                token.cancel()
                DispatchQueue.main.async {
                    self?.abandonSession(sessionID, message: "无法停止豆包听写")
                }
                return
            }

            guard processMacros, let anchor = input.anchor else {
                if processMacros {
                    diagnostics.event("macro_skipped", bundleIdentifier: job.bundleID, detail: "no_anchor")
                }
                DispatchQueue.main.async {
                    self?.finishSession(sessionID, announceStop: announceStop)
                }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                guard let outcome = job.run(
                    anchor: anchor,
                    adapter: adapter,
                    token: token,
                    diagnostics: diagnostics
                ) else { return }
                DispatchQueue.main.async {
                    self?.finishSession(
                        sessionID,
                        announceStop: false,
                        noticeMessage: outcome.message,
                        noticeTone: outcome.tone
                    )
                }
            }
        }
    }

    private func finishSession(
        _ id: UUID,
        announceStop: Bool,
        noticeMessage: String? = nil,
        noticeTone: OverlayTone = .send
    ) {
        guard let session = activeSession, session.id == id else { return }
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

        activeSession = nil
        delegate?.dictationPhaseDidChange(.idle)
        if announce {
            delegate?.dictationShowOverlay("已停止", tone: .stopped, autoHide: 1.4)
        } else {
            delegate?.dictationHideOverlay()
        }
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
            diagnostics.event("focus_changed", bundleIdentifier: application.bundleIdentifier)
            // Tell Doubao to abort so it never keeps recording into another app.
            cancel(announce: true, emitCancelShortcut: true)
        }
    }
}

/// The macro pass for one utterance; runs off the main thread.
private struct MacroJob: Sendable {
    struct Outcome: Sendable {
        var message: String?
        var tone: OverlayTone = .send
    }

    let rules: [MacroRule]
    let listened: TimeInterval
    let mode: TextTargetMode
    let allowKeystrokeFallback: Bool
    let bundleID: String?

    /// Returns `nil` when the session was cancelled.
    func run(
        anchor: TextSessionAnchor,
        adapter: AXTextAdapter,
        token: CancellationToken,
        diagnostics: Diagnostics
    ) -> Outcome? {
        do {
            let inserted = try adapter.waitForInsertedText(
                after: anchor,
                timeout: SettlePolicy.timeout(forListeningDuration: listened),
                mode: mode
            )
            guard !token.isCancelled else { return nil }
            let timing = inserted.timing
            let firstChange = timing.firstChange.map { String(Int($0 * 1000)) } ?? "none"
            diagnostics.event(
                "text_settled",
                bundleIdentifier: bundleID,
                detail: "mode=\(mode.rawValue) kind=\(inserted.kind) length=\(inserted.text.count) listened_ms=\(Int(listened * 1000)) first_change_ms=\(firstChange) settled_ms=\(Int(timing.settled * 1000)) notifications=\(timing.notifications)"
            )

            let result = MacroEngine().apply(inserted.text, rules: rules)
            diagnostics.event(
                "macro_result",
                bundleIdentifier: bundleID,
                detail: "matches=\(result.matchCount) input_length=\(inserted.text.count) output_length=\(result.output.count)"
            )
            guard result.changed else { return Outcome() }
            guard !token.isCancelled else { return nil }

            let method = try adapter.replace(
                inserted,
                with: result.output,
                allowKeystrokeFallback: allowKeystrokeFallback
            )
            diagnostics.event("replace_success", bundleIdentifier: bundleID, detail: method.rawValue)
            return Outcome(message: "已应用 \(result.matchCount) 条语音宏")
        } catch {
            guard !token.isCancelled else { return nil }
            diagnostics.event("macro_not_applied", bundleIdentifier: bundleID, detail: "\(error)")
            switch error as? TextTargetError {
            case .settleTimeout, .noInsertion:
                return Outcome()
            case .keystrokeFallbackDisabled:
                return Outcome(message: "此应用不接受写回，已保留原文", tone: .notice)
            case .verificationFailed:
                return Outcome(message: "语音宏替换未确认，请检查文本", tone: .notice)
            default:
                return Outcome(message: "未应用语音宏，已保留原文", tone: .notice)
            }
        }
    }
}

private func milliseconds(since start: TimeInterval) -> Int {
    Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
}
