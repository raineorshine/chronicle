import SwiftUI
import AppKit
import Charts
import ChronicleCore

struct ContentView: View {
    @ObservedObject var store: DashboardStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView(columnVisibility: $store.columnVisibility) {
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
                                      detail: Self.hours(sub.hours),
                                      isHighlighted: store.isHighlighted(sub.key),
                                      onHoverChanged: { hovering in
                                          if hovering {
                                              store.setHighlight(sub.key)
                                          } else if store.highlightedSegmentKey == sub.key {
                                              store.setHighlight(nil)
                                          }
                                      }) {
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TaskColorSwatch(store: store, taskKey: task.key, taskName: task.label)
                Button {
                    store.select(HierarchySelection(taskKey: task.key), nodeID: nodeID)
                } label: {
                    HStack(spacing: 6) {
                        Text(task.label)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Self.hours(task.hours))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HoursShareBar(fraction: shareFraction,
                          color: store.taskColor(forKey: task.key))
        }
        .rowHighlight(active: store.isHighlighted(task.key)
                      && store.selectedNodeID != nodeID)
        .onHover { hovering in
            if hovering {
                store.setHighlight(task.key)
            } else if store.highlightedSegmentKey == task.key {
                store.setHighlight(nil)
            }
        }
        .listRowBackground(RowHoverBackground(isSelected: store.selectedNodeID == nodeID))
    }

    /// This task's share of the week's total recorded hours (0...1).
    private var shareFraction: Double {
        let total = store.weeklyHoursTotal
        guard total > 0 else { return 0 }
        return min(1, max(0, task.hours / total))
    }

    private static func hours(_ h: Double) -> String {
        String(format: "%.1fh", h)
    }
}

/// A thin horizontal bar showing a task's share of the week's total recorded
/// hours. The faint track spans the full width; the tinted fill spans `fraction`.
private struct HoursShareBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel("Share of weekly hours")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

/// A grid of curated palette swatches. Selecting one assigns it as the task's
/// color override; the currently-effective color is marked with a ring + check.
private struct PalettePicker: View {
    @ObservedObject var store: DashboardStore
    let taskKey: String
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.fixed(22), spacing: 8), count: 6)

    var body: some View {
        let current = store.taskColor(forKey: taskKey)
        VStack(alignment: .leading, spacing: 8) {
            Text("Task Color")
                .font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(DashboardStore.palette.enumerated()), id: \.offset) { _, swatch in
                    let isSelected = swatch.hexString == current.hexString
                    Button {
                        store.setTaskColor(taskKey, swatch)
                        dismiss()
                    } label: {
                        Circle()
                            .fill(swatch)
                            .frame(width: 20, height: 20)
                            .overlay(
                                Circle().strokeBorder(Color.primary.opacity(isSelected ? 0.9 : 0.15),
                                                      lineWidth: isSelected ? 2 : 1)
                            )
                            .overlay(
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .opacity(isSelected ? 1 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(isSelected ? "Current color" : "Set this color")
                }
            }
            Divider()
            Button("Reset to Auto Color") {
                store.setTaskColor(taskKey, nil)
                dismiss()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .disabled(store.taskColors[taskKey] == nil)
        }
        .padding(12)
        .frame(width: 196)
    }
}

/// A compact color swatch for a task. Clicking opens a curated palette picker;
/// right-clicking offers a reset to the task's stable auto-color.
private struct TaskColorSwatch: View {
    @ObservedObject var store: DashboardStore
    let taskKey: String
    let taskName: String
    var size: CGFloat = 14
    @State private var showingPicker = false

    var body: some View {
        Button {
            showingPicker = true
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(store.taskColor(forKey: taskKey))
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Set this task's color")
        .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
            PalettePicker(store: store, taskKey: taskKey)
        }
        .contextMenu {
            Button("Copy task name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(taskName, forType: .string)
            }
            Button("Reset to Auto Color") { store.setTaskColor(taskKey, nil) }
                .disabled(store.taskColors[taskKey] == nil)
        }
    }
}

private struct SelectableRow: View {
    let title: String
    let isSelected: Bool
    let systemImage: String
    var indent: Int = 0
    var detail: String? = nil
    var isHighlighted: Bool = false
    /// When provided, the row participates in the shared cross-surface highlight
    /// (keyed) and its tint is driven solely by `isHighlighted`. When nil, the row
    /// is non-cross-lit (e.g. "All Tasks") and falls back to its own local hover.
    var onHoverChanged: ((Bool) -> Void)? = nil
    let action: () -> Void

    @State private var isHovering = false

    private var showsTint: Bool {
        onHoverChanged == nil ? isHovering : isHighlighted
    }

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
        .rowHighlight(active: showsTint && !isSelected)
        .onHover { hovering in
            isHovering = hovering
            onHoverChanged?(hovering)
        }
        .listRowBackground(RowHoverBackground(isSelected: isSelected))
    }
}

/// Inner highlight background for a sidebar row. Applied as part of the row's own
/// content (not `listRowBackground`), so it repaints in lockstep with the row
/// body. `listRowBackground` on an AppKit-backed `List` repaints lazily on cell
/// reuse, which left a just-exited row's tint on screen for up to ~1s while the
/// next row lit up - looking like two highlighted rows at once. Drawing the tint
/// here updates deterministically, so exactly one row is ever tinted.
private struct RowHighlight: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.primary.opacity(0.08) : Color.clear)
            )
            .padding(.horizontal, -6)
            .padding(.vertical, -3)
    }
}

private extension View {
    func rowHighlight(active: Bool) -> some View {
        modifier(RowHighlight(active: active))
    }
}

/// Full-bleed list-row background for the selection accent only. Hover/highlight
/// tint is drawn by `RowHighlight` inside the row content instead, because
/// `listRowBackground` repaints lazily on cell reuse and would otherwise leave a
/// stale tint on a just-exited row.
private struct RowHoverBackground: View {
    let isSelected: Bool

    var body: some View {
        (isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
    }
}

// MARK: - Detail

private struct DashboardDetail: View {
    @ObservedObject var store: DashboardStore
    @State private var isShowingReplaceSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let message = store.errorMessage {
                errorBanner(message)
            }
            WeeklyChartCard(store: store)
                .frame(maxHeight: .infinity)
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460, maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                TaskSearchButton(store: store)
            }
            ToolbarItem(placement: .primaryAction) {
                CalendarPickerButton(store: store)
            }
            ToolbarItem(placement: .primaryAction) {
                AliasPickerButton(store: store)
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
                .help("Reload calendar data")
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: showsBackButton ? 8 : 0) {
                    Button {
                        store.drillUp()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Back to the broader view")
                    .opacity(showsBackButton ? 1 : 0)
                    .frame(width: showsBackButton ? nil : 0)
                    .disabled(!showsBackButton)
                    .accessibilityHidden(!showsBackButton)
                    Text(selectionTitle).font(.title2).bold()
                    if let scope = replaceableScope {
                        Button {
                            isShowingReplaceSheet = true
                        } label: {
                            Label("Replace…", systemImage: "arrow.left.arrow.right")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .disabled(store.isReplacing || store.isRefreshing)
                        .help("Replace this title on every future event, from today onward")
                        .sheet(isPresented: $isShowingReplaceSheet) {
                            ReplaceTaskSheet(store: store,
                                             taskKey: scope.taskKey,
                                             subtaskKey: scope.subtaskKey,
                                             currentTitle: store.currentEventTitle)
                        }
                    }
                }
                Text(store.isTaskLevel ? "Hours per activity by week"
                                       : "Subtask breakdown by week")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            WindowControls(store: store)
        }
    }

    private var showsBackButton: Bool {
        store.selectedNodeID != "all"
    }

    /// The task (and optionally subtask) whose page is showing, or nil at the
    /// "All Tasks" scope, which spans too many distinct titles to replace.
    /// A subtask scope replaces only that subtask's events.
    private var replaceableScope: (taskKey: String, subtaskKey: String?)? {
        guard let taskKey = store.selection.taskKey else { return nil }
        return (taskKey, store.selection.subtaskKey)
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

// MARK: - Replace recurring task

/// Confirmation for replacing a recurring task. Unlike aliases, this rewrites
/// titles on the user's real calendar events and cannot be undone, so the action
/// is gated behind an explicit step that spells out its scope first.
private struct ReplaceTaskSheet: View {
    @ObservedObject var store: DashboardStore
    let taskKey: String
    /// When set, only this subtask's events are replaced.
    let subtaskKey: String?
    let currentTitle: String
    @Environment(\.dismiss) private var dismiss
    @State private var newTitle = ""

    private var canReplace: Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != currentTitle
    }

    /// Spells out the blast radius, which differs by scope: a task sweeps in its
    /// subtasked events too, while a subtask touches only its own.
    private var scopeExplanation: String {
        let quoted = "\u{201C}\(currentTitle)\u{201D}"
        let scope = subtaskKey == nil
            ? "every future event under \(quoted), including its subtasks,"
            : "every future event titled \(quoted)"
        return "Replaces the title of \(scope) from today onward in your calendar. "
            + "Past events are unchanged. This cannot be undone."
    }

    private func replace() {
        guard canReplace else { return }
        store.replaceRecurringTask(taskKey: taskKey,
                                   subtaskKey: subtaskKey,
                                   newTitle: newTitle)
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(subtaskKey == nil ? "Replace Recurring Task"
                                   : "Replace Recurring Subtask")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("New title").font(.caption).foregroundStyle(.secondary)
                TextField("New title", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(replace)
            }

            Text(scopeExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Replace", action: replace)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canReplace)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { newTitle = currentTitle }
    }
}

// MARK: - Task search

private struct TaskSearchButton: View {
    @ObservedObject var store: DashboardStore
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Search", systemImage: "magnifyingglass")
        }
        .help("Search activities by name (⌘F)")
        .keyboardShortcut("f", modifiers: .command)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TaskSearchPopover(store: store, isPresented: $isPresented)
        }
    }
}

/// Live autosuggest over the window's activities and their subtasks. ↑/↓ move
/// the highlight and Enter (or a click) selects, landing on exactly the scope
/// the matching sidebar row would.
private struct TaskSearchPopover: View {
    @ObservedObject var store: DashboardStore
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    /// Matches for the typed query, or the busiest activities when nothing is
    /// typed yet, so the popover always opens onto something selectable.
    private var results: [TaskSearchResult] {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? TaskSearch.topActivities(in: store.taskList)
            : TaskSearch.match(query, in: store.taskList)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search activities", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { commit() }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.escape) { isPresented = false; return .handled }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider()

            if results.isEmpty {
                hint("No matches.")
                Spacer(minLength: 0)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                row(result, index: index)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .onChange(of: highlighted) { _, index in
                        guard results.indices.contains(index) else { return }
                        proxy.scrollTo(results[index].id)
                    }
                }
            }
        }
        // A fixed height, rather than one that hugs the results: an AppKit
        // popover sizes its window from the content it is presented with and
        // does not grow afterwards, so a list that appears as you type would be
        // clipped to the height of the empty state.
        .frame(width: 320, height: 300)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func row(_ result: TaskSearchResult, index: Int) -> some View {
        Button {
            commit(index)
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(store.taskColor(forKey: result.taskKey))
                    .frame(width: 11, height: 11)
                Text(result.displayLabel)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(String(format: "%.1fh", result.hours))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(index == highlighted ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .id(result.id)
        .onHover { hovering in
            if hovering { highlighted = index }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    /// Moves the highlight, clamped to the ends of the list. Always `.handled`
    /// so the arrow keys never fall through to the text field's own cursor
    /// movement.
    private func move(_ offset: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        highlighted = min(max(highlighted + offset, 0), results.count - 1)
        return .handled
    }

    private func commit(_ index: Int? = nil) {
        let target = index ?? highlighted
        guard results.indices.contains(target) else { return }
        let result = results[target]
        store.select(HierarchySelection(taskKey: result.taskKey,
                                        subtaskKey: result.subtaskKey),
                     nodeID: result.id)
        query = ""
        isPresented = false
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
        .help("Choose which calendars to include")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            CalendarPicker(store: store)
        }
    }
}

// MARK: - Rename aliases

private struct AliasPickerButton: View {
    @ObservedObject var store: DashboardStore
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("Aliases", systemImage: "arrow.triangle.merge")
        }
        .help("Merge renamed tasks together")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AliasPicker(store: store)
        }
    }
}

/// Manages rename chains: each links titles that are renames of the same task
/// so they merge across all metrics. Adding `old → new` extends the matching
/// chain (or starts one), so a task renamed repeatedly grows a single chain.
private struct AliasPicker: View {
    @ObservedObject var store: DashboardStore
    @State private var oldTitle = ""
    @State private var newTitle = ""

    private var canAdd: Bool {
        !oldTitle.trimmingCharacters(in: .whitespaces).isEmpty
            && !newTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func add() {
        guard canAdd else { return }
        store.addRename(from: oldTitle, to: newTitle)
        oldTitle = ""
        newTitle = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Aliases").font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            if store.aliasChains.isEmpty {
                Text("No aliases yet.")
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(store.aliasChains.enumerated()), id: \.offset) { index, chain in
                            AliasChainRow(chain: chain) { store.removeAliasChain(at: index) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 260)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                TextField("Old title", text: $oldTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                HStack(spacing: 6) {
                    TextField("New title", text: $newTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(!canAdd)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Text("Links titles that are renames of the same task so they merge "
                 + "across all metrics. Adding a rename whose old title matches "
                 + "an existing chain's newest title extends that chain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        .frame(width: 320)
    }
}

private struct AliasChainRow: View {
    let chain: [String]
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(chain.joined(separator: "  →  "))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove this alias")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
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
                        ForEach(store.sortedAvailableCalendars) { cal in
                            CalendarPickerRow(store: store, calendar: cal)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 360)

                Divider()
                Text("Selected calendars are included in your metrics. The "
                     + "columns icon toggles whether a calendar shows as one "
                     + "whole-calendar segment or breaks out into individual "
                     + "tasks. The minus icon marks a calendar subtractive — its "
                     + "time is removed from overlapping events in other calendars.")
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
    private var isWholeSegment: Bool { store.isCalendarWholeSegment(calendar) }
    private var isIncluded: Bool { store.isCalendarSelected(calendar) }

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
                store.setCalendarSegmentMode(calendar, wholeCalendar: !isWholeSegment)
            } label: {
                Image(systemName: isWholeSegment ? "rectangle.stack.fill" : "rectangle.split.3x1")
                    .foregroundStyle(isWholeSegment ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!isIncluded)
            .help(isWholeSegment
                  ? "Whole calendar: this calendar shows as one segment. Click to "
                    + "break it out into individual task segments."
                  : "Segment by task (default): this calendar's tasks each show as "
                    + "their own segment. Click to collapse it into one segment.")

            Button {
                store.setSubtractive(calendar, subtractive: !isSubtractive)
            } label: {
                Image(systemName: isSubtractive ? "minus.circle.fill" : "minus.circle")
                    .foregroundStyle(isSubtractive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .toolTip(isSubtractive
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

    /// Serializes to an `#RRGGBB` string in sRGB; nil if it can't be converted.
    var hexString: String? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((srgb.redComponent * 255).rounded())
        let g = Int((srgb.greenComponent * 255).rounded())
        let b = Int((srgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

/// A transparent AppKit view that shows its `toolTip` on hover but never
/// intercepts mouse events. Returning `nil` from `hitTest(_:)` lets clicks pass
/// through to the control beneath, while the window's tooltip-rect tracking
/// (which does not rely on `hitTest`) still displays the tooltip.
private final class PassthroughToolTipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Attaches an AppKit tooltip that displays on hover. Unlike SwiftUI's
/// `.help(_:)`, `NSView.toolTip` renders reliably inside popovers.
private struct ToolTipView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughToolTipView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

extension View {
    /// A hover tooltip that works inside popovers, where `.help(_:)` does not.
    func toolTip(_ text: String) -> some View {
        overlay(ToolTipView(text: text))
    }
}

private struct WindowControls: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            Text(store.dateBoundsShort)
                .font(.caption).foregroundStyle(.secondary)

            WeeksPopUpButton(
                options: store.allowedWeekWindows,
                selection: store.weeksWindow,
                onSelect: { store.setWeeksWindow($0) }
            )
            .fixedSize()
        }
    }
}

/// A menu-style weeks picker backed by `NSPopUpButton` so we can disable the
/// AppKit focus ring. A SwiftUI `Picker` (even with `.focusEffectDisabled()`)
/// still draws the accent focus ring whenever the window becomes key, which
/// makes the control look permanently selected. Setting `focusRingType = .none`
/// on the underlying button is the only reliable way to suppress it.
private struct WeeksPopUpButton: NSViewRepresentable {
    let options: [Int]
    let selection: Int
    let onSelect: (Int) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.focusRingType = .none
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.options = options

        let titles = options.map { "\($0) wks" }
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let index = options.firstIndex(of: selection) {
            button.selectItem(at: index)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(options: options, onSelect: onSelect)
    }

    final class Coordinator: NSObject {
        var options: [Int]
        var onSelect: (Int) -> Void

        init(options: [Int], onSelect: @escaping (Int) -> Void) {
            self.options = options
            self.onSelect = onSelect
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard options.indices.contains(index) else { return }
            onSelect(options[index])
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
                    ScrollView {
                        SegmentLegend(store: store)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var chart: some View {
        Chart(store.chartPoints) { point in
            if store.chartStyle == .area {
                AreaMark(
                    x: .value("Week", store.weekDate(point.weekStart)),
                    y: .value("Hours", point.hours)
                )
                .foregroundStyle(by: .value("Activity", store.displayLabel(forSegment: point.segmentKey)))
                .interpolationMethod(.linear)
                .opacity(store.chartOpacity(forSegment: point.segmentKey))
            } else {
                BarMark(
                    x: .value("Week", store.weekDate(point.weekStart)),
                    y: .value("Hours", point.hours)
                )
                .foregroundStyle(by: .value("Activity", store.displayLabel(forSegment: point.segmentKey)))
                .opacity(store.chartOpacity(forSegment: point.segmentKey))
            }
        }
        .chartForegroundStyleScale(domain: store.styleDomain, range: store.styleRange)
        .chartXScale(domain: store.windowDateDomain)
        .chartXAxis {
            AxisMarks(values: store.windowWeekDates) { value in
                if let date = value.as(Date.self) {
                    AxisValueLabel(anchor: axisLabelAnchor(for: date)) {
                        Text(store.weekLabelShort(date: date))
                    }
                }
            }
        }
        .chartYAxisLabel("Hours")
        .chartLegend(.hidden)
        .frame(height: 300)
        .animation(.easeInOut(duration: 0.15), value: store.highlightedSegmentKey)
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
                                if let date: Date = proxy.value(atX: x),
                                   let week = store.nearestWeek(to: date),
                                   let hours: Double = proxy.value(atY: y),
                                   let seg = store.segment(inWeek: week, atHours: hours) {
                                    hovered = seg
                                    hoverPoint = location
                                    store.setHighlight(seg.key)
                                } else {
                                    hovered = nil
                                    store.setHighlight(nil)
                                }
                            case .ended:
                                hovered = nil
                                store.setHighlight(nil)
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

    /// Because the X scale is continuous with its domain pinned to the first and
    /// last week, those points sit flush against the plot edges. Anchor their
    /// labels inward (leading / trailing) so they extend into the plot instead of
    /// clipping off the sides; interior labels stay centered on their tick.
    private func axisLabelAnchor(for date: Date) -> UnitPoint {
        if date == store.windowWeekDates.first { return .topLeading }
        if date == store.windowWeekDates.last { return .topTrailing }
        return .top
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

/// A tappable legend. At the activity level, clicking a task segment drills
/// into its subtasks; whole-calendar segments and the subtask level are
/// non-interactive.
private struct SegmentLegend: View {
    @ObservedObject var store: DashboardStore

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)]

    var body: some View {
        let weekHours = store.metricsWeekHoursBySegment
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(store.segmentStyles) { style in
                let isCalendarBucket = WeeklyBucketing.isCalendarBucketKey(style.key)
                let isTask = store.isTaskLevel
                    && style.key != WeeklyBucketing.otherKey
                    && !isCalendarBucket
                let drillable = isTask
                HStack(spacing: 6) {
                    if isTask {
                        TaskColorSwatch(store: store, taskKey: style.key, taskName: style.displayLabel, size: 11)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(style.color)
                            .frame(width: 11, height: 11)
                    }
                    Button {
                        store.drillInto(segmentKey: style.key)
                    } label: {
                        HStack(spacing: 6) {
                            Text(style.displayLabel).font(.caption).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(String(format: "%.1fh", weekHours[style.key] ?? 0))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!drillable)
                    .help(drillable ? "Break \(style.displayLabel) down by subtask"
                          : isCalendarBucket ? "\(style.displayLabel) (whole calendar)" : "")
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(store.isHighlighted(style.key) ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
                .onHover { hovering in
                    if hovering {
                        store.setHighlight(style.key)
                    } else if store.highlightedSegmentKey == style.key {
                        store.setHighlight(nil)
                    }
                }
            }
        }
    }
}
