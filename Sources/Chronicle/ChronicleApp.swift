import SwiftUI

@main
struct ChronicleApp: App {
    @StateObject private var store = DashboardStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
        .commands {
            NavigationCommands(store: store)
        }
    }
}

/// Menu-bar commands for keyboard-driven sidebar navigation.
private struct NavigationCommands: Commands {
    @ObservedObject var store: DashboardStore

    var body: some Commands {
        CommandMenu("Navigate") {
            Button("All Tasks") { store.selectHome() }
                .keyboardShortcut("0", modifiers: .command)
            // Second binding for the same action; a button takes one shortcut.
            Button("All Tasks (Home)") { store.selectHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])

            Divider()

            Button("Previous Activity") { store.navigateSibling(-1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Next Activity") { store.navigateSibling(1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)

            Divider()

            ForEach(1...9, id: \.self) { n in
                Button("Activity \(n)") { store.selectActivity(n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }
    }
}
