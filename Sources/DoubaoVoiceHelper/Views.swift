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
            Label(model.statusTitle, systemImage: model.status.symbolName)
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
    @State private var previewInput = "斜杠批准"

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
                Text("本 App 不录音，只控制豆包并处理本次听写文本。")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }

            Section("输入") {
                HStack {
                    Text("额外鼠标键")
                    Spacer()
                    TextField(
                        "button",
                        text: Binding(
                            get: { String(model.settings.mouseBinding.button) },
                            set: {
                                if let value = Int64($0) {
                                    model.setMouseButton(value)
                                }
                            }
                        )
                    )
                    .frame(width: 70)
                    Button("捕获") {
                        model.beginMouseButtonCapture()
                    }
                }

                HStack {
                    Text("豆包快捷键")
                    ShortcutRecorder(
                        shortcut: Binding(
                            get: { model.settings.doubaoShortcut },
                            set: { model.setShortcut($0) }
                        )
                    )
                    Button("测试") {
                        model.testShortcut()
                    }
                }
            }

            Section("语音宏") {
                ForEach(
                    Array(model.settings.macroRules.enumerated()),
                    id: \.element.id
                ) { index, rule in
                    HStack {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: {
                                    model.settings.macroRules[index].isEnabled
                                },
                                set: { newValue in
                                    model.updateMacroRule(at: index) {
                                        $0.isEnabled = newValue
                                    }
                                }
                            )
                        )
                        .labelsHidden()

                        TextField(
                            "识别文本",
                            text: Binding(
                                get: {
                                    model.settings.macroRules[index].source
                                },
                                set: { newValue in
                                    model.updateMacroRule(at: index) {
                                        $0.source = newValue
                                    }
                                }
                            )
                        )
                        Text("→")
                        TextField(
                            "输出文本",
                            text: Binding(
                                get: {
                                    model.settings.macroRules[index].replacement
                                },
                                set: { newValue in
                                    model.updateMacroRule(at: index) {
                                        $0.replacement = newValue
                                    }
                                }
                            )
                        )
                        Button(role: .destructive) {
                            model.removeMacroRule(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Button("添加语音宏") {
                    model.addMacroRule()
                }

                HStack {
                    TextField("预览输入", text: $previewInput)
                    Text("→")
                    Text(model.preview(previewInput).output)
                        .textSelection(.enabled)
                        .frame(minWidth: 120, alignment: .leading)
                }
                .padding(.top, 4)
            }

            Section("排除应用") {
                Text("排除列表中的应用会完整透传额外鼠标键。")
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
                    action: model.requestAccessibilityPermission,
                    settingsAction: model.openAccessibilitySettings
                )
                PermissionRow(
                    title: "输入监控",
                    granted: model.permissionSnapshot.inputMonitoringAuthorized,
                    action: model.requestInputMonitoringPermission,
                    settingsAction: model.openInputMonitoringSettings
                )
                Text(
                    "辅助功能权限用于监听额外鼠标键、发送快捷键和安全访问支持的文本控件。"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("首版兼容范围") {
                ForEach(TargetCompatibility.minimumMatrix) { target in
                    HStack {
                        Text(target.name)
                        Spacer()
                        Text("待实机验证")
                            .foregroundStyle(.secondary)
                    }
                }
                Text(
                    "无法证明文本范围时只触发豆包，保留原文，不使用退格、撤销或剪贴板回退。"
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

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void
    let settingsAction: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            Text(granted ? "已授权" : "未授权")
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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.shortcut = shortcut
        view.onShortcut = { value in
            context.coordinator.parent.shortcut = value
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.shortcut = shortcut
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

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        shortcut = AppKeyboardShortcut(
            keyCode: event.keyCode,
            modifiers: modifiers(from: event.modifierFlags)
        )
        onShortcut?(shortcut)
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        guard let modifier = modifier(forKeyCode: event.keyCode),
              isActive(modifier, in: event.modifierFlags)
        else {
            return
        }

        shortcut = AppKeyboardShortcut(
            keyCode: event.keyCode,
            modifiers: [modifier]
        )
        onShortcut?(shortcut)
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

    private func modifier(forKeyCode keyCode: UInt16) -> KeyboardModifier? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return nil
        }
    }

    private func isActive(
        _ modifier: KeyboardModifier,
        in flags: NSEvent.ModifierFlags
    ) -> Bool {
        switch modifier {
        case .command: return flags.contains(.command)
        case .option: return flags.contains(.option)
        case .control: return flags.contains(.control)
        case .shift: return flags.contains(.shift)
        case .function: return flags.contains(.function)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).stroke()

        let text = shortcut.displayName
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
