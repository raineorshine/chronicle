import SwiftUI

@main
struct ChronicleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}
