import AppKit
import Combine
import Foundation
import os
import DoubaoVoiceHelperCore

enum AppStatus {
    case ready
    case listening
    case processing
    case paused
    case capturing
    case permission
    case error

    var title: String {
        switch self {
        case .ready: return "就绪"
        case .listening: return "正在听写"
        case .processing: return "正在处理"
        case .paused: return "已暂停"
        case .capturing: return "等待捕获鼠标键"
        case .permission: return "需要辅助功能权限"
        case .error: return "发生错误"
        }
    }

    var symbolName: String {
        switch self {
        case .ready: return "mic"
        case .listening: return "mic.fill"
        case .processing: return "ellipsis.circle"
        case .paused: return "pause.circle"
        case .capturing: return "dot.circle.and.hand.point.up.left.fill"
        case .permission: return "lock.shield"
        case .error: return "exclamationmark.triangle"
        }
    }
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

private final class ActiveSession: @unchecked Sendable {
    enum Phase {
        case listening
        case processing
    }

    let id = UUID()
    let anchor: TextSessionAnchor?
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let cancellation = CancellationToken()
    var phase: Phase = .listening

    init(
        anchor: TextSessionAnchor?,
        bundleIdentifier: String?,
        processIdentifier: pid_t
    ) {
        self.anchor = anchor
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var status: AppStatus = .ready
    @Published private(set) var notice: String?
    @Published private(set) var permissionSnapshot = PermissionSnapshot(
        accessibilityTrusted: false,
        inputMonitoringAuthorized: false
    )

    let repository: SettingsRepository
    let permissionService: PermissionService
    let shortcutEmitter: ShortcutEmitting
    let textAdapter: AXTextAdapter
    let loginItemService: LoginItemService
    let overlayController: StatusOverlayController

    private let diagnostics = Diagnostics()
    private lazy var mouseMonitor = MouseEventMonitor(
        configuration: .init(
            button: settings.mouseBinding.button,
            excludedBundleIDs: settings.excludedBundleIDs,
            paused: false,
            capturing: false
        ),
        callbackHandler: { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event)
            }
        }
    )
    private var activeSession: ActiveSession?
    private var workspaceObserver: NSObjectProtocol?
    private var monitorStarted = false
    private var captureMode = false
    private var ignoreNextMouseUp = false
    private var captureTimeout: DispatchWorkItem?
    private var pendingMouseDown: DispatchWorkItem?
    private let holdToTalkDelay: TimeInterval = 0.25

    init(
        repository: SettingsRepository = SettingsRepository(),
        permissionService: PermissionService = PermissionService(),
        shortcutEmitter: ShortcutEmitting = CoreGraphicsShortcutEmitter(),
        textAdapter: AXTextAdapter = AXTextAdapter(),
        loginItemService: LoginItemService = LoginItemService(),
        overlayController: StatusOverlayController? = nil
    ) {
        self.repository = repository
        self.permissionService = permissionService
        self.shortcutEmitter = shortcutEmitter
        self.textAdapter = textAdapter
        self.loginItemService = loginItemService
        self.overlayController = overlayController ?? StatusOverlayController()
        self.settings = repository.load()

        workspaceObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let application = notification.userInfo?[
                    NSWorkspace.applicationUserInfoKey
                ] as? NSRunningApplication
            else {
                return
            }
            DispatchQueue.main.async {
                self?.handleApplicationActivation(application)
            }
        }

        refreshPermissions()
        syncMonitorConfiguration()
        startMonitoringIfPossible()
        if settings.launchAtLogin {
            try? loginItemService.setEnabled(true)
        }
    }

    var statusTitle: String {
        status.title
    }

    var isPaused: Bool {
        get { status == .paused }
        set { setPaused(newValue) }
    }

    func refreshPermissions() {
        permissionSnapshot = permissionService.snapshot()
        if (!permissionSnapshot.accessibilityTrusted ||
            !permissionSnapshot.inputMonitoringAuthorized),
           activeSession == nil
        {
            status = .permission
        } else if status == .permission {
            status = .ready
        }
    }

    func requestAccessibilityPermission() {
        _ = permissionService.requestAccessibility()
        refreshPermissions()
        startMonitoringIfPossible()
    }

    func requestInputMonitoringPermission() {
        _ = permissionService.requestInputMonitoring()
        refreshPermissions()
        startMonitoringIfPossible()
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        openPrivacyPane("Privacy_ListenEvent")
    }

    func setPaused(_ paused: Bool) {
        if paused {
            cancelActiveSession()
            status = .paused
        } else {
            status = hasRequiredPermissions ? .ready : .permission
        }
        syncMonitorConfiguration()
        persist()
    }

    func setOverlayEnabled(_ enabled: Bool) {
        settings.overlayEnabled = enabled
        if !enabled {
            overlayController.hide()
        }
        persist()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        settings.launchAtLogin = enabled
        do {
            try loginItemService.setEnabled(enabled)
            persist()
        } catch {
            settings.launchAtLogin = !enabled
            showNotice("登录启动设置失败")
        }
    }

    func setMouseButton(_ button: Int64) {
        guard button >= 0 else { return }
        settings.mouseBinding.button = button
        syncMonitorConfiguration()
        persist()
    }

    func setShortcut(_ shortcut: KeyboardShortcut) {
        settings.doubaoShortcut = shortcut
        persist()
    }

    func testShortcut() {
        refreshPermissions()
        guard permissionSnapshot.accessibilityTrusted else {
            showNotice("请先授权辅助功能，系统才会接受模拟快捷键")
            return
        }
        do {
            try shortcutEmitter.emit(settings.doubaoShortcut)
            showNotice("已发送豆包快捷键")
        } catch {
            showNotice("发送豆包快捷键失败")
        }
    }

    func beginMouseButtonCapture() {
        guard monitorStarted else {
            showNotice("请先授权辅助功能，再捕获鼠标键")
            return
        }
        captureMode = true
        status = .capturing
        syncMonitorConfiguration()
        showOverlay("请按一下要绑定的额外鼠标键")

        captureTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.captureMode else { return }
            self.captureMode = false
            self.status = self.hasRequiredPermissions ? .ready : .permission
            self.syncMonitorConfiguration()
            self.showNotice("鼠标键捕获超时，请重试")
        }
        captureTimeout = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 10,
            execute: timeout
        )
    }

    func addMacroRule() {
        settings.macroRules.append(
            MacroRule(source: "", replacement: "", isEnabled: true)
        )
        persist()
    }

    func removeMacroRule(at index: Int) {
        guard settings.macroRules.indices.contains(index) else { return }
        settings.macroRules.remove(at: index)
        persist()
    }

    func updateMacroRule(at index: Int, _ update: (inout MacroRule) -> Void) {
        guard settings.macroRules.indices.contains(index) else { return }
        update(&settings.macroRules[index])
        persist()
    }

    func addExcludedBundleID() {
        settings.excludedBundleIDs.append("")
        persist()
    }

    func removeExcludedBundleID(at index: Int) {
        guard settings.excludedBundleIDs.indices.contains(index) else {
            return
        }
        settings.excludedBundleIDs.remove(at: index)
        syncMonitorConfiguration()
        persist()
    }

    func updateExcludedBundleID(at index: Int, value: String) {
        guard settings.excludedBundleIDs.indices.contains(index) else {
            return
        }
        settings.excludedBundleIDs[index] = value
        syncMonitorConfiguration()
        persist()
    }

    func preview(_ text: String) -> MacroResult {
        MacroEngine().apply(text, rules: settings.macroRules)
    }

    func persist() {
        guard MacroEngine().validate(settings.macroRules).isEmpty else {
            showNotice("语音宏不能包含空文本或重复识别文本")
            return
        }
        do {
            try repository.save(settings)
        } catch {
            showNotice("设置保存失败")
        }
    }

    private func startMonitoringIfPossible() {
        guard !monitorStarted,
              permissionSnapshot.accessibilityTrusted,
              permissionSnapshot.inputMonitoringAuthorized
        else {
            return
        }

        do {
            try mouseMonitor.start()
            monitorStarted = true
            status = settings.launchAtLogin ? .ready : .ready
        } catch {
            status = .error
            showNotice("无法监听额外鼠标键")
        }
    }

    private func syncMonitorConfiguration() {
        mouseMonitor.update(
            configuration: .init(
                button: settings.mouseBinding.button,
                excludedBundleIDs: settings.excludedBundleIDs,
                paused: status == .paused,
                capturing: captureMode
            )
        )
    }

    private func handle(_ event: MouseButtonEvent) {
        if captureMode {
            guard event.kind == .down else { return }
            captureMode = false
            captureTimeout?.cancel()
            captureTimeout = nil
            ignoreNextMouseUp = true
            settings.mouseBinding.button = event.button
            status = .ready
            syncMonitorConfiguration()
            persist()
            showNotice("已绑定额外鼠标键 \(event.button)")
            return
        }

        if ignoreNextMouseUp {
            if event.kind == .up {
                ignoreNextMouseUp = false
            }
            return
        }

        switch event.kind {
        case .down:
            if event.button == 0, !event.isLongPress {
                scheduleSessionStart(event)
            } else {
                beginSession(event)
            }
        case .up:
            pendingMouseDown?.cancel()
            pendingMouseDown = nil
            guard activeSession != nil else {
                return
            }
            endSession(event)
        }
    }

    private func scheduleSessionStart(_ event: MouseButtonEvent) {
        guard status != .paused, activeSession == nil else { return }
        pendingMouseDown?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let currentApplication = NSWorkspace.shared.frontmostApplication
            if let eventBundleIdentifier = event.bundleIdentifier,
               currentApplication?.bundleIdentifier != eventBundleIdentifier
            {
                return
            }
            if event.processIdentifier != 0,
               currentApplication?.processIdentifier != event.processIdentifier
            {
                return
            }
            self.beginSession(event)
        }
        pendingMouseDown = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + holdToTalkDelay,
            execute: work
        )
    }

    private func beginSession(_ event: MouseButtonEvent) {
        guard status != .paused, activeSession == nil else { return }

        let anchor = try? textAdapter.beginSession()
        let session = ActiveSession(
            anchor: anchor,
            bundleIdentifier: event.bundleIdentifier,
            processIdentifier: event.processIdentifier
        )
        activeSession = session

        do {
            try shortcutEmitter.emit(settings.doubaoShortcut)
            diagnostics.event(
                "mouse_session_started",
                bundleIdentifier: event.bundleIdentifier
            )
            status = .listening
            if anchor == nil {
                showOverlay("正在听写（本次不处理语音宏）")
            } else {
                showOverlay("正在听写")
            }
        } catch {
            activeSession = nil
            status = .error
            showNotice("无法发送豆包快捷键")
        }
    }

    private func endSession(_ event: MouseButtonEvent) {
        guard let session = activeSession,
              session.phase == .listening
        else {
            return
        }

        if let bundleIdentifier = session.bundleIdentifier,
           bundleIdentifier != event.bundleIdentifier
        {
            cancelActiveSession()
            return
        }

        session.phase = .processing
        do {
            try shortcutEmitter.emit(settings.doubaoShortcut)
            diagnostics.event(
                "shortcut_emitted",
                bundleIdentifier: session.bundleIdentifier
            )
        } catch {
            session.cancellation.cancel()
            activeSession = nil
            status = .error
            showNotice("无法停止豆包听写")
            return
        }

        guard let anchor = session.anchor else {
            finishSession(session.id, message: "本次未读取到可编辑文本")
            return
        }

        status = .processing
        let rules = settings.macroRules
        let adapter = textAdapter
        let token = session.cancellation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let inserted = try adapter.waitForInsertedText(
                    after: anchor,
                    timeout: 1.8
                )
                guard !token.isCancelled else { return }
                let result = MacroEngine().apply(inserted.text, rules: rules)
                guard result.changed else {
                    DispatchQueue.main.async {
                        self?.finishSession(session.id, message: nil)
                    }
                    return
                }
                guard !token.isCancelled else { return }
                try adapter.replace(inserted, with: result.output)
                DispatchQueue.main.async {
                    self?.finishSession(
                        session.id,
                        message: "已应用 \(result.matchCount) 条语音宏"
                    )
                }
            } catch {
                guard !token.isCancelled else { return }
                DispatchQueue.main.async {
                    self?.finishSession(
                        session.id,
                        message: "未应用语音宏，已保留原文"
                    )
                }
            }
        }
    }

    private func finishSession(_ id: UUID, message: String?) {
        guard activeSession?.id == id else { return }
        activeSession = nil
        status = hasRequiredPermissions ? .ready : .permission
        if let message {
            if message.hasPrefix("已应用") {
                showOverlay(message)
            } else {
                showNotice(message)
            }
        } else {
            overlayController.hide()
        }
    }

    private func cancelActiveSession() {
        guard let session = activeSession else { return }
        session.cancellation.cancel()
        if session.phase == .listening {
            try? shortcutEmitter.emit(settings.doubaoShortcut)
        }
        activeSession = nil
        if status != .paused {
            status = hasRequiredPermissions ? .ready : .permission
        }
        overlayController.hide()
    }

    private func handleApplicationActivation(
        _ application: NSRunningApplication
    ) {
        guard let session = activeSession,
              session.phase == .listening
        else {
            return
        }
        let changedProcess = session.processIdentifier != application.processIdentifier
        let changedBundle = session.bundleIdentifier != application.bundleIdentifier
        if changedProcess || changedBundle {
            diagnostics.event(
                "focus_changed",
                bundleIdentifier: application.bundleIdentifier
            )
            cancelActiveSession()
        }
    }

    private func showOverlay(_ message: String) {
        guard settings.overlayEnabled else { return }
        overlayController.show(message)
    }

    private func showNotice(_ message: String) {
        notice = message
        showOverlay(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.notice == message else { return }
            self.notice = nil
            self.overlayController.hide()
            if self.status == .error {
                self.status = self.hasRequiredPermissions
                    ? .ready
                    : .permission
            }
        }
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var hasRequiredPermissions: Bool {
        permissionSnapshot.accessibilityTrusted &&
            permissionSnapshot.inputMonitoringAuthorized
    }
}

private final class Diagnostics {
    private let logger = Logger(
        subsystem: "com.jarod.doubao-voice-helper",
        category: "runtime"
    )

    func event(
        _ name: String,
        bundleIdentifier: String? = nil
    ) {
        let bundle = bundleIdentifier ?? "unknown"
        logger.notice("event=\(name) bundle=\(bundle)")
    }
}
