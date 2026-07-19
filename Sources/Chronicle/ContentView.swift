import SwiftUI
import AppKit
import Charts
import ChronicleCore

struct ContentView: View {
    @StateObject private var store = DashboardStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            HierarchySidebar(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            DashboardDetail(store: store)
        }
        .onAppear { store.load() }
        .onChange(of: scenePhase) { _, phase in
            // Re-check when returning to the app (e.g. after granting access in
            // System Settings) so the picker refreshes without a restart.
            if phase == .active { store.refreshCalendarAccessState() }
        }
    }
}

// MARK: - Sidebar

private struct HierarchySidebar: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        List {
            SelectableRow(title: "All Tasks",
                          isSelected: store.selectedNodeID == "all",
                          systemImage: "square.grid.2x2") {
                store.select(.all, nodeID: "all")
            }

            ForEach(store.taskList) { task in
                TaskRow(store: store, task: task)
            }
        }
        .listStyle(.sidebar)
    }
}

/// One task in the flat, hours-sorted list. Expands to its merged subtasks when
/// it has any; otherwise it's a single selectable row.
private struct TaskRow: View {
    @ObservedObject var store: DashboardStore
    let task: TaskSummary

    private var nodeID: String { "task:\(task.key)" }

    var body: some View {
        Group {
            if task.subtasks.isEmpty {
                taskRow
            } else {
                DisclosureGroup {
                    ForEach(task.subtasks) { sub in
                        let subID = "sub:\(task.key):\(sub.key)"
                        SelectableRow(title: sub.label,
                                      isSelected: store.selectedNodeID == subID,
                                      systemImage: "circle.fill",
                                      indent: 1,
                                      detail: Self.hours(sub.hours)) {
                            store.select(HierarchySelection(taskKey: task.key,
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
                      systemImage: "list.bullet",
                      detail: Self.hours(task.hours)) {
            store.select(HierarchySelection(taskKey: task.key), nodeID: nodeID)
        }
    }

    private static func hours(_ h: Double) -> String {
        String(format: "%.1fh", h)
    }
}

private struct SelectableRow: View {
    let title: String
    let isSelected: Bool
    let systemImage: String
    var indent: Int = 0
    var detail: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
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
            WindowControls(store: store)
            if let message = store.errorMessage {
                errorBanner(message)
            }
            WeeklyChartCard(store: store)
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if store.selectedNodeID != "all" {
                        Button {
                            store.drillUp()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(.borderless)
                        .help("Back to the broader view")
                    }
                    Text(selectionTitle).font(.title2).bold()
                }
                Text(store.isTaskLevel ? "Hours per activity by week"
                                       : "Subtask breakdown by week")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            LatestWeekMetric(store: store)
        }
    }

    private var selectionTitle: String {
        store.selectedNodeID == "all" ? "All Tasks" : store.currentTitle
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
            if store.calendarAccessDenied {
                Text("Calendar access is turned off for Chronicle. Enable it in "
                     + "System Settings › Privacy & Security › Calendars, then "
                     + "return here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    store.openCalendarSettings()
                }
            } else {
                Text("Chronicle needs access to your calendars to list them here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Grant Calendar Access") {
                    store.requestCalendarAccess()
                }
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

/// The latest week's hours plus a colored delta chip versus the prior week.
private struct LatestWeekMetric: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        let latest = store.latestWeek
        VStack(alignment: .trailing, spacing: 2) {
            Text(String(format: "%.1f", latest.hours))
                .font(.title).monospacedDigit().bold()
            HStack(spacing: 6) {
                Text("This week").font(.caption).foregroundStyle(.secondary)
                if let delta = latest.delta, abs(delta) >= 0.05 {
                    let up = delta > 0
                    Text("\(up ? "▲" : "▼") \(String(format: "%.1f", abs(delta)))h")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(up ? Color.green : Color.red)
                        .help("Change versus the previous week")
                }
            }
        }
    }
}

private struct WindowControls: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        HStack(spacing: 12) {
            Picker("Weeks", selection: Binding(
                get: { store.weeksWindow },
                set: { store.setWeeksWindow($0) }
            )) {
                ForEach(store.allowedWeekWindows, id: \.self) { n in
                    Text("\(n) wks").tag(n)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Text("\(store.dateBounds.from) → \(store.dateBounds.to)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Weekly stacked chart

private struct WeeklyChartCard: View {
    @ObservedObject var store: DashboardStore
    @State private var hovered: DashboardStore.HoveredSegment?
    @State private var hoverPoint: CGPoint = .zero

    var body: some View {
        Group {
            if store.stacks.points.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    chart
                    SegmentLegend(store: store)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var chart: some View {
        Chart(store.stacks.points) { point in
            BarMark(
                x: .value("Week", point.weekStart),
                y: .value("Hours", point.hours)
            )
            .foregroundStyle(by: .value("Activity", store.displayLabel(forSegment: point.segmentKey)))
            .opacity(1.0)
        }
        .chartForegroundStyleScale(domain: store.styleDomain, range: store.styleRange)
        .chartXScale(domain: store.windowWeekStarts)
        .chartXAxis {
            AxisMarks(values: store.windowWeekStarts) { value in
                if let week = value.as(String.self) {
                    AxisValueLabel {
                        Text(store.weekLabelShort(week))
                            + Text(week == store.currentWeekStart ? " •" : "")
                    }
                }
            }
        }
        .chartYAxisLabel("Hours")
        .chartLegend(.hidden)
        .frame(minHeight: 300)
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plotAnchor = proxy.plotFrame else { return }
                                let plot = geo[plotAnchor]
                                let x = location.x - plot.origin.x
                                let y = location.y - plot.origin.y
                                if let week: String = proxy.value(atX: x),
                                   let hours: Double = proxy.value(atY: y),
                                   let seg = store.segment(inWeek: week, atHours: hours) {
                                    hovered = seg
                                    hoverPoint = location
                                } else {
                                    hovered = nil
                                }
                            case .ended:
                                hovered = nil
                            }
                        }
                    if let seg = hovered {
                        tooltip(for: seg)
                            .fixedSize()
                            .offset(x: min(max(hoverPoint.x - 70, 0), geo.size.width - 150),
                                    y: min(max(hoverPoint.y - 44, 0), geo.size.height - 44))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func tooltip(for seg: DashboardStore.HoveredSegment) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(seg.color)
                .frame(width: 9, height: 9)
            Text(seg.label).font(.caption2).lineLimit(1)
            Spacer(minLength: 12)
            Text(String(format: "%.1fh", seg.hours))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: 220)
        .fixedSize(horizontal: true, vertical: false)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .shadow(radius: 6, y: 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis").font(.largeTitle).foregroundStyle(.secondary)
            Text("No data for this selection.").foregroundStyle(.secondary)
            Text("Run Refresh to extract from Calendar.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

/// A tappable legend. At the activity level, clicking a segment drills into its
/// subtasks; "Other" and the subtask level are non-interactive.
private struct SegmentLegend: View {
    @ObservedObject var store: DashboardStore

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(store.segmentStyles) { style in
                let drillable = store.isTaskLevel && style.key != WeeklyBucketing.otherKey
                Button {
                    store.drillInto(segmentKey: style.key)
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(style.color)
                            .frame(width: 11, height: 11)
                        Text(style.displayLabel).font(.caption).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!drillable)
                .help(drillable ? "Break \(style.displayLabel) down by subtask" : "")
            }
        }
    }
}
