import AppKit
import Combine
import Foundation
import os
import UniformTypeIdentifiers
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

    var menuBarIconName: String {
        switch self {
        case .listening, .processing, .capturing:
            return "StatusBarIconFilledTemplate-18pt"
        case .ready, .paused, .permission, .error:
            return "StatusBarIconTemplate-18pt"
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
    let role: MouseBindingRole
    let shortcut: KeyboardShortcut
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let cancellation = CancellationToken()
    var phase: Phase = .listening
    let pressOrigin: CGPoint
    var cancelArmed = false
    var replacingSelection = false

    init(
        anchor: TextSessionAnchor?,
        role: MouseBindingRole,
        shortcut: KeyboardShortcut,
        bundleIdentifier: String?,
        processIdentifier: pid_t,
        pressOrigin: CGPoint
    ) {
        self.anchor = anchor
        self.role = role
        self.shortcut = shortcut
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.pressOrigin = pressOrigin
    }
}

enum OnboardingPhase: Equatable {
    case intro
    case permissions
    case confirm(MouseBindingRole)
    case optionsPlus(MouseBindingRole)
    case loginItem
    case done
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
    @Published private(set) var captureRole: MouseBindingRole?
    @Published var onboardingPhase: OnboardingPhase
    @Published private(set) var lastHeardButton: Int64?
    @Published private(set) var updateState: UpdateState = .idle
    @Published var logiOptionsInstalled: Bool = LogiOptionsPatcher.shared.isInstalled
    @Published var logiOptionsNeedsFix: Bool = false
    @Published var logiOptionsPatching: Bool = false

    let repository: SettingsRepository
    let permissionService: PermissionService
    let shortcutEmitter: ShortcutEmitting
    let textAdapter: AXTextAdapter
    let loginItemService: LoginItemService
    let overlayController: StatusOverlayController
    let selectionRestorer: AXSelectionRestorer
    let updateService = UpdateService()

    private let diagnostics = Diagnostics()
    private lazy var mouseMonitor = MouseEventMonitor(
        configuration: .init(
            toggleButton: settings.toggleMouseBinding.button,
            holdButton: settings.holdMouseBinding.button,
            enterButton: settings.enterMouseBinding.button,
            navigationExcludedBundleIDs: settings.excludedBundleIDs,
            holdExcludedBundleIDs: settings.holdExcludedBundleIDs,
            paused: false,
            capturing: false,
            wechatHoldPreemptEnabled: settings.wechatHoldPreemptEnabled,
            swallowEscape: false
        ),
        selectionRestorer: selectionRestorer,
        callbackHandler: { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event)
            }
        }
    )
    private var activeSession: ActiveSession?
    private var workspaceObserver: NSObjectProtocol?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var monitorStarted = false
    private var captureMode = false
    private var confirmationRole: MouseBindingRole?
    private var captureTimeout: DispatchWorkItem?
    private var sessionCooldownUntil = Date.distantPast
    private let sessionCooldown: TimeInterval = 0.35

    init(
        repository: SettingsRepository = SettingsRepository(),
        permissionService: PermissionService = PermissionService(),
        shortcutEmitter: ShortcutEmitting = CoreGraphicsShortcutEmitter(),
        textAdapter: AXTextAdapter = AXTextAdapter(),
        loginItemService: LoginItemService = LoginItemService(),
        overlayController: StatusOverlayController? = nil,
        selectionRestorer: AXSelectionRestorer = AXSelectionRestorer()
    ) {
        self.repository = repository
        self.permissionService = permissionService
        self.shortcutEmitter = shortcutEmitter
        self.textAdapter = textAdapter
        self.loginItemService = loginItemService
        self.overlayController = overlayController ?? StatusOverlayController()
        self.selectionRestorer = selectionRestorer
        let loaded = repository.load()
        self.settings = loaded
        self.onboardingPhase = loaded.onboardingCompleted ? .done : .intro
        try? repository.save(loaded)

        if !permissionService.snapshot().accessibilityTrusted {
            _ = permissionService.requestAccessibility()
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
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
        observeLifecycle()

        refreshPermissions()
        syncMonitorConfiguration()
        startMonitoringIfPossible()
        updateService.$state
            .receive(on: DispatchQueue.main)
            .assign(to: &$updateState)

        if settings.launchAtLogin, settings.onboardingCompleted {
            try? loginItemService.setEnabled(true)
        }
    }

    var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    func checkForUpdates() {
        Task {
            await updateService.checkForUpdates(currentVersion: appVersionString)
        }
    }

    func downloadAndInstallUpdate() {
        guard case .updateAvailable(_, _, let downloadURL, _) = updateState,
              let downloadURL
        else {
            return
        }
        Task {
            await updateService.downloadAndInstall(
                downloadURL: downloadURL,
                currentAppURL: Bundle.main.bundleURL
            )
        }
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(AppSettings.gitHubReleasesPageURL)
    }

    var statusTitle: String {
        status.title
    }

    var requiresInputMonitoringForConfiguredButtons: Bool {
        [
            settings.toggleMouseBinding.button,
            settings.holdMouseBinding.button,
            settings.enterMouseBinding.button,
        ].contains { $0 >= 2 }
    }

    var isPaused: Bool {
        get { status == .paused }
        set { setPaused(newValue) }
    }

    func refreshPermissions() {
        permissionSnapshot = permissionService.snapshot()
        checkLogiOptionsStatus()
        if !hasRequiredPermissions, activeSession == nil
        {
            status = .permission
        } else if status == .permission {
            status = .ready
        }
    }

    func checkLogiOptionsStatus() {
        logiOptionsInstalled = LogiOptionsPatcher.shared.isInstalled
        if logiOptionsInstalled {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let needs = LogiOptionsPatcher.shared.needsFix()
                DispatchQueue.main.async {
                    self?.logiOptionsNeedsFix = needs
                }
            }
        }
    }

    func patchLogiOptions() {
        logiOptionsPatching = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try LogiOptionsPatcher.shared.patch()
                DispatchQueue.main.async {
                    self.logiOptionsPatching = false
                    self.logiOptionsNeedsFix = false
                    self.showNotice("成功修复 \(result.count) 处罗技侧键配置为原生按键！")
                }
            } catch {
                DispatchQueue.main.async {
                    self.logiOptionsPatching = false
                    self.showNotice("修复失败：\(error.localizedDescription)")
                }
            }
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

    func setWechatHoldPreemptEnabled(_ enabled: Bool) {
        settings.wechatHoldPreemptEnabled = enabled
        syncMonitorConfiguration()
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

    func mouseBinding(for role: MouseBindingRole) -> MouseBinding {
        switch role {
        case .toggle: return settings.toggleMouseBinding
        case .hold: return settings.holdMouseBinding
        case .enter: return settings.enterMouseBinding
        case .capture, .unbound, .escape: return MouseBinding()
        }
    }

    func setMouseButton(_ button: Int64, for role: MouseBindingRole) {
        guard button >= 0 else { return }
        switch role {
        case .toggle:
            settings.toggleMouseBinding.button = button
        case .hold:
            settings.holdMouseBinding.button = button
        case .enter:
            settings.enterMouseBinding.button = button
        case .capture, .unbound, .escape:
            return
        }
        syncMonitorConfiguration()
        persist()
    }

    func shortcut(for role: MouseBindingRole) -> KeyboardShortcut {
        switch role {
        case .toggle: return settings.toggleShortcut
        case .hold: return settings.holdShortcut
        case .enter: return settings.enterShortcut
        case .capture, .unbound, .escape: return .doubaoDefault
        }
    }

    func setShortcut(
        _ shortcut: KeyboardShortcut,
        for role: MouseBindingRole
    ) {
        switch role {
        case .toggle:
            settings.toggleShortcut = shortcut
        case .hold:
            settings.holdShortcut = shortcut
        case .enter:
            settings.enterShortcut = shortcut
        case .capture, .unbound, .escape:
            return
        }
        persist()
    }

    func beginMouseButtonCapture(
        for role: MouseBindingRole,
        confirming: Bool = false
    ) {
        guard monitorStarted else {
            showNotice("请先授权辅助功能，再捕获鼠标键")
            return
        }
        captureMode = true
        captureRole = role
        confirmationRole = confirming ? role : nil
        status = .capturing
        syncMonitorConfiguration()
        let prompt = confirming
            ? "请按下默认的\(role.displayName)键"
            : "请按一下要绑定\(role.displayName)的鼠标键"
        showOverlay(prompt, tone: .listening)

        captureTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.captureMode else { return }
            if self.confirmationRole != nil,
               role == .toggle || role == .enter
            {
                self.captureMode = false
                self.captureRole = nil
                self.confirmationRole = nil
                self.captureTimeout = nil
                self.status = self.hasRequiredPermissions ? .ready : .permission
                self.syncMonitorConfiguration()
                self.onboardingPhase = .optionsPlus(role)
                self.overlayController.hide()
                return
            }
            self.captureMode = false
            self.captureRole = nil
            self.confirmationRole = nil
            self.status = self.hasRequiredPermissions ? .ready : .permission
            self.syncMonitorConfiguration()
            self.showNotice("鼠标键捕获超时，请重试")
        }
        captureTimeout = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (confirming ? 8 : 10),
            execute: timeout
        )
    }

    func cancelMouseButtonCapture() {
        guard captureMode else { return }
        captureMode = false
        captureRole = nil
        confirmationRole = nil
        captureTimeout?.cancel()
        captureTimeout = nil
        if settings.onboardingCompleted {
            status = hasRequiredPermissions ? .ready : .permission
        }
        syncMonitorConfiguration()
        overlayController.hide()
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

    func removeMacroRule(id: UUID) {
        settings.macroRules.removeAll { $0.id == id }
        persist()
    }

    func updateMacroRule(at index: Int, _ update: (inout MacroRule) -> Void) {
        guard settings.macroRules.indices.contains(index) else { return }
        update(&settings.macroRules[index])
        persist()
    }

    func updateMacroRule(id: UUID, _ update: (inout MacroRule) -> Void) {
        guard let index = settings.macroRules.firstIndex(where: { $0.id == id }) else { return }
        update(&settings.macroRules[index])
        persist()
    }

    func addExcludedBundleID(_ bundleID: String = "") {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !settings.excludedBundleIDs.contains(trimmed) else { return }
        settings.excludedBundleIDs.append(trimmed)
        syncMonitorConfiguration()
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

    func removeExcludedBundleID(_ bundleID: String) {
        settings.excludedBundleIDs.removeAll { $0 == bundleID }
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

    func pickAndAddExcludedApplication(window: NSWindow? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "添加排除"
        panel.message = "选择在其中保留鼠标前进/后退原生导航的应用"

        let targetWindow = window ?? NSApp.keyWindow ?? NSApp.windows.first
        if let targetWindow {
            panel.beginSheetModal(for: targetWindow) { [weak self] response in
                guard response == .OK, let self else { return }
                for url in panel.urls {
                    if let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier {
                        self.addExcludedBundleID(bundleID)
                    }
                }
            }
        } else {
            panel.begin { [weak self] response in
                guard response == .OK, let self else { return }
                for url in panel.urls {
                    if let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier {
                        self.addExcludedBundleID(bundleID)
                    }
                }
            }
        }
    }

    func preview(_ text: String) -> MacroResult {
        MacroEngine().apply(text, rules: settings.macroRules)
    }

    func persist() {
        let mouseButtons = [
            settings.toggleMouseBinding.button,
            settings.holdMouseBinding.button,
            settings.enterMouseBinding.button,
        ]
        guard Set(mouseButtons).count == mouseButtons.count else {
            showNotice("三种鼠标功能不能绑定同一个按键")
            return
        }
        do {
            try repository.save(settings)
        } catch {
            showNotice("设置保存失败")
        }
    }

    func advanceOnboarding() {
        switch onboardingPhase {
        case .intro:
            onboardingPhase = .permissions
            refreshPermissions()
        case .permissions:
            guard hasRequiredPermissions else {
                showNotice("请先授权辅助功能，额外键还需要输入监控")
                return
            }
            startMonitoringIfPossible()
            beginOnboardingConfirm(for: .toggle)
        case .confirm:
            break
        case .optionsPlus(let role):
            skipOnboardingConfirm(for: role)
        case .loginItem:
            completeOnboarding()
        case .done:
            break
        }
    }

    func skipOnboardingConfirm(for role: MouseBindingRole) {
        cancelMouseButtonCapture()
        switch role {
        case .toggle:
            beginOnboardingConfirm(for: .hold)
        case .hold:
            beginOnboardingConfirm(for: .enter)
        default:
            onboardingPhase = .loginItem
        }
    }

    func completeOnboarding(enableLoginItem: Bool? = nil) {
        cancelMouseButtonCapture()
        if let enableLoginItem {
            setLaunchAtLogin(enableLoginItem)
        }
        settings.onboardingCompleted = true
        onboardingPhase = .done
        persist()
        status = hasRequiredPermissions ? .ready : .permission
        syncMonitorConfiguration()
    }

    func retryOnboardingConfirm(for role: MouseBindingRole) {
        beginOnboardingConfirm(for: role)
    }

    func beginOnboardingConfirm(for role: MouseBindingRole) {
        lastHeardButton = nil
        onboardingPhase = .confirm(role)
        beginMouseButtonCapture(for: role, confirming: true)
    }

    private func startMonitoringIfPossible() {
        guard !monitorStarted,
              permissionSnapshot.accessibilityTrusted,
              !requiresInputMonitoringForConfiguredButtons ||
                permissionSnapshot.inputMonitoringAuthorized
        else {
            return
        }

        do {
            try mouseMonitor.start()
            monitorStarted = true
            diagnostics.event("mouse_event_tap_started")
            status = .ready
        } catch {
            status = .error
            diagnostics.event("mouse_event_tap_failed")
            showNotice("无法监听鼠标键，请确认辅助功能授权")
        }
    }

    private func syncMonitorConfiguration() {
        mouseMonitor.update(
            configuration: .init(
                toggleButton: settings.toggleMouseBinding.button,
                holdButton: settings.holdMouseBinding.button,
                enterButton: settings.enterMouseBinding.button,
                navigationExcludedBundleIDs: settings.excludedBundleIDs,
                holdExcludedBundleIDs: settings.holdExcludedBundleIDs,
                paused: status == .paused || !settings.onboardingCompleted,
                capturing: captureMode,
                wechatHoldPreemptEnabled: settings.wechatHoldPreemptEnabled,
                swallowEscape: activeSession != nil
            )
        )
    }

    private func handle(_ event: MouseButtonEvent) {
        diagnostics.event(
            "mouse_button_received",
            bundleIdentifier: event.bundleIdentifier,
            button: event.button,
            role: event.role.logName
        )
        if event.role == .escape {
            cancelActiveSession(announce: true)
            return
        }
        if captureMode {
            guard event.kind == .down else { return }
            if let confirmationRole {
                lastHeardButton = event.button
                let expected = mouseBinding(for: confirmationRole).button
                showOverlay("收到 \(MouseBinding(button: event.button).displayName)", tone: .listening)
                if event.button == expected {
                    captureMode = false
                    captureTimeout?.cancel()
                    captureTimeout = nil
                    captureRole = nil
                    self.confirmationRole = nil
                    skipOnboardingConfirm(for: confirmationRole)
                } else {
                    showNotice(
                        "收到 \(MouseBinding(button: event.button).displayName)，请按 \(MouseBinding(button: expected).displayName)"
                    )
                }
                return
            }
            captureMode = false
            captureTimeout?.cancel()
            captureTimeout = nil
            let role = captureRole ?? .hold
            captureRole = nil
            setMouseButton(event.button, for: role)
            status = .ready
            syncMonitorConfiguration()
            persist()
            showNotice("已将\(role.displayName)设置为：\(MouseBinding(button: event.button).displayName)")
            return
        }

        switch event.role {
        case .hold:
            switch event.kind {
            case .down:
                beginSession(event)
            case .up:
                endSession(event)
            case .dragged:
                updateHoldCancel(event)
            }
        case .toggle:
            guard event.kind == .down else { return }
            if activeSession == nil {
                beginSession(event)
            } else {
                endSession(event)
            }
        case .enter:
            guard event.kind == .down else { return }
            sendEnter()
        case .capture, .unbound, .escape:
            break
        }
    }

    private func sendEnter() {
        guard status != .paused, activeSession == nil else { return }
        do {
            try shortcutEmitter.tap(settings.enterShortcut)
            diagnostics.event("enter_emitted")
            showOverlay("发送", tone: .send, autoHide: 1.2)
        } catch {
            showNotice("发送回车失败")
        }
    }

    private func beginSession(_ event: MouseButtonEvent) {
        guard status != .paused,
              settings.onboardingCompleted,
              Date() >= sessionCooldownUntil
        else { return }
        guard event.role == .hold || event.role == .toggle else { return }

        if let existing = activeSession {
            if event.role == .hold && existing.role == .toggle {
                diagnostics.event(
                    "session_preempted_by_hold",
                    bundleIdentifier: event.bundleIdentifier
                )
                cancelActiveSession(announce: false)
            } else {
                return
            }
        }

        let shortcut = shortcut(for: event.role)
        let anchor: TextSessionAnchor?
        do {
            let captured = try textAdapter.beginSession(targetProcessIdentifier: event.processIdentifier)
            anchor = captured
            diagnostics.event(
                "anchor_captured",
                bundleIdentifier: event.bundleIdentifier,
                role: "\(captured.identity.role):\(captured.originalText.count)chars"
            )
        } catch {
            anchor = nil
            diagnostics.event(
                "anchor_failed",
                bundleIdentifier: event.bundleIdentifier,
                role: "\(error)"
            )
        }
        let session = ActiveSession(
            anchor: anchor,
            role: event.role,
            shortcut: shortcut,
            bundleIdentifier: event.bundleIdentifier,
            processIdentifier: event.processIdentifier,
            pressOrigin: event.location
        )
        activeSession = session

        do {
            if event.role == .hold {
                session.replacingSelection = event.preservesSelection
                    || selectionRestorer.restore()
                try shortcutEmitter.keyDown(shortcut)
            } else {
                try shortcutEmitter.tap(shortcut)
            }
            diagnostics.event(
                "mouse_session_started",
                bundleIdentifier: event.bundleIdentifier
            )
            status = .listening
            let message: String
            if event.role == .hold {
                message = session.replacingSelection
                    ? "将替换选中文字"
                    : "松开以停止"
            } else {
                message = "听写中"
            }
            showOverlay(message, tone: .listening)
            syncMonitorConfiguration()

            if session.role == .toggle {
                let sessionID = session.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                    guard let self, self.activeSession?.id == sessionID else { return }
                    self.diagnostics.event(
                        "session_timeout",
                        bundleIdentifier: self.activeSession?.bundleIdentifier
                    )
                    self.cancelActiveSession(announce: true)
                }
            }
        } catch {
            selectionRestorer.clear()
            activeSession = nil
            status = .error
            showNotice("无法发送豆包快捷键")
        }
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
            showOverlay("再拖将停止", tone: .cancelArmed)
        } else {
            let message = session.replacingSelection
                ? "将替换选中文字"
                : "松开以停止"
            showOverlay(message, tone: .listening)
        }
    }

    private func endSession(_ event: MouseButtonEvent) {
        guard let session = activeSession,
              session.phase == .listening
        else {
            return
        }

        guard event.role == session.role else {
            return
        }

        if let bundleIdentifier = session.bundleIdentifier,
           bundleIdentifier != event.bundleIdentifier
        {
            cancelActiveSession(announce: true)
            return
        }

        session.phase = .processing
        do {
            if session.role == .hold {
                if session.replacingSelection {
                    _ = selectionRestorer.restore()
                }
                try shortcutEmitter.keyUp(session.shortcut)
                selectionRestorer.clear()
            } else {
                try shortcutEmitter.tap(session.shortcut)
            }
            diagnostics.event(
                "shortcut_emitted",
                bundleIdentifier: session.bundleIdentifier
            )
        } catch {
            session.cancellation.cancel()
            activeSession = nil
            status = .error
            showNotice("无法停止豆包听写")
            syncMonitorConfiguration()
            return
        }

        let announceStop = session.cancelArmed
        if announceStop {
            session.cancellation.cancel()
            finishSession(session.id, announceStop: true)
            return
        }

        guard let anchor = session.anchor, !settings.macroRules.isEmpty else {
            diagnostics.event(
                "macro_skipped",
                bundleIdentifier: session.bundleIdentifier,
                role: session.anchor == nil ? "no_anchor" : "no_rules"
            )
            finishSession(session.id, announceStop: false)
            return
        }

        status = .processing
        showOverlay("正在处理", tone: .listening)
        let rules = settings.macroRules
        let adapter = textAdapter
        let token = session.cancellation
        let diagnostics = self.diagnostics
        let bundleID = session.bundleIdentifier
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let inserted = try adapter.waitForInsertedText(
                    after: anchor,
                    timeout: 1.8
                )
                guard !token.isCancelled else { return }
                diagnostics.event(
                    "inserted_text",
                    bundleIdentifier: bundleID,
                    role: inserted.text
                )
                let result = MacroEngine().apply(inserted.text, rules: rules)
                diagnostics.event(
                    "macro_result",
                    bundleIdentifier: bundleID,
                    role: "matches=\(result.matchCount):output=\(result.output)"
                )
                guard result.changed else {
                    DispatchQueue.main.async {
                        self?.finishSession(session.id, announceStop: false)
                    }
                    return
                }
                guard !token.isCancelled else { return }
                try adapter.replace(inserted, with: result.output)
                diagnostics.event("replace_success", bundleIdentifier: bundleID)
                DispatchQueue.main.async {
                    self?.finishSession(
                        session.id,
                        announceStop: false,
                        noticeMessage: "已应用 \(result.matchCount) 条语音宏"
                    )
                }
            } catch {
                guard !token.isCancelled else { return }
                diagnostics.event(
                    "replace_error",
                    bundleIdentifier: bundleID,
                    role: "\(error)"
                )
                DispatchQueue.main.async {
                    self?.finishSession(session.id, announceStop: false)
                }
            }
        }
    }

    private func finishSession(
        _ id: UUID,
        announceStop: Bool,
        noticeMessage: String? = nil
    ) {
        guard activeSession?.id == id else { return }
        activeSession = nil
        sessionCooldownUntil = Date().addingTimeInterval(sessionCooldown)
        status = hasRequiredPermissions ? .ready : .permission
        syncMonitorConfiguration()
        if announceStop {
            showOverlay("已停止", tone: .stopped, autoHide: 1.4)
        } else if let noticeMessage {
            showOverlay(noticeMessage, tone: .send, autoHide: 1.2)
        } else {
            overlayController.hide()
        }
    }

    private func cancelActiveSession(announce: Bool = false) {
        guard let session = activeSession else { return }
        session.cancellation.cancel()
        if session.phase == .listening {
            if session.role == .hold {
                if session.replacingSelection {
                    _ = selectionRestorer.restore()
                }
                try? shortcutEmitter.keyUp(session.shortcut)
            } else {
                try? shortcutEmitter.tap(session.shortcut)
            }
        }
        selectionRestorer.clear()
        activeSession = nil
        if status != .paused {
            status = hasRequiredPermissions ? .ready : .permission
        }
        syncMonitorConfiguration()
        if announce {
            showOverlay("已停止", tone: .stopped, autoHide: 1.4)
        } else {
            overlayController.hide()
        }
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
            cancelActiveSession(announce: true)
        }
    }

    private func observeLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter
        let notifications: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        for name in notifications {
            let observer = workspace.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.cancelActiveSession(announce: true)
                }
            }
            lifecycleObservers.append(observer)
        }
        let terminate = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.cancelActiveSession(announce: false)
            }
        }
        lifecycleObservers.append(terminate)
    }

    private func showOverlay(
        _ message: String,
        tone: OverlayTone = .listening,
        autoHide: TimeInterval? = nil
    ) {
        guard settings.overlayEnabled else { return }
        overlayController.show(message, tone: tone, autoHide: autoHide)
    }

    private func showNotice(_ message: String) {
        notice = message
        showOverlay(message, tone: .notice, autoHide: 2.2)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.notice == message else { return }
            self.notice = nil
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
            (!requiresInputMonitoringForConfiguredButtons ||
                permissionSnapshot.inputMonitoringAuthorized)
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        for observer in lifecycleObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private final class Diagnostics: @unchecked Sendable {
    private let logger = Logger(
        subsystem: "com.jarod.doubao-voice-helper",
        category: "runtime"
    )

    func event(
        _ name: String,
        bundleIdentifier: String? = nil,
        button: Int64? = nil,
        role: String? = nil
    ) {
        let bundle = bundleIdentifier ?? "unknown"
        let buttonValue = button.map(String.init) ?? "none"
        let roleValue = role ?? "none"
        logger.notice(
            "event=\(name, privacy: .public) bundle=\(bundle, privacy: .public) button=\(buttonValue, privacy: .public) role=\(roleValue, privacy: .public)"
        )
    }
}
