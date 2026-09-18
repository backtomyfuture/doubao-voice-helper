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
                Toggle(
                    "微信输入区抢跑（避免和微信自己的长按语音冲突）",
                    isOn: Binding(
                        get: { model.settings.wechatHoldPreemptEnabled },
                        set: { model.setWechatHoldPreemptEnabled($0) }
                    )
                )
            }

            Section("输入") {
                MouseMappingRow(role: .toggle)
                    .environmentObject(model)
                MouseMappingRow(role: .hold)
                    .environmentObject(model)
                MouseMappingRow(role: .enter)
                    .environmentObject(model)
                Text(
                    "默认：前进键切换语音；左键长按使用左 Control + Option；后退键发送 Return。非浏览器里后退键会发送。"
                )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("导航排除") {
                Text("这些应用里前进/后退仍是系统导航。左键长按不受此名单影响。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(
                    model.settings.excludedBundleIDs.indices,
                    id: \.self
                ) { index in
                    HStack {
                        TextField(
                            "bundle identifier",
                            text: Binding(
                                get: {
                                    model.settings.excludedBundleIDs[index]
                                },
                                set: {
                                    model.updateExcludedBundleID(
                                        at: index,
                                        value: $0
                                    )
                                }
                            )
                        )
                        Button(role: .destructive) {
                            model.removeExcludedBundleID(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("添加排除应用") {
                    model.addExcludedBundleID()
                }
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

            Section("说明") {
                Text(
                    "按住式：约 280ms 长按，移动超过 6pt 当拖拽。拖远可取消。Esc 在听写中停止豆包。微信里会抢在官方长按语音之前接管左键。"
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(role.displayName)
                    .font(.headline)
                Spacer()
                TextField(
                    "button",
                    text: Binding(
                        get: {
                            String(model.mouseBinding(for: role).button)
                        },
                        set: {
                            if let value = Int64($0) {
                                model.setMouseButton(value, for: role)
                            }
                        }
                    )
                )
                .frame(width: 55)
                Text(model.mouseBinding(for: role).displayName)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .leading)
                Button(model.captureRole == role ? "取消" : "设置") {
                    if model.captureRole == role {
                        model.cancelMouseButtonCapture()
                    } else {
                        model.beginMouseButtonCapture(for: role)
                    }
                }
            }

            HStack {
                Text("豆包快捷键")
                    .foregroundStyle(.secondary)
                ShortcutRecorder(
                    shortcut: Binding(
                        get: { model.shortcut(for: role) },
                        set: { model.setShortcut($0, for: role) }
                    ),
                    isRecording: $isRecordingShortcut
                )
                Button(isRecordingShortcut ? "取消" : "设置") {
                    isRecordingShortcut.toggle()
                }
            }
        }
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
        view.isRecording = isRecording
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
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
    private var activeModifierShortcut: AppKeyboardShortcut?
    private var capturedKeyCodes: [UInt16] = []
    var isRecording = false

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            window?.makeFirstResponder(self)
        }
    }

    func setRecording(_ recording: Bool) {
        guard recording != isRecording else { return }
        isRecording = recording
        activeModifierShortcut = nil
        capturedKeyCodes.removeAll()
        if recording {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        } else if window?.firstResponder === self {
            window?.makeFirstResponder(window?.contentView)
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        if event.keyCode == 53 {
            isRecording = false
            activeModifierShortcut = nil
            capturedKeyCodes.removeAll()
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
        onShortcut?(shortcut)
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        let activeModifiers = modifiers(from: event.modifierFlags)
        if activeModifiers.isEmpty {
            if let activeModifierShortcut {
                shortcut = activeModifierShortcut
                onShortcut?(shortcut)
            }
            activeModifierShortcut = nil
            capturedKeyCodes.removeAll()
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
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).stroke()

        let text = (isRecording ? activeModifierShortcut : nil)?.displayName
            ?? shortcut.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
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
