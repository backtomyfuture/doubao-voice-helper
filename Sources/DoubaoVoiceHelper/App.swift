import AppKit
import SwiftUI

@main
@MainActor
struct DoubaoVoiceHelperApp: App {
    @StateObject private var model: AppModel
    private let settingsWindowController: SettingsWindowController

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = AppModel()
        let settingsWindowController = SettingsWindowController(model: model)
        _model = StateObject(wrappedValue: model)
        self.settingsWindowController = settingsWindowController
        // Login-item launches stay silent unless the user has to act.
        if model.needsAttentionOnLaunch {
            DispatchQueue.main.async {
                settingsWindowController.show()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView {
                settingsWindowController.show()
            }
                .environmentObject(model)
        } label: {
            Label {
                Text("豆包语音助手")
            } icon: {
                MenuBarIcon(
                    imageName: model.status.menuBarIconName,
                    fallbackSystemName: model.status.symbolName
                )
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
