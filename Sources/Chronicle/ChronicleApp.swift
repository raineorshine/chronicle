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
            Button("Toggle Sidebar") { store.toggleSidebar() }
                .keyboardShortcut("\\", modifiers: .command)
            // Second binding for the same action; a button takes one shortcut.
            Button("Toggle Sidebar (⌘B)") { store.toggleSidebar() }
                .keyboardShortcut("b", modifiers: .command)

            Divider()

            Button("All Tasks") { store.selectHome() }
                .keyboardShortcut("1", modifiers: .command)
            // Second binding for the same action; a button takes one shortcut.
            Button("All Tasks (Home)") { store.selectHome() }
                .keyboardShortcut("h", modifiers: [.command, .shift])

            Divider()

            Button("Previous Activity") { store.navigateSibling(-1) }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button("Next Activity") { store.navigateSibling(1) }
                .keyboardShortcut(.rightArrow, modifiers: .command)

            Divider()

            // Cmd+(N+1) selects the Nth activity, so Cmd+2 -> activity 1 ... Cmd+9 -> activity 8.
            ForEach(1...8, id: \.self) { n in
                Button("Activity \(n)") { store.selectActivity(n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n + 1)")), modifiers: .command)
            }
        }
    }
}
