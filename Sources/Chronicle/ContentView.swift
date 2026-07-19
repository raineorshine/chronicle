import SwiftUI
import AppKit
import Charts
import ChronicleCore

struct ContentView: View {
    @StateObject private var store = DashboardStore()

    var body: some View {
        NavigationSplitView {
            HierarchySidebar(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            DashboardDetail(store: store)
        }
        .onAppear { store.load() }
    }
}

// MARK: - Sidebar

private struct HierarchySidebar: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        List {
            SelectableRow(title: "All Calendars",
                          isSelected: store.selectedNodeID == "all",
                          systemImage: "square.grid.2x2") {
                store.select(.all, nodeID: "all")
            }

            ForEach(store.calendars) { cal in
                CalendarDisclosure(store: store, calendar: cal)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct CalendarDisclosure: View {
    @ObservedObject var store: DashboardStore
    let calendar: CalendarNode

    var body: some View {
        DisclosureGroup {
            ForEach(calendar.tasks) { task in
                TaskDisclosure(store: store, calendarKey: calendar.key, task: task)
            }
        } label: {
            SelectableRow(title: calendar.label,
                          isSelected: store.selectedNodeID == "cal:\(calendar.key)",
                          systemImage: "calendar") {
                store.select(HierarchySelection(calendarKey: calendar.key),
                             nodeID: "cal:\(calendar.key)")
            }
        }
    }
}

private struct TaskDisclosure: View {
    @ObservedObject var store: DashboardStore
    let calendarKey: String
    let task: TaskNode

    private var nodeID: String { "task:\(calendarKey):\(task.key)" }

    var body: some View {
        Group {
            if task.subtasks.isEmpty {
                taskRow
            } else {
                DisclosureGroup {
                    ForEach(task.subtasks) { sub in
                        let subID = "sub:\(calendarKey):\(task.key):\(sub.key)"
                        SelectableRow(title: sub.label,
                                      isSelected: store.selectedNodeID == subID,
                                      systemImage: "circle.fill",
                                      indent: 1) {
                            store.select(HierarchySelection(calendarKey: calendarKey,
                                                            taskKey: task.key,
                                                            subtaskKey: sub.key),
                                         nodeID: subID)
                        }
                    }
                } label: { taskRow }
            }
        }
    }

    private var taskRow: some View {
        SelectableRow(title: task.label,
                      isSelected: store.selectedNodeID == nodeID,
                      systemImage: "list.bullet") {
            store.select(HierarchySelection(calendarKey: calendarKey, taskKey: task.key),
                         nodeID: nodeID)
        }
    }
}

private struct SelectableRow: View {
    let title: String
    let isSelected: Bool
    let systemImage: String
    var indent: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(indent) * 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}

// MARK: - Detail

private struct DashboardDetail: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            RangeControls(store: store)
            if let message = store.errorMessage {
                errorBanner(message)
            }
            ChartCard(store: store)
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                CalendarPickerButton(store: store)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refresh()
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshing)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectionTitle).font(.title2).bold()
                Text("\(store.dateBounds.from) → \(store.dateBounds.to)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 24) {
                Metric(value: String(format: "%.1f", store.totals.totalHours), label: "Hours")
                Metric(value: "\(store.totals.occurrences)", label: "Occurrences")
            }
        }
    }

    private var selectionTitle: String {
        store.selectedNodeID == "all" ? "All Calendars" : store.currentTitle
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Copy error message")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CalendarPickerButton: View {
    @ObservedObject var store: DashboardStore
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
            store.loadCalendars()
        } label: {
            Label("Calendars", systemImage: "calendar")
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            CalendarPicker(store: store)
        }
    }
}

private struct CalendarPicker: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Calendars").font(.headline)
                Spacer()
                if store.isLoadingCalendars {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if !store.hasCalendarAccess && store.availableCalendars.isEmpty {
                accessRequestView
            } else if store.availableCalendars.isEmpty {
                Text("No calendars found.")
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.availableCalendars) { cal in
                            CalendarPickerRow(store: store, calendar: cal)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 360)

                Divider()
                Text("Selected calendars are included in your metrics. The "
                     + "minus icon marks a calendar subtractive — its time is "
                     + "removed from overlapping events in other calendars.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 300)
    }

    private var accessRequestView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Chronicle needs access to your calendars to list them here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Grant Calendar Access") {
                store.loadCalendars()
            }
        }
        .padding(14)
    }
}

private struct CalendarPickerRow: View {
    @ObservedObject var store: DashboardStore
    let calendar: CalendarInfo

    private var isSubtractive: Bool { store.isCalendarSubtractive(calendar) }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { store.isCalendarSelected(calendar) },
                set: { store.setCalendar(calendar, included: $0) }
            )) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(hex: calendar.colorHex) ?? .secondary)
                        .frame(width: 12, height: 12)
                    Text(calendar.title)
                        .lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 4)

            Button {
                store.setSubtractive(calendar, subtractive: !isSubtractive)
            } label: {
                Image(systemName: isSubtractive ? "minus.circle.fill" : "minus.circle")
                    .foregroundStyle(isSubtractive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(isSubtractive
                  ? "Subtractive: this calendar's time is removed from overlapping "
                    + "events in other calendars. Click to turn off."
                  : "Mark subtractive: remove this calendar's time from overlapping "
                    + "events in other calendars (also includes it).")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }
}

extension Color {
    /// Builds a color from an `#RRGGBB` string; returns nil if unparseable.
    init?(hex: String?) {
        guard var hex else { return nil }
        hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}


private struct Metric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).font(.title).monospacedDigit().bold()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct RangeControls: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        HStack(spacing: 12) {
            Picker("Range", selection: Binding(
                get: { store.preset },
                set: { store.preset = $0; store.reloadData() }
            )) {
                ForEach(RangePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            if store.preset == .custom {
                DatePicker("", selection: Binding(
                    get: { store.customFrom },
                    set: { store.customFrom = $0; store.reloadData() }
                ), displayedComponents: .date)
                .labelsHidden()
                Text("to").foregroundStyle(.secondary)
                DatePicker("", selection: Binding(
                    get: { store.customTo },
                    set: { store.customTo = $0; store.reloadData() }
                ), displayedComponents: .date)
                .labelsHidden()
            }
            Spacer()
        }
    }
}

private struct ChartCard: View {
    @ObservedObject var store: DashboardStore

    private var series: [CalendarDailyPoint] { store.calendarSeries }

    /// Distinct calendars present in the current view, ordered by label, each
    /// paired with its resolved color (falls back to gray when unknown).
    private var calendarsInView: [(label: String, color: Color)] {
        var color: [String: Color] = [:]
        var order: [String] = []
        for point in series where color[point.calendarLabel] == nil {
            color[point.calendarLabel] = Color(hex: point.colorHex) ?? .secondary
            order.append(point.calendarLabel)
        }
        return order.map { ($0, color[$0]!) }
    }

    var body: some View {
        Group {
            if series.isEmpty || series.allSatisfy({ $0.hours == 0 }) {
                emptyState
            } else {
                chart
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var chart: some View {
        let calendars = calendarsInView
        let bounds = store.dateBounds
        return Chart(series) { point in
            BarMark(
                x: .value("Day", chartDate(point.date)),
                y: .value("Hours", point.hours)
            )
            .foregroundStyle(by: .value("Calendar", point.calendarLabel))
        }
        .chartForegroundStyleScale(
            domain: calendars.map(\.label),
            range: calendars.map(\.color)
        )
        .chartXScale(domain: chartDate(bounds.from)...chartDate(bounds.to))
        .chartYAxisLabel("Hours")
        .chartLegend(calendars.count > 1 ? .visible : .hidden)
        .frame(minHeight: 280)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.secondary)
            Text("No data for this selection.").foregroundStyle(.secondary)
            Text("Run Refresh to extract from Calendar.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private func chartDate(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s) ?? Date()
    }
}
