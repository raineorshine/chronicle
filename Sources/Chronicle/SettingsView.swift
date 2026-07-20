import SwiftUI

/// The app's native Settings window (opened via the Chronicle menu, ⌘, or the
/// toolbar gear). Currently exposes the weekly chart's visual style.
struct SettingsView: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        Form {
            Picker("Weekly chart", selection: $store.chartStyle) {
                ForEach(DashboardStore.ChartStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .navigationTitle("Settings")
    }
}
