import SwiftUI
import DoubaoVoiceHelperCore

struct RootSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.onboardingPhase == .done {
            SettingsView()
        } else {
            OnboardingView()
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("豆包语音助手")
                .font(.title2.weight(.semibold))
            content
            Spacer()
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            model.refreshPermissions()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.onboardingPhase {
        case .intro:
            intro
        case .permissions:
            permissions
        case .confirm(let role):
            confirm(role)
        case .optionsPlus(let role):
            optionsPlus(role)
        case .loginItem:
            loginItem
        case .done:
            EmptyView()
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("本 App 不录音，也不做语音识别。")
            Text("它只把三颗鼠标键映射到豆包：前进键切换语音，左键长按按住说话，后退键发送回车。")
            Text("非浏览器里，后退键会直接发送。浏览器、Finder 里前进后退仍是系统导航。")
                .foregroundStyle(.secondary)
            Button("继续") {
                model.advanceOnboarding()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("需要辅助功能权限才能监听鼠标并发送快捷键。")
            Text("前进/后退键还需要输入监控权限。")
                .foregroundStyle(.secondary)
            PermissionRow(
                title: "辅助功能",
                granted: model.permissionSnapshot.accessibilityTrusted,
                required: true,
                action: model.requestAccessibilityPermission,
                settingsAction: model.openAccessibilitySettings
            )
            PermissionRow(
                title: "输入监控",
                granted: model.permissionSnapshot.inputMonitoringAuthorized,
                required: model.requiresInputMonitoringForConfiguredButtons,
                action: model.requestInputMonitoringPermission,
                settingsAction: model.openInputMonitoringSettings
            )
            HStack {
                Button("我已授权，继续") {
                    model.refreshPermissions()
                    model.advanceOnboarding()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func confirm(_ role: MouseBindingRole) -> some View {
        let binding = model.mouseBinding(for: role)
        return VStack(alignment: .leading, spacing: 12) {
            Text("确认\(role.displayName)")
                .font(.headline)
            Text("请按下 \(binding.displayName)（button \(binding.button)）。")
            if let heard = model.lastHeardButton {
                Text("收到 button \(heard)")
                    .font(.title3.monospaced())
            } else {
                Text("等待按键…")
                    .foregroundStyle(.secondary)
            }
            if role == .hold {
                Text("点一下左键即可，不必长按。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("暂时跳过") {
                model.skipOnboardingConfirm(for: role)
            }
        }
    }

    private func optionsPlus(_ role: MouseBindingRole) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("没有收到\(role.displayName)键")
                .font(.headline)
            Text(
                "Logitech Options+ 常会在驱动层吃掉前进/后退键。请在 Options+ 里把该键设为 Disabled（或「无」），然后重启 Options+ agent，再回到这里按一次。"
            )
            HStack {
                Button("再试一次") {
                    model.retryOnboardingConfirm(for: role)
                }
                Button("跳过，稍后再说") {
                    model.skipOnboardingConfirm(for: role)
                }
            }
        }
    }

    private var loginItem: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("登录时启动？")
                .font(.headline)
            Text("建议开启，这样开机后三颗键就能用。")
                .foregroundStyle(.secondary)
            HStack {
                Button("开启并完成") {
                    model.completeOnboarding(enableLoginItem: true)
                }
                .keyboardShortcut(.defaultAction)
                Button("暂不开启") {
                    model.completeOnboarding(enableLoginItem: false)
                }
            }
        }
    }
}
