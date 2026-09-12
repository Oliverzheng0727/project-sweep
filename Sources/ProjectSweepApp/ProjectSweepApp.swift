import AppKit
import CleanupCore
import SwiftUI

@main
struct ProjectSweepApp: App {
    @StateObject private var state = SweepState()
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("language") private var language = AppLanguagePreference.system.rawValue
    private var languagePreference: AppLanguagePreference {
        AppLanguagePreference(rawValue: language) ?? .system
    }
    var body: some Scene {
        WindowGroup(AppText.string("项目清理")) {
            SweepView(state: state)
                .id(languagePreference.id)
                .frame(minWidth: 960, minHeight: 680)
                .environment(\.locale, languagePreference.locale)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    applyLanguageToAppKit()
                }
                .onChange(of: language) { applyLanguageToAppKit() }
        }
        .defaultSize(width: 1140, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(AppText.string("选择项目总目录…")) { state.chooseLibrary() }.keyboardShortcut("o")
                    .disabled(state.executing)
                Button(AppText.string("直接打开单个项目…")) { state.chooseProject() }.keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(state.executing)
            }
        }
    }

    private func applyLanguageToAppKit() {
        let title = AppText.string("项目清理")
        DispatchQueue.main.async {
            NSApp.mainWindow?.title = title
            NSApp.mainMenu?.items.first?.title = title
        }
    }
}
