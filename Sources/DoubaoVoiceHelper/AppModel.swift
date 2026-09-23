import AppKit
import Combine
import Foundation
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

enum OnboardingPhase: Equatable {
    case intro
    case permissions
    case confirm(MouseBindingRole)
    case optionsPlus(MouseBindingRole)
    case loginItem
    case done
}

/// User-editable lists of bundle identifiers.
enum AppList {
    case navigationExcluded
    case keystrokeFallback
    case terminalMacro

    var pickerPrompt: String {
        switch self {
        case .navigationExcluded: return "添加排除"
        case .keystrokeFallback: return "允许击键写回"
        case .terminalMacro: return "添加终端"
        }
    }

    var pickerMessage: String {
        switch self {
        case .navigationExcluded:
            return "选择在其中保留鼠标前进/后退原生导航的应用"
        case .keystrokeFallback:
            return "选择不接受辅助功能写入、需要用模拟击键完成语音宏替换的应用"
        case .terminalMacro:
            return "选择要在提示符处执行语音宏的终端应用"
        }
    }
}

/// UI state, settings, permissions and onboarding. Dictation sessions are
/// run by `DictationCoordinator`.
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
    let loginItemService: LoginItemService
    let overlayController: StatusOverlayController
    let selectionRestorer: AXSelectionRestorer
    let updateService = UpdateService()

    private let diagnostics = Diagnostics()
    private let coordinator: DictationCoordinator
    private lazy var mouseMonitor = MouseEventMonitor(
        configuration: monitorConfiguration(),
        selectionRestorer: selectionRestorer,
        callbackHandler: { [weak self] event in
            DispatchQueue.main.async {
                self?.handle(event)
            }
        }
    )
    private let observers = ObserverTokens()
    private var monitorStarted = false
    private var captureMode = false
    private var confirmationRole: MouseBindingRole?
    private var captureTimeout: DispatchWorkItem?
    private var pendingSave: DispatchWorkItem?

    private static let saveDebounce: TimeInterval = 0.6

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
        self.loginItemService = loginItemService
        self.overlayController = overlayController ?? StatusOverlayController()
        self.selectionRestorer = selectionRestorer
        self.coordinator = DictationCoordinator(
            shortcutEmitter: shortcutEmitter,
            textAdapter: textAdapter,
            selectionRestorer: selectionRestorer,
            diagnostics: diagnostics
        )
        let loaded = repository.load()
        self.settings = loaded
        self.onboardingPhase = loaded.onboardingCompleted ? .done : .intro
        try? repository.save(loaded)
        coordinator.delegate = self

        // First launch asks for permissions inside onboarding instead.
        if loaded.onboardingCompleted,
           !permissionService.snapshot().accessibilityTrusted
        {
            _ = permissionService.requestAccessibility()
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

    /// The settings window opens by itself only when the user has to act.
    var needsAttentionOnLaunch: Bool {
        !settings.onboardingCompleted || !hasRequiredPermissions
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
        flushPendingSave()
        let currentVersion = appVersionString
        Task {
            await updateService.downloadAndInstall(
                downloadURL: downloadURL,
                currentAppURL: Bundle.main.bundleURL,
                currentVersion: currentVersion
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

    var macroValidationIssues: [UUID: MacroValidationIssue.Kind] {
        Dictionary(
            MacroEngine().validate(settings.macroRules).map { ($0.ruleID, $0.kind) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Permissions and integrations

    func refreshPermissions() {
        permissionSnapshot = permissionService.snapshot()
        checkLogiOptionsStatus()
        if !hasRequiredPermissions, !coordinator.isActive {
            status = .permission
        } else if status == .permission {
            status = .ready
        }
    }

    func checkLogiOptionsStatus() {
        logiOptionsInstalled = LogiOptionsPatcher.shared.isInstalled
        guard logiOptionsInstalled else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let needs = LogiOptionsPatcher.shared.needsFix()
            DispatchQueue.main.async {
                self?.logiOptionsNeedsFix = needs
            }
        }
    }

    func patchLogiOptions() {
        logiOptionsPatching = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message: String
            let patched: Bool
            do {
                let result = try LogiOptionsPatcher.shared.patch()
                message = "成功修复 \(result.count) 处罗技侧键配置为原生按键！"
                patched = true
            } catch {
                message = "修复失败：\(error.localizedDescription)"
                patched = false
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.logiOptionsPatching = false
                if patched { self.logiOptionsNeedsFix = false }
                self.showNotice(message)
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

    // MARK: - General settings

    func setPaused(_ paused: Bool) {
        if paused {
            coordinator.cancel()
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

    // MARK: - Bindings

    func mouseBinding(for role: MouseBindingRole) -> MouseBinding {
        switch role {
        case .toggle: return settings.toggleMouseBinding
        case .hold: return settings.holdMouseBinding
        case .enter: return settings.enterMouseBinding
        case .capture, .unbound, .escape: return MouseBinding()
        }
    }

    /// Returns `false` when the button was rejected.
    @discardableResult
    func setMouseButton(_ button: Int64, for role: MouseBindingRole) -> Bool {
        if button == 0 || button == 1 {
            showNotice("鼠标左键与右键已保留为系统操作，不能绑定")
            return false
        }
        guard button == -1 || button > 1 else { return false }
        if button > 1,
           let owner = [MouseBindingRole.toggle, .hold, .enter].first(where: {
               $0 != role && mouseBinding(for: $0).button == button
           })
        {
            showNotice("\(MouseBinding(button: button).displayName)已用于\(owner.displayName)")
            return false
        }
        switch role {
        case .toggle:
            settings.toggleMouseBinding.button = button
        case .hold:
            settings.holdMouseBinding.button = button
        case .enter:
            settings.enterMouseBinding.button = button
        case .capture, .unbound, .escape:
            return false
        }
        syncMonitorConfiguration()
        persist()
        return true
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
            MainActor.assumeIsolated {
                self?.captureTimedOut(role: role)
            }
        }
        captureTimeout = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (confirming ? 8 : 10),
            execute: timeout
        )
    }

    private func captureTimedOut(role: MouseBindingRole) {
        guard captureMode else { return }
        let showOptionsPlusHelp = confirmationRole != nil &&
            (role == .toggle || role == .enter)
        captureMode = false
        captureRole = nil
        confirmationRole = nil
        captureTimeout = nil
        status = hasRequiredPermissions ? .ready : .permission
        syncMonitorConfiguration()
        if showOptionsPlusHelp {
            onboardingPhase = .optionsPlus(role)
            overlayController.hide()
        } else {
            showNotice("鼠标键捕获超时，请重试")
        }
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

    // MARK: - Macro rules

    func addMacroRule() {
        settings.macroRules.append(
            MacroRule(source: "", replacement: "", isEnabled: true)
        )
        persist()
    }

    func removeMacroRule(id: UUID) {
        settings.macroRules.removeAll { $0.id == id }
        persist()
    }

    /// Text edits arrive per keystroke, so they are saved after a short pause.
    func updateMacroRule(id: UUID, _ update: (inout MacroRule) -> Void) {
        guard let index = settings.macroRules.firstIndex(where: { $0.id == id }) else { return }
        update(&settings.macroRules[index])
        schedulePersist()
    }

    func preview(_ text: String) -> MacroResult {
        MacroEngine().apply(text, rules: settings.macroRules)
    }

    // MARK: - App lists

    func bundleIDs(in list: AppList) -> [String] {
        switch list {
        case .navigationExcluded: return settings.excludedBundleIDs
        case .keystrokeFallback: return settings.keystrokeFallbackBundleIDs
        case .terminalMacro: return settings.terminalMacroBundleIDs
        }
    }

    private func setBundleIDs(_ ids: [String], in list: AppList) {
        switch list {
        case .navigationExcluded:
            settings.excludedBundleIDs = ids
            syncMonitorConfiguration()
        case .keystrokeFallback:
            settings.keystrokeFallbackBundleIDs = ids
        case .terminalMacro:
            settings.terminalMacroBundleIDs = ids
        }
        persist()
    }

    func addBundleID(_ bundleID: String, to list: AppList) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        var ids = bundleIDs(in: list)
        guard !trimmed.isEmpty, !ids.contains(trimmed) else { return }
        ids.append(trimmed)
        setBundleIDs(ids, in: list)
    }

    func removeBundleID(_ bundleID: String, from list: AppList) {
        setBundleIDs(bundleIDs(in: list).filter { $0 != bundleID }, in: list)
    }

    func pickApplications(for list: AppList, window: NSWindow? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = list.pickerPrompt
        panel.message = list.pickerMessage

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            let bundleIDs = panel.urls.compactMap { Bundle(url: $0)?.bundleIdentifier }
            MainActor.assumeIsolated {
                for bundleID in bundleIDs {
                    self?.addBundleID(bundleID, to: list)
                }
            }
        }
        if let targetWindow = window ?? NSApp.keyWindow ?? NSApp.windows.first {
            panel.beginSheetModal(for: targetWindow, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    // MARK: - Persistence

    func persist() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try repository.save(settings)
        } catch {
            showNotice("设置保存失败")
        }
    }

    private func schedulePersist() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.persist()
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounce, execute: work)
    }

    private func flushPendingSave() {
        if pendingSave != nil {
            persist()
        }
    }

    // MARK: - Onboarding

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
            if settings.holdMouseBinding.button > 1 {
                beginOnboardingConfirm(for: .hold)
            } else {
                beginOnboardingConfirm(for: .enter)
            }
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

    // MARK: - Monitoring

    private func startMonitoringIfPossible() {
        guard !monitorStarted, hasRequiredPermissions else {
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

    private func monitorConfiguration() -> MouseEventMonitor.Configuration {
        .init(
            toggleButton: settings.toggleMouseBinding.button,
            holdButton: settings.holdMouseBinding.button,
            enterButton: settings.enterMouseBinding.button,
            navigationExcludedBundleIDs: settings.excludedBundleIDs,
            holdExcludedBundleIDs: settings.holdExcludedBundleIDs,
            paused: status == .paused || !settings.onboardingCompleted,
            capturing: captureMode,
            listensForEscape: coordinator.isActive
        )
    }

    private func syncMonitorConfiguration() {
        mouseMonitor.update(configuration: monitorConfiguration())
    }

    private func handle(_ event: MouseButtonEvent) {
        diagnostics.event(
            "mouse_button_received",
            bundleIdentifier: event.bundleIdentifier,
            button: event.button,
            detail: event.role.logName
        )
        if event.role == .escape {
            coordinator.cancel(announce: true, emitCancelShortcut: false)
            return
        }
        if captureMode {
            handleCapture(event)
            return
        }
        coordinator.handleTrigger(event)
    }

    private func handleCapture(_ event: MouseButtonEvent) {
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
        status = hasRequiredPermissions ? .ready : .permission
        let accepted = setMouseButton(event.button, for: role)
        syncMonitorConfiguration()
        if accepted {
            showNotice("已将\(role.displayName)设置为：\(MouseBinding(button: event.button).displayName)")
        }
    }

    // MARK: - Lifecycle

    private func observeLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.addWorkspace(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else {
                return
            }
            MainActor.assumeIsolated {
                self?.coordinator.applicationDidActivate(application)
            }
        })

        let notifications: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        for name in notifications {
            observers.addWorkspace(workspace.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.coordinator.cancel(announce: true, emitCancelShortcut: false)
                }
            })
        }
        observers.addLocal(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushPendingSave()
                self?.coordinator.cancel(
                    announce: false,
                    emitCancelShortcut: false,
                    synchronous: true
                )
            }
        })
    }

    // MARK: - Feedback

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
            MainActor.assumeIsolated {
                guard let self, self.notice == message else { return }
                self.notice = nil
                if self.status == .error {
                    self.status = self.hasRequiredPermissions ? .ready : .permission
                }
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

}

/// Removes block-based observers when the owner goes away, without needing
/// an isolated deinit on the main-actor owner.
private final class ObserverTokens: @unchecked Sendable {
    private var workspace: [NSObjectProtocol] = []
    private var local: [NSObjectProtocol] = []

    func addWorkspace(_ token: NSObjectProtocol) {
        workspace.append(token)
    }

    func addLocal(_ token: NSObjectProtocol) {
        local.append(token)
    }

    deinit {
        workspace.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        local.forEach(NotificationCenter.default.removeObserver)
    }
}

extension AppModel: DictationCoordinatorDelegate {
    var dictationConfiguration: DictationConfiguration {
        DictationConfiguration(settings: settings, paused: status == .paused)
    }

    func dictationPhaseDidChange(_ phase: DictationPhase) {
        switch phase {
        case .listening:
            status = .listening
        case .processing:
            status = .processing
        case .idle:
            if status != .paused {
                status = hasRequiredPermissions ? .ready : .permission
            }
        }
        syncMonitorConfiguration()
    }

    func dictationShowOverlay(_ message: String, tone: OverlayTone, autoHide: TimeInterval?) {
        showOverlay(message, tone: tone, autoHide: autoHide)
    }

    func dictationHideOverlay() {
        overlayController.hide()
    }

    func dictationDidFail(_ message: String) {
        status = .error
        showNotice(message)
    }
}
