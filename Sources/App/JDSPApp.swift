import Engine
import SwiftUI

@main
struct JDSPApp: App {
    @State private var controller = EngineController()

    var body: some Scene {
        MenuBarExtra {
            PanelView(controller: controller)
        } label: {
            Image(nsImage: MenuBarIcon.image(controller.iconState))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(controller: controller)
        }
    }
}
