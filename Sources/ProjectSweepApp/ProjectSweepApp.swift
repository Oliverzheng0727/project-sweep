import AppKit
import SwiftUI

@main
struct ProjectSweepApp: App {
    @StateObject private var state = SweepState()
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup("项目清理") {
            SweepView(state: state)
                .frame(minWidth: 960, minHeight: 680)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1140, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("选择项目总目录…") { state.chooseLibrary() }.keyboardShortcut("o")
                    .disabled(state.executing)
                Button("直接打开单个项目…") { state.chooseProject() }.keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(state.executing)
            }
        }
    }
}
