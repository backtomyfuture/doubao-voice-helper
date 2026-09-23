import AppKit
import SwiftUI
import DoubaoVoiceHelperCore

private typealias AppKeyboardShortcut = DoubaoVoiceHelperCore.KeyboardShortcut

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    private let openSettings: () -> Void

    init(openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(model.statusTitle)
            } icon: {
                MenuBarIcon(
                    imageName: model.status.menuBarIconName,
                    fallbackSystemName: model.status.symbolName
                )
            }
                .font(.headline)

            Divider()

            Button(model.isPaused ? "恢复监听" : "暂停监听") {
                model.setPaused(!model.isPaused)
            }
            Button {
                openSettings()
            } label: {
                Label("打开设置…", systemImage: "gear")
            }
            Button("检查权限") {
                model.refreshPermissions()
                model.requestAccessibilityPermission()
                if model.requiresInputMonitoringForConfiguredButtons {
                    model.requestInputMonitoringPermission()
                }
            }
            Button("检查更新…") {
                openSettings()
                model.checkForUpdates()
            }

            Divider()

            Button("退出") {
                NSApp.terminate(nil)
            }
        }
        .padding(10)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showManualExcludedInput = false
    @State private var manualExcludedBundleID = ""

    var body: some View {
        Form {
            Section("常规") {
                Toggle(
                    "登录时自动启动",
                    isOn: Binding(
                        get: { model.settings.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                Toggle(
                    "显示状态浮层",
                    isOn: Binding(
                        get: { model.settings.overlayEnabled },
                        set: { model.setOverlayEnabled($0) }
                    )
                )
                Text("本 App 不录音，只把鼠标动作映射到豆包快捷键。")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }

            Section("输入") {
                MouseMappingRow(role: .hold)
                    .environmentObject(model)
                MouseMappingRow(role: .toggle)
                    .environmentObject(model)
                MouseMappingRow(role: .enter)
                    .environmentObject(model)
                Text(
                    "默认：前进键为切换式语音，后退键发送 Return，按住式未绑定。左键和右键保留给系统，只能绑定侧键或中键。点击“录制按键”更换。"
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if model.logiOptionsInstalled {
                Section("罗技鼠标适配 (Logi Options+)") {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: model.logiOptionsNeedsFix ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(model.logiOptionsNeedsFix ? .orange : .green)
                            .font(.title2)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.logiOptionsNeedsFix ? "检测到侧键被罗技手势接管" : "罗技侧键已配置为原生按键")
                                .font(.headline)
                            Text(
                                model.logiOptionsNeedsFix
                                    ? "Logi Options+ 默认将侧键设为手势导航，导致系统与本助手无法收到鼠标事件。点击下方按钮即可一键修复为原生按键（Button 4/3），无需关闭罗技软件。"
                                    : "已将所有罗技鼠标前进/后退键修复为原生鼠标按键，可直接录制与正常使用。"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            Button {
                                model.patchLogiOptions()
                            } label: {
                                if model.logiOptionsPatching {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("正在修复…")
                                    }
                                } else {
                                    Label(
                                        model.logiOptionsNeedsFix ? "一键修复罗技侧键为原生按键" : "重新扫描并修复罗技侧键",
                                        systemImage: "wrench.and.screwdriver"
                                    )
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.logiOptionsPatching)
                            .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("语音宏（特殊文字替换）") {
                Text("听写结束时，将识别到的特定文字替换为目标符号或命令。长词优先；匹配时忽略标点和空格。用 | 分隔多个说法（如 斜杠|写杠）以兼容同音误识别。整句都是命令时，结尾标点会一并去掉。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(model.settings.macroRules) { rule in
                    MacroRuleIssueLabel(kind: model.macroValidationIssues[rule.id])
                    HStack(spacing: 8) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: {
                                    model.settings.macroRules.first(where: { $0.id == rule.id })?.isEnabled ?? false
                                },
                                set: { enabled in
                                    model.updateMacroRule(id: rule.id) { $0.isEnabled = enabled }
                                }
                            )
                        )
                        .labelsHidden()

                        TextField(
                            "识别词 (如 斜杠批准)",
                            text: Binding(
                                get: {
                                    model.settings.macroRules.first(where: { $0.id == rule.id })?.source ?? ""
                                },
                                set: { source in
                                    model.updateMacroRule(id: rule.id) { $0.source = source }
                                }
                            )
                        )
                        .frame(minWidth: 120)

                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .font(.caption)

                        TextField(
                            "替换为 (如 /approve)",
                            text: Binding(
                                get: {
                                    model.settings.macroRules.first(where: { $0.id == rule.id })?.replacement ?? ""
                                },
                                set: { replacement in
                                    model.updateMacroRule(id: rule.id) { $0.replacement = replacement }
                                }
                            )
                        )
                        .frame(minWidth: 120)

                        Button(role: .destructive) {
                            model.removeMacroRule(id: rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button {
                    model.addMacroRule()
                } label: {
                    Label("添加替换规则", systemImage: "plus.circle")
                }

                MacroPreviewRow()
                    .environmentObject(model)
            }

            Section("击键写回（语音宏）") {
                Text("部分应用（多为 Electron / Chromium 编辑器）不接受辅助功能写入。只有名单内的应用，才会在确认光标恰好位于本次听写文本之后时，用退格加模拟输入完成替换；名单外的应用保留原文。终端请加入下方的终端名单，而不是这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                AppBundleList(list: .keystrokeFallback, removeHelp: "从击键写回名单中移除")
                    .environmentObject(model)
            }

            Section("终端语音宏") {
                Text("名单内的终端会比对整屏文本：只有整屏除了光标处这一行的插入之外完全没有变化（没有命令输出、没有换行、没有占位提示被替换），才会用退格加模拟输入替换本次听写。其余情况保留原文。终端未开放辅助功能文本时自动退回“只触发”。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                AppBundleList(list: .terminalMacro, removeHelp: "从终端名单中移除")
                    .environmentObject(model)
            }

            Section("浏览器与导航排除") {
                Text("在此名单中的应用（如浏览器）内，鼠标侧键（前进/后退）将保留原生页面前进/后退功能，不触发切换式语音或回车。按住式语音不受此名单影响。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                ForEach(model.settings.excludedBundleIDs, id: \.self) { bundleID in
                    ExcludedAppRow(bundleID: bundleID) {
                        model.removeBundleID(bundleID, from: .navigationExcluded)
                    }
                }

                if showManualExcludedInput {
                    HStack(spacing: 8) {
                        TextField("输入应用的 Bundle Identifier (如 com.example.app)", text: $manualExcludedBundleID)
                            .textFieldStyle(.roundedBorder)

                        Button("添加") {
                            model.addBundleID(manualExcludedBundleID, to: .navigationExcluded)
                            manualExcludedBundleID = ""
                            showManualExcludedInput = false
                        }
                        .disabled(manualExcludedBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("取消") {
                            manualExcludedBundleID = ""
                            showManualExcludedInput = false
                        }
                    }
                    .padding(.vertical, 2)
                }

                HStack(spacing: 12) {
                    Button {
                        model.pickApplications(for: .navigationExcluded)
                    } label: {
                        Label("选择应用程序…", systemImage: "plus.circle")
                    }

                    Button {
                        showManualExcludedInput.toggle()
                    } label: {
                        Label(showManualExcludedInput ? "收起手动输入" : "手动输入 Bundle ID", systemImage: "pencil")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.top, 4)
            }

            Section("权限") {
                PermissionRow(
                    title: "辅助功能",
                    granted: model.permissionSnapshot.accessibilityTrusted,
                    required: true,
                    action: model.requestAccessibilityPermission,
                    settingsAction: model.openAccessibilitySettings
                )
                PermissionRow(
                    title: model.requiresInputMonitoringForConfiguredButtons
                        ? "输入监控（额外键必需）"
                        : "输入监控（可选）",
                    granted: model.permissionSnapshot.inputMonitoringAuthorized,
                    required: model.requiresInputMonitoringForConfiguredButtons,
                    action: model.requestInputMonitoringPermission,
                    settingsAction: model.openInputMonitoringSettings
                )
                Text(
                    "辅助功能用于监听鼠标并发送快捷键。前进/后退等额外鼠标键需要输入监控权限。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("软件与更新") {
                HStack {
                    Text("当前版本")
                    Spacer()
                    Text("v\(model.appVersionString)")
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }

                switch model.updateState {
                case .idle:
                    Button {
                        model.checkForUpdates()
                    } label: {
                        Label("检查更新", systemImage: "arrow.clockwise")
                    }

                case .checking:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在查询 GitHub 最新发布版本…")
                            .foregroundStyle(.secondary)
                    }

                case .upToDate(let version):
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("当前已是最新版本 (v\(version))")
                        Spacer()
                        Button("重新检查") {
                            model.checkForUpdates()
                        }
                    }

                case .noReleasesFound(let current):
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text("暂无公开发布版本 (当前版本: v\(current))")
                        Spacer()
                        Button("重新检查") {
                            model.checkForUpdates()
                        }
                    }

                case .updateAvailable(let newVersion, let notes, let downloadURL, let releasePageURL):
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("发现新版本 \(newVersion)")
                                    .font(.headline)
                                Text("可直接一键更新替换本地应用并自动重启")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !notes.isEmpty {
                            Text(notes)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.08))
                                .cornerRadius(6)
                        }

                        HStack(spacing: 12) {
                            if downloadURL != nil {
                                Button {
                                    model.downloadAndInstallUpdate()
                                } label: {
                                    Label("一键更新并重启", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            Button("在 GitHub 查看发行注记") {
                                NSWorkspace.shared.open(releasePageURL)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                case .downloading(let progress):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("正在下载新版本…")
                            Spacer()
                            Text("\(Int(progress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: progress)
                    }
                    .padding(.vertical, 4)

                case .installing:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在解压安装，即将自动重启应用…")
                    }
                    .padding(.vertical, 4)

                case .failed(let error):
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("检查更新失败: \(error)")
                                .font(.caption)
                        }
                        HStack(spacing: 12) {
                            Button("重试") {
                                model.checkForUpdates()
                            }
                            Button("前往 GitHub 手动下载") {
                                model.openReleasesPage()
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section("说明") {
                Text(
                    "按住式：约 280ms 长按开始，达到前移动超过 10pt 视为拖拽。长按中拖远可停止且不做语音宏。听写中按 Esc 停止豆包。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 680, minHeight: 620)
        .padding()
        .onAppear {
            model.refreshPermissions()
        }
    }
}

private struct MouseMappingRow: View {
    @EnvironmentObject private var model: AppModel
    @State private var isRecordingShortcut = false
    let role: MouseBindingRole

    private var isCapturing: Bool {
        model.captureRole == role
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(role.displayName)
                    .font(.headline)
                    .frame(minWidth: 90, alignment: .leading)

                Spacer()

                // 鼠标按键 Badge 友好展示
                HStack(spacing: 6) {
                    Image(systemName: "computermouse.fill")
                        .foregroundStyle(isCapturing ? .orange : .secondary)
                        .font(.caption)
                    Text(model.mouseBinding(for: role).displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isCapturing ? .orange : .primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isCapturing ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.08))
                .cornerRadius(6)

                // 录制鼠标键按钮
                if isCapturing {
                    Button {
                        model.cancelMouseButtonCapture()
                    } label: {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("请按鼠标键… (点击取消)")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    HStack(spacing: 6) {
                        Button {
                            model.beginMouseButtonCapture(for: role)
                        } label: {
                            Label("录制按键", systemImage: "hand.tap")
                        }
                        .buttonStyle(.bordered)

                        if model.mouseBinding(for: role).button > 1 {
                            Button("清空") {
                                model.setMouseButton(-1, for: role)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                Text("触发的快捷键")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Spacer()
                ShortcutRecorder(
                    shortcut: Binding(
                        get: { model.shortcut(for: role) },
                        set: { model.setShortcut($0, for: role) }
                    ),
                    isRecording: $isRecordingShortcut
                )
                .frame(minWidth: 140, minHeight: 26, maxHeight: 26)

                Button(isRecordingShortcut ? "完成" : "修改") {
                    isRecordingShortcut.toggle()
                }

                Menu {
                    Button("左 Control (豆包默认)") {
                        model.setShortcut(AppKeyboardShortcut.leftControl, for: role)
                    }
                    Button("左 Command + 左 Control") {
                        model.setShortcut(AppKeyboardShortcut.leftCommandLeftControl, for: role)
                    }
                    Button("左 Control + Option") {
                        model.setShortcut(AppKeyboardShortcut.leftControlOption, for: role)
                    }
                    Button("右 Control") {
                        model.setShortcut(AppKeyboardShortcut.rightControl, for: role)
                    }
                    Divider()
                    Button("Return (回车)") {
                        model.setShortcut(AppKeyboardShortcut.returnKey, for: role)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .help("选择常用快捷键预设")
            }
        }
        .padding(.vertical, 3)
    }
}

struct PermissionRow: View {
    let title: String
    let granted: Bool
    let required: Bool
    let action: () -> Void
    let settingsAction: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            Text(
                granted
                    ? "已授权"
                    : required ? "未授权" : "可选"
            )
                .foregroundStyle(.secondary)
            if !granted {
                Button("请求") {
                    action()
                }
                Button("打开设置") {
                    settingsAction()
                }
            }
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: AppKeyboardShortcut
    @Binding var isRecording: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.shortcut = shortcut
        view.onShortcut = { value in
            context.coordinator.parent.shortcut = value
            context.coordinator.parent.isRecording = false
        }
        view.onCancel = {
            context.coordinator.parent.isRecording = false
        }
        view.onRecordingChanged = { recording in
            context.coordinator.parent.isRecording = recording
        }
        view.isRecording = isRecording
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        context.coordinator.parent = self
        nsView.shortcut = shortcut
        nsView.setRecording(isRecording)
        nsView.needsDisplay = true
    }

    final class Coordinator {
        var parent: ShortcutRecorder

        init(_ parent: ShortcutRecorder) {
            self.parent = parent
        }
    }
}

private final class ShortcutRecorderView: NSView {
    var shortcut = AppKeyboardShortcut.doubaoDefault
    var onShortcut: ((AppKeyboardShortcut) -> Void)?
    var onCancel: (() -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    private var activeModifierShortcut: AppKeyboardShortcut?
    private var capturedKeyCodes: [UInt16] = []
    private var localMonitor: Any?
    var isRecording = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 140, height: 26)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        } else {
            // Leaving the window is the last main-actor callback before the
            // view is released, so the key monitor is removed here.
            stopLocalMonitor()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowDidResignKey() {
        guard isRecording else { return }
        // 当窗口失去焦点（例如按下快捷键直接触发了豆包官方悬浮窗抢占焦点），
        // 如果已经捕获到了按键，自动确认为用户要设置的快捷键，避免因失焦漏掉松开事件而录制失败
        if let activeModifierShortcut {
            shortcut = activeModifierShortcut
            onShortcut?(shortcut)
            self.activeModifierShortcut = nil
            capturedKeyCodes.removeAll()
            stopLocalMonitor()
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        onRecordingChanged?(!isRecording)
    }

    func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        if !recording {
            if let activeModifierShortcut {
                shortcut = activeModifierShortcut
                onShortcut?(shortcut)
            }
            stopLocalMonitor()
        }
        isRecording = recording
        activeModifierShortcut = nil
        capturedKeyCodes.removeAll()
        if recording {
            startLocalMonitor()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        } else if window?.firstResponder === self {
            window?.makeFirstResponder(window?.contentView)
        }
        needsDisplay = true
    }

    private func startLocalMonitor() {
        stopLocalMonitor()
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { [weak self] event in
            guard let self, self.isRecording else { return event }
            if event.type == .keyDown {
                self.handleKeyDown(with: event)
                return nil
            } else if event.type == .flagsChanged {
                self.handleFlagsChanged(with: event)
                return nil
            }
            return event
        }
    }

    private func stopLocalMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        handleKeyDown(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        handleFlagsChanged(with: event)
    }

    private func handleKeyDown(with event: NSEvent) {
        guard isRecording else { return }
        if event.keyCode == 53 {
            isRecording = false
            activeModifierShortcut = nil
            capturedKeyCodes.removeAll()
            stopLocalMonitor()
            onCancel?()
            needsDisplay = true
            return
        }
        shortcut = AppKeyboardShortcut(
            keyCode: event.keyCode,
            modifiers: modifiers(from: event.modifierFlags),
            physicalKeyCodes: capturedKeyCodes + [event.keyCode]
        )
        activeModifierShortcut = nil
        capturedKeyCodes.removeAll()
        stopLocalMonitor()
        onShortcut?(shortcut)
        needsDisplay = true
    }

    private func handleFlagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        let activeModifiers = modifiers(from: event.modifierFlags)
        if activeModifiers.isEmpty {
            if let activeModifierShortcut {
                shortcut = activeModifierShortcut
                onShortcut?(shortcut)
            }
            activeModifierShortcut = nil
            capturedKeyCodes.removeAll()
            stopLocalMonitor()
            needsDisplay = true
            return
        }

        if ShortcutStroke.isModifierKey(event.keyCode),
           !capturedKeyCodes.contains(event.keyCode)
        {
            capturedKeyCodes.append(event.keyCode)
        }
        guard !capturedKeyCodes.isEmpty else { return }
        activeModifierShortcut = AppKeyboardShortcut(
            physicalKeyCodes: capturedKeyCodes
        )
        needsDisplay = true
    }

    private func modifiers(
        from flags: NSEvent.ModifierFlags
    ) -> Set<KeyboardModifier> {
        var result = Set<KeyboardModifier>()
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.function) { result.insert(.function) }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            border.lineWidth = 1.5
            border.stroke()
        } else {
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).stroke()
        }

        let text: String
        let textColor: NSColor
        if isRecording {
            if let activeModifierShortcut {
                text = activeModifierShortcut.displayName
                textColor = .controlAccentColor
            } else {
                text = "请按下快捷键…"
                textColor = .secondaryLabelColor
            }
        } else {
            text = shortcut.displayName
            textColor = .labelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: textColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2
            ),
            withAttributes: attributes
        )
    }
}

struct ExcludedAppMetadata {
    let bundleID: String
    let name: String
    let icon: NSImage

    private static let knownFriendlyNames: [String: String] = [
        "com.apple.Safari": "Safari 浏览器",
        "com.google.Chrome": "Google Chrome",
        "com.microsoft.edgemac": "Microsoft Edge 浏览器",
        "org.mozilla.firefox": "Firefox 火狐浏览器",
        "company.thebrowser.Browser": "Arc 浏览器",
        "com.stablyai.orca": "Orca",
        "com.todesktop.230313m46w4u92": "Cursor",
        "com.microsoft.VSCode": "Visual Studio Code",
        "com.citrolabs.ego": "Ego 浏览器",
        "com.citrolabs.ego.lite": "Ego Lite",
        "com.brave.Browser": "Brave 浏览器",
        "com.operasoftware.Opera": "Opera 浏览器",
        "com.vivaldi.Vivaldi": "Vivaldi 浏览器",
        "com.apple.Terminal": "终端 (Terminal)",
        "com.mitchellh.ghostty": "Ghostty",
        "com.github.wez.wezterm": "WezTerm",
        "com.googlecode.iterm2": "iTerm2",
        "net.kovidgoyal.kitty": "kitty",
        "dev.warp.Warp-Stable": "Warp",
        AppSettings.bundleIdentifier: "豆包语音助手",
    ]

    static func resolve(for bundleID: String) -> ExcludedAppMetadata {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let fileManagerName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let friendlyName = knownFriendlyNames[bundleID] ?? fileManagerName
            return ExcludedAppMetadata(bundleID: bundleID, name: friendlyName, icon: icon)
        } else {
            let friendlyName = knownFriendlyNames[bundleID] ?? (bundleID.components(separatedBy: ".").last ?? bundleID)
            let icon = NSWorkspace.shared.icon(for: .application)
            return ExcludedAppMetadata(bundleID: bundleID, name: friendlyName, icon: icon)
        }
    }
}

private struct AppBundleList: View {
    @EnvironmentObject private var model: AppModel
    let list: AppList
    let removeHelp: String

    var body: some View {
        ForEach(model.bundleIDs(in: list), id: \.self) { bundleID in
            ExcludedAppRow(bundleID: bundleID, removeHelp: removeHelp) {
                model.removeBundleID(bundleID, from: list)
            }
        }

        Button {
            model.pickApplications(for: list)
        } label: {
            Label("选择应用程序…", systemImage: "plus.circle")
        }
        .padding(.top, 4)
    }
}

private struct MacroRuleIssueLabel: View {
    let kind: MacroValidationIssue.Kind?

    var body: some View {
        if let kind {
            Label(
                kind == .emptySource ? "识别词为空，此规则不会生效" : "识别词与上方规则重复，只有先出现的规则生效",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }
}

private struct MacroPreviewRow: View {
    @EnvironmentObject private var model: AppModel
    @State private var sample = "斜杠批准。"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("输入一段听写文本试试效果", text: $sample)
                .textFieldStyle(.roundedBorder)
            let result = model.preview(sample)
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(.secondary)
                Text(result.output.isEmpty ? " " : result.output)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Text(result.changed ? "命中 \(result.matchCount) 条" : "无命中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}

private struct ExcludedAppRow: View {
    let bundleID: String
    var removeHelp = "从排除名单中移除"
    let onDelete: () -> Void

    private var metadata: ExcludedAppMetadata {
        ExcludedAppMetadata.resolve(for: bundleID)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: metadata.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(metadata.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(bundleID)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(removeHelp)
        }
        .padding(.vertical, 3)
    }
}
