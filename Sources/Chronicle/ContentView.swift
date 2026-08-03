import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers
import ChronicleCore

/// Replace the pasteboard contents with `string`.
private func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}

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
        // One sheet for every surface that can start a rename, so a row doesn't
        // have to own presentation state that dies with it when the list reloads.
        .sheet(item: $store.renameTarget) { target in
            RenameTaskSheet(store: store, target: target)
        }
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
            .contextMenu {
                TaskMenuItems(store: store, openTarget: .all, displayName: "All Tasks")
            }

            ForEach(store.taskList) { task in
                TaskRow(store: store, task: task)
            }
        }
        .listStyle(.sidebar)
    }
}

/// The one right-click menu for a task or subtask, shown identically wherever
/// one appears: sidebar rows, the detail header, the summary lists, and chart
/// slices. Items that don't apply to a target are disabled rather than
/// dropped, so the menu keeps the same shape everywhere.
private struct TaskMenuItems: View {
    @ObservedObject var store: DashboardStore
    /// The page "Open" navigates to; nil when the target is an aggregate with
    /// no page of its own, or the page already showing (the detail header).
    var openTarget: HierarchySelection? = nil
    /// The task (and optionally subtask) identity for rename/categorize/color;
    /// nil for aggregates ("All Tasks", "Other", whole-calendar buckets).
    var taskKey: String? = nil
    var subtaskKey: String? = nil
    /// The target's visible name, which "Copy task name" copies verbatim.
    let displayName: String

    /// Color overrides are a task-level attribute, so the color items act only
    /// on a task target — not on subtasks or aggregates.
    private var colorKey: String? {
        subtaskKey == nil ? taskKey : nil
    }

    var body: some View {
        Button("Open") {
            if let openTarget { store.open(openTarget) }
        }
        .disabled(openTarget == nil)
        Button("Copy task name") { copyToPasteboard(displayName) }
        Divider()
        Button(subtaskKey == nil ? "Rename task…" : "Rename subtask…") {
            if let taskKey {
                store.beginRename(taskKey: taskKey, subtaskKey: subtaskKey)
            }
        }
        .disabled(taskKey == nil || store.isRenaming || store.isRefreshing)
        CategorizeMenu(store: store, taskKey: taskKey, subtaskKey: subtaskKey)
        Divider()
        ColorMenu(store: store, taskKey: colorKey)
        Button("Reset to Auto Color") {
            if let colorKey { store.setTaskColor(colorKey, nil) }
        }
        .disabled(colorKey.flatMap { store.taskColors[$0] } == nil)
    }
}

/// Submenu naming each palette color, with the effective choice checked the
/// same way the swatch picker rings it. Disabled for targets whose color can't
/// be overridden (subtasks and aggregates).
private struct ColorMenu: View {
    @ObservedObject var store: DashboardStore
    /// The task whose override the menu edits; nil disables the submenu.
    let taskKey: String?

    var body: some View {
        Menu("Color") {
            if let taskKey {
                let currentHex = store.taskColor(forKey: taskKey).hexString
                choice("Automatic", isCurrent: store.taskColors[taskKey] == nil) {
                    store.setTaskColor(taskKey, nil)
                }
                Divider()
                ForEach(DashboardStore.palette) { swatch in
                    choice(swatch.name,
                           isCurrent: swatch.color.hexString == currentHex) {
                        store.setTaskColor(taskKey, swatch.color)
                    }
                }
            }
        }
        .disabled(taskKey == nil)
    }

    /// A menu entry that reads as a radio choice: checked when current, and
    /// selecting the current one again is a no-op rather than an un-check.
    private func choice(_ name: String,
                        isCurrent: Bool,
                        select: @escaping () -> Void) -> some View {
        Toggle(name, isOn: Binding(get: { isCurrent },
                                   set: { if $0 { select() } }))
    }
}

/// The shared task menu for a chart segment key (a slice or a summary row),
/// resolved to its task/subtask identity in the current scope. Aggregate
/// segments have no identity, which leaves only "Copy task name" enabled.
private struct SegmentMenuItems: View {
    @ObservedObject var store: DashboardStore
    let segmentKey: String

    var body: some View {
        let identity = store.identity(forSegment: segmentKey)
        TaskMenuItems(store: store,
                      openTarget: identity.map {
                          HierarchySelection(taskKey: $0.taskKey,
                                             subtaskKey: $0.subtaskKey)
                      },
                      taskKey: identity?.taskKey,
                      subtaskKey: identity?.subtaskKey,
                      displayName: store.displayLabel(forSegment: segmentKey))
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
                DisclosureGroup(isExpanded: store.expansionBinding(forTaskKey: task.key)) {
                    ForEach(task.subtasks) { sub in
                        let subID = "sub:\(task.key):\(sub.key)"
                        SelectableRow(title: sub.label,
                                      isSelected: store.selectedNodeID == subID,
                                      systemImage: "circle.fill",
                                      indent: 1,
                                      detail: Self.hours(sub.hours),
                                      isRecurring: store.isRecurring(taskKey: task.key,
                                                                     subtaskKey: sub.key),
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
                        .contextMenu {
                            TaskMenuItems(store: store,
                                          openTarget: HierarchySelection(taskKey: task.key,
                                                                         subtaskKey: sub.key),
                                          taskKey: task.key,
                                          subtaskKey: sub.key,
                                          displayName: sub.label)
                        }
                    }
                } label: { taskRow }
            }
        }
    }

    private var taskRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TaskColorSwatch(store: store, taskKey: task.key)
                Button {
                    store.select(HierarchySelection(taskKey: task.key), nodeID: nodeID)
                } label: {
                    HStack(spacing: 6) {
                        Text(task.label)
                            .lineLimit(1)
                        if store.isRecurring(taskKey: task.key) {
                            RecurringMarker()
                        }
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
        .contentShape(Rectangle())
        .contextMenu {
            TaskMenuItems(store: store,
                          openTarget: HierarchySelection(taskKey: task.key),
                          taskKey: task.key,
                          displayName: task.label)
        }
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

/// Submenu of the activities a sidebar row can be filed under. Picking one
/// rewrites the row's future events so the chosen activity becomes their task
/// and the row keeps its own name as the subtask: `Faiz` filed under `em`
/// becomes `em - Faiz`, `Health - Dr. Brown` filed under `Wellbeing` becomes
/// `Wellbeing - Dr. Brown`.
private struct CategorizeMenu: View {
    @ObservedObject var store: DashboardStore
    /// Nil for aggregates that can't be refiled, which disables the submenu.
    let taskKey: String?
    /// Set on a subtask row, so only that subtask's events are refiled.
    let subtaskKey: String?

    /// The activities that already act as categories — the ones with subtasks,
    /// i.e. that head a `Task - Subtask` title. A standalone activity like
    /// `Bavel` is a leaf, not a heading, so filing something under it would
    /// invent a category the user never chose. The row's own activity stays in
    /// the list so it reads the same from every row; picking it does nothing.
    ///
    /// Alphabetical: this is a lookup by name, unlike the sidebar itself, which
    /// ranks by hours. Sorting is on the comparison key, not the label, so a
    /// leading emoji doesn't decide where a name lands.
    private var categories: [TaskSummary] {
        store.taskList
            .filter { !$0.subtasks.isEmpty }
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    var body: some View {
        Menu("Categorize") {
            ForEach(categories) { category in
                Button(category.label) {
                    if let taskKey {
                        store.categorize(taskKey: taskKey,
                                         subtaskKey: subtaskKey,
                                         categoryLabel: category.label)
                    }
                }
            }
        }
        .disabled(taskKey == nil || categories.isEmpty
                  || store.isReplacing || store.isRefreshing)
    }
}

/// Marks a sidebar task that still has a recurring event scheduled ahead of it.
/// Uses the same glyph Apple Calendar puts on a repeating event, so it reads as
/// "this repeats" rather than as an action.
private struct RecurringMarker: View {
    var body: some View {
        Image(systemName: "repeat")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .help("Recurs in the future")
            .accessibilityLabel("Recurring")
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
                ForEach(DashboardStore.palette) { swatch in
                    let isSelected = swatch.color.hexString == current.hexString
                    Button {
                        store.setTaskColor(taskKey, swatch.color)
                        dismiss()
                    } label: {
                        Circle()
                            .fill(swatch.color)
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
                    .help(isSelected ? "\(swatch.name) (current)" : swatch.name)
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
/// right-clicking falls through to the enclosing row's task menu.
private struct TaskColorSwatch: View {
    @ObservedObject var store: DashboardStore
    let taskKey: String
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
    }
}

private struct SelectableRow: View {
    let title: String
    let isSelected: Bool
    let systemImage: String
    var indent: Int = 0
    var detail: String? = nil
    var isRecurring: Bool = false
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
                if isRecurring {
                    RecurringMarker()
                }
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
            SummaryCard(store: store)
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
                    // The spinner overlays the icon rather than replacing it so
                    // the item keeps its size and the toolbar does not re-layout
                    // while refreshing.
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .opacity(store.isRefreshing ? 0 : 1)
                        .overlay {
                            if store.isRefreshing {
                                ProgressView().controlSize(.small)
                            }
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
                        .contentShape(Rectangle())
                        .contextMenu {
                            // No openTarget: this page is already showing.
                            TaskMenuItems(store: store,
                                          taskKey: store.selection.taskKey,
                                          subtaskKey: store.selection.subtaskKey,
                                          displayName: selectionTitle)
                        }
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
            SchedulePreviewView(preview: store.schedulePreview,
                                color: store.taskColor(forKey: store.selection.taskKey ?? ""))
                .padding(.leading, 14)
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
        // A known-empty count means there is nothing to rewrite. An unknown one
        // (still counting, or the count failed) must not block the action.
        return !trimmed.isEmpty && trimmed != currentTitle
            && store.replacementPreview?.totalReplaced != 0
    }

    /// Spells out the blast radius, which differs by scope: a task sweeps in its
    /// subtasked events too, while a subtask touches only its own. Once the count
    /// arrives it replaces the vaguer wording with the number of events at stake,
    /// where a recurring series counts once rather than once per occurrence.
    private var scopeExplanation: String {
        guard let preview = store.replacementPreview else {
            let quoted = "\u{201C}\(currentTitle)\u{201D}"
            let scope = subtaskKey == nil
                ? "every future event under \(quoted), including its subtasks,"
                : "every future event titled \(quoted)"
            return "Replaces the title of \(scope) from today onward in your calendar. "
                + "Past events are unchanged. This cannot be undone."
        }
        guard preview.totalReplaced > 0 else {
            return "No future events match this selection."
        }
        let events = preview.totalReplaced == 1 ? "1 event" : "\(preview.totalReplaced) events"
        return "Replaces \(events) from today onward in your calendar. "
            + "Past events are unchanged. This cannot be undone."
    }

    /// Matching events Chronicle cannot rewrite, e.g. on a subscribed calendar.
    private var readOnlyNote: String? {
        guard let skipped = store.replacementPreview?.skippedReadOnly, skipped > 0 else { return nil }
        return skipped == 1
            ? "1 more is on a read-only calendar and will be skipped."
            : "\(skipped) more are on a read-only calendar and will be skipped."
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

            VStack(alignment: .leading, spacing: 4) {
                Text(scopeExplanation)
                if let readOnlyNote {
                    Text(readOnlyNote)
                }
            }
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
        .onAppear {
            newTitle = currentTitle
            store.loadReplacementPreview(taskKey: taskKey, subtaskKey: subtaskKey)
        }
    }
}

// MARK: - Rename a task

/// Confirmation for renaming a task outright. Sits between the app's two other
/// rename-shaped tools: an alias only merges titles at read time and leaves the
/// calendar alone, while a replacement rewrites from today onward and splits a
/// recurring series there, deliberately leaving history under the old name. This
/// renames the events themselves, past ones included, and keeps a recurring
/// series whole — so the activity simply carries its new name throughout.
///
/// Like a replacement it cannot be undone, so it is gated behind an explicit
/// step that spells out its scope first.
private struct RenameTaskSheet: View {
    @ObservedObject var store: DashboardStore
    let target: RenameTarget
    @Environment(\.dismiss) private var dismiss
    @State private var newTitle = ""

    /// Height held for the explanation from the moment the sheet opens, so the
    /// count fading in doesn't resize the sheet under the pointer.
    ///
    /// Two lines of caption text (14.4pt each at this sheet's 340pt text width),
    /// which is what all but the wordiest breakdown comes to. A longer sentence,
    /// or a read-only note underneath, grows the sheet — worth it to keep the
    /// reserved space from dwarfing the common case.
    private static let explanationHeight: CGFloat = 29

    private var canRename: Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
        // A known-empty count means there is nothing to rewrite. An unknown one
        // (still counting, or the count unavailable) must not block the action —
        // unlike missing access, which would make the rename fail outright.
        if store.renamePreviewState == .needsCalendarAccess { return false }
        return !trimmed.isEmpty && trimmed != target.currentTitle
            && store.renamePreviewState.summary?.totalRenamed != 0
    }

    /// Spells out the blast radius in calendar events rather than occurrences —
    /// a weekly series is "1 weekly event", however many times it has repeated.
    ///
    /// Nil while the count is still being taken, which renders as blank space of
    /// the same height: stating the scope in vaguer words first and swapping it
    /// for the count reads as the scope changing, not as the count arriving.
    private var scopeExplanation: String? {
        switch store.renamePreviewState {
        case .counting:
            return nil
        case .needsCalendarAccess:
            return "\(RenameError.accessDenied)"
        case .unavailable:
            // The count didn't come, but the action is still on offer, so it
            // has to be described — in the widest terms that stay true.
            let quoted = "\u{201C}\(target.currentTitle)\u{201D}"
            let scope = target.subtaskKey == nil
                ? "every event under \(quoted), including its subtasks,"
                : "every event titled \(quoted),"
            return "Renames \(scope) past and future. This cannot be undone."
        case .counted(let preview):
            guard preview.totalRenamed > 0 else {
                return "No events match this selection."
            }
            return "Renames \(preview.eventPhrase), past and future. "
                + "This cannot be undone."
        }
    }

    /// Matching events Chronicle cannot rewrite, e.g. on a subscribed calendar.
    private var readOnlyNote: String? {
        guard let skipped = store.renamePreviewState.summary?.skippedReadOnly,
              skipped > 0 else { return nil }
        return skipped == 1
            ? "1 more is on a read-only calendar and will be skipped."
            : "\(skipped) more are on a read-only calendar and will be skipped."
    }

    private func rename() {
        guard canRename else { return }
        store.renameTask(taskKey: target.taskKey,
                         subtaskKey: target.subtaskKey,
                         newTitle: newTitle)
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.subtaskKey == nil ? "Rename Task" : "Rename Subtask")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("New title").font(.caption).foregroundStyle(.secondary)
                TextField("New title", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(rename)
            }

            // Both layers are always rendered, so the space is held from the
            // first frame: the spinner crossfades into the count rather than
            // the count pushing the buttons down as it arrives.
            ZStack(alignment: .topLeading) {
                // The spinner clears promptly once the count is in; only the
                // count itself takes its time arriving.
                ProgressView()
                    // Circular explicitly: the default indeterminate style can
                    // come out as a bar that stretches the full width, which
                    // has no leading edge to align to.
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .opacity(scopeExplanation == nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.15), value: scopeExplanation)

                VStack(alignment: .leading, spacing: 4) {
                    Text(scopeExplanation ?? "")
                    if let readOnlyNote {
                        Text(readOnlyNote)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .opacity(scopeExplanation == nil ? 0 : 1)
                .animation(.easeIn(duration: 0.5), value: scopeExplanation)
            }
            .frame(maxWidth: .infinity,
                   minHeight: Self.explanationHeight,
                   alignment: .topLeading)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            newTitle = target.currentTitle
            store.loadRenamePreview(taskKey: target.taskKey, subtaskKey: target.subtaskKey)
        }
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
                    CalendarPickerRows(store: store)
                        .padding(.vertical, 6)
                }
                .frame(maxHeight: 360)

                Divider()
                Text("Selected calendars are included in your metrics, in "
                     + "priority order — drag the handle to reorder. When events "
                     + "overlap, the higher calendar counts in full and the "
                     + "overlap is removed from the lower one. The columns icon "
                     + "toggles whether a calendar shows as one whole-calendar "
                     + "segment or breaks out into individual tasks.")
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

/// The picker's calendar list: the selected ones first, in priority order and
/// draggable to reorder, then everything else.
private struct CalendarPickerRows: View {
    @ObservedObject var store: DashboardStore

    /// Where a hovering drag would insert, drawn as an insertion line.
    @StateObject private var indicator = DropIndicator()

    /// Measured height of one row, so a drop can tell "above this row" from
    /// "below it". Every row is the same height, so one measurement covers all.
    @State private var rowHeight: CGFloat = 24

    /// Gap between rows. Part of the slot arithmetic, so the drop target can
    /// cover it rather than leaving it a dead strip between two rows.
    private static let rowSpacing: CGFloat = 2

    var body: some View {
        let selected = store.selectedCalendars
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(Array(selected.enumerated()), id: \.element.id) { index, cal in
                CalendarPickerRow(store: store, calendar: cal) {
                    NSItemProvider(object: cal.id as NSString)
                }
                .measureRowHeight(into: $rowHeight)
                .overlay(alignment: .top) { insertionLine(at: index) }
                .overlay(alignment: .bottom) {
                    // Only the last row can host the trailing slot; every other
                    // one is already some row's leading slot.
                    if index == selected.count - 1 {
                        insertionLine(at: selected.count)
                    }
                }
            }
            ForEach(store.unselectedCalendars) { cal in
                CalendarPickerRow(store: store, calendar: cal, onDrag: nil)
            }
        }
        // One target for the whole list rather than one per row: the spacing
        // between rows belongs to no row, so per-row targets left dead strips
        // where the indicator vanished and a drop was silently rejected.
        .onDrop(of: [.text], delegate: CalendarListDropDelegate(
            slotCount: selected.count,
            rowHeight: rowHeight,
            rowSpacing: Self.rowSpacing,
            indicator: indicator,
            onDrop: moveCalendar(withID:to:)))
    }

    /// The bar marking where a dropped calendar would land, drawn only for the
    /// slot the pointer is currently over.
    @ViewBuilder
    private func insertionLine(at slot: Int) -> some View {
        if indicator.slot == slot {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .padding(.horizontal, 10)
        }
    }

    /// Applies a completed drop. The dragged item carries a calendar identifier;
    /// anything else (a stray text drag from another app) matches nothing and is
    /// ignored.
    private func moveCalendar(withID id: String, to slot: Int) {
        guard let dragged = store.selectedCalendars.first(where: { $0.id == id }) else { return }
        store.moveCalendar(dragged, to: slot)
    }
}

private struct CalendarPickerRow: View {
    @ObservedObject var store: DashboardStore
    let calendar: CalendarInfo
    /// Supplies the drag payload for selected calendars, which can be reordered.
    /// Nil for unselected ones, which have no place in the priority order.
    var onDrag: (() -> NSItemProvider)?

    private var isWholeSegment: Bool { store.isCalendarWholeSegment(calendar) }
    private var isIncluded: Bool { store.isCalendarSelected(calendar) }

    var body: some View {
        HStack(spacing: 8) {
            dragHandle

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }

    /// The reorder grip, or — for unselected calendars — an equal-width gap that
    /// keeps every row's checkbox on the same vertical line.
    @ViewBuilder
    private var dragHandle: some View {
        if let onDrag {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .frame(width: 11)
                .onDrag(onDrag) {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: calendar.colorHex) ?? .secondary)
                            .frame(width: 12, height: 12)
                        Text(calendar.title).lineLimit(1)
                    }
                    .padding(6)
                }
                .toolTip("Drag to reorder priority. When events overlap, the "
                         + "calendar higher in the list counts in full and the "
                         + "overlap is removed from the one below it.")
        } else {
            Color.clear.frame(width: 11, height: 1)
        }
    }
}

/// Drag-to-reorder over the whole calendar list: maps the pointer to the slot a
/// drop would insert into and commits the move there.
private struct CalendarListDropDelegate: DropDelegate {
    /// Number of draggable (selected) rows; slots run `0...slotCount`.
    let slotCount: Int
    let rowHeight: CGFloat
    let rowSpacing: CGFloat
    let indicator: DropIndicator
    let onDrop: (String, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        indicator.update(to: slot(for: info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        indicator.update(to: slot(for: info))
        // `.copy`, not `.move`: nothing is removed from a source here, and the
        // move operation asks the drag session for semantics a plain string
        // payload can't honor.
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        indicator.clear()
    }

    func performDrop(info: DropInfo) -> Bool {
        let target = slot(for: info)
        indicator.clear()
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        // The payload loads asynchronously, so the move hops back to the main
        // actor before touching the store.
        provider.loadObject(ofClass: NSString.self) { identifier, _ in
            guard let identifier = identifier as? String else { return }
            DispatchQueue.main.async { onDrop(identifier, target) }
        }
        return true
    }

    /// The slot the pointer is in: one past every row whose midpoint it has
    /// passed. Because this measures against midpoints rather than row bounds,
    /// every y maps to a slot — the gaps between rows included — and dragging
    /// past the last selected row parks the drop at the end of the order.
    private func slot(for info: DropInfo) -> Int {
        let stride = rowHeight + rowSpacing
        guard slotCount > 0, stride > 0 else { return 0 }
        let passed = ((info.location.y - rowHeight / 2) / stride).rounded(.down)
        return min(max(Int(passed) + 1, 0), slotCount)
    }
}

/// Where a drag would drop a calendar, held for the insertion indicator.
///
/// A reference type rather than `@State` on purpose. As `@State`, the value
/// cleared in `performDrop` came back a few hundred milliseconds later — once
/// the re-extraction that the reorder kicked off published and SwiftUI re-ran
/// the list from a stale snapshot — stranding the indicator at the drop point
/// until the next drag. Nothing wrote that value; it was restored.
///
/// The mouse button is treated as the end-of-drag signal for the same reason of
/// trust: SwiftUI delivered `dropExited` twice across 27 instrumented drags, so
/// a drag that leaves the list without dropping cannot rely on it either. No
/// drag is in flight once the button is up.
@MainActor
final class DropIndicator: ObservableObject {
    @Published private(set) var slot: Int?

    /// Runs only while the indicator is showing, to notice the button coming up.
    /// The drag-ending mouse-up never reaches an event monitor — AppKit consumes
    /// it — so polling is the only way to see the drag finish.
    private var poll: Timer?

    private var isDragging: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    /// Points the indicator at `slot`. An update arriving with the button
    /// already up belongs to a drag that has ended, and retires it instead.
    func update(to slot: Int?) {
        guard isDragging else { return clear() }
        if self.slot != slot { self.slot = slot }
        guard poll == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if !self.isDragging { self.clear() }
            }
        }
        // `.common`, so it keeps ticking while AppKit is tracking the drag.
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    func clear() {
        if slot != nil { slot = nil }
        poll?.invalidate()
        poll = nil
    }
}

private extension View {
    /// Publishes this view's rendered height, for callers that need to reason
    /// about where inside it a pointer landed.
    func measureRowHeight(into height: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { height.wrappedValue = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, new in height.wrappedValue = new }
            }
        )
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

// MARK: - Summary

/// The headline numbers for the current scope, above the chart: what took the
/// most time across the charted window, and what moved most from the previous
/// week into the metrics week (the same week the sidebar tallies).
///
/// Both lists are ranked off the very stacks the chart draws, so the summary can
/// never disagree with the picture beneath it. Nothing is drawn when there is
/// nothing to summarize, leaving the chart's own empty state to speak.
private struct SummaryCard: View {
    @ObservedObject var store: DashboardStore

    var body: some View {
        let top = store.topSegments
        let movers = store.topMovers
        if top.isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 24) {
                column(store.isTaskLevel ? "Top tasks" : "Top subtasks",
                       help: "Total hours over the \(store.weeksWindow) weeks charted below") {
                    ForEach(top) { entry in
                        row(segmentKey: entry.segmentKey) {
                            Text(Self.hours(entry.hours))
                        }
                    }
                }
                column("Top movers", help: "Change from \(store.moverComparisonDescription)") {
                    if movers.isEmpty {
                        Text("No change from the previous week.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                    } else {
                        ForEach(movers) { mover in
                            row(segmentKey: mover.segmentKey) {
                                HStack(spacing: 5) {
                                    Text(Self.change(mover))
                                    // The percentage hangs off the right in a
                                    // column of its own, so the before/after
                                    // values still line up on a mover that rose
                                    // out of zero and has no percentage to show.
                                    Text(Self.percent(mover) ?? "")
                                        .foregroundStyle(Self.percentColor(mover))
                                        .lineLimit(1)
                                        .frame(width: Self.percentColumnWidth,
                                               alignment: .leading)
                                }
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func column<Content: View>(_ title: String,
                                       help: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption).bold()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
                .help(help)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One list row: the segment's chart color and name on the left, its numbers
    /// on the right. Hovering cross-lights the same segment in the chart and the
    /// sidebar, the way every other surface does.
    private func row<Trailing: View>(segmentKey key: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .fill(store.color(forSegment: key))
                .frame(width: 11, height: 11)
            Text(store.displayLabel(forSegment: key))
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(store.isHighlighted(key) ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .contextMenu {
            SegmentMenuItems(store: store, segmentKey: key)
        }
        .onHover { hovering in
            if hovering {
                store.setHighlight(key)
            } else if store.highlightedSegmentKey == key {
                store.setHighlight(nil)
            }
        }
    }

    /// Hours to one decimal, dropping a zero tenth so a round number reads as
    /// "10" rather than "10.0".
    private static func hoursValue(_ hours: Double) -> String {
        let rounded = (hours * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(format: "%.0f", rounded)
                                            : String(format: "%.1f", rounded)
    }

    private static func hours(_ hours: Double) -> String {
        "\(hoursValue(hours)) hrs"
    }

    /// A mover's before and after, e.g. "10 → 12 hrs" — only the destination
    /// carries the unit, since both sides share it.
    private static func change(_ mover: MoverEntry) -> String {
        "\(hoursValue(mover.previousHours)) → \(hours(mover.currentHours))"
    }

    /// The change as a percentage, e.g. "+20%". Nil for a segment that rose out
    /// of zero: it moved, but not by any finite percentage.
    private static func percent(_ mover: MoverEntry) -> String? {
        guard let change = mover.percentChange else { return nil }
        let magnitude = String(format: "%.0f", abs(change))
        return "\(change < 0 ? "−" : "+")\(magnitude)%"
    }

    /// Green for more time, red for less. Uses the system colors rather than the
    /// task palette so the direction reads as a signal, not as an identity, and
    /// still adapts to the viewer's appearance and accessibility settings.
    private static func percentColor(_ mover: MoverEntry) -> Color {
        mover.delta < 0 ? .red : .green
    }

    /// Reserved width of the hanging percentage column, sized to hold a
    /// five-character change ("+220%") at caption size.
    private static let percentColumnWidth: CGFloat = 42
}

// MARK: - Weekly stacked chart

private struct WeeklyChartCard: View {
    @ObservedObject var store: DashboardStore
    @State private var hovered: DashboardStore.HoveredSegment?
    @State private var hoverPoint: CGPoint = .zero
    @State private var tooltipSize: CGSize = .zero
    /// The slice the context menu describes. Unlike `hovered`, this survives
    /// the hover-ended event AppKit sends when the menu opens (the pointer
    /// "leaves" the view), so the menu doesn't lose its target. It refreshes on
    /// every hover move, so it always names the slice that was right-clicked.
    @State private var menuSegmentKey: String?

    var body: some View {
        Group {
            if store.stacks.points.isEmpty {
                emptyState
            } else {
                chart
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var chart: some View {
        GeometryReader { geo in
            chartBody(width: geo.size.width)
        }
        .frame(minHeight: 300, maxHeight: .infinity)
    }

    private func chartBody(width: CGFloat) -> some View {
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
            if store.usesMonthAxis {
                AxisMarks(values: store.monthBoundaryDates) { _ in
                    AxisGridLine()
                }
                AxisMarks(values: store.monthLabelDates) { value in
                    if let date = value.as(Date.self) {
                        AxisValueLabel(anchor: .topLeading) {
                            Text(store.monthLabel(date: date))
                                .font(Self.axisLabelTextStyle)
                                .padding(.leading, 4)
                        }
                    }
                }
            } else {
                AxisMarks(values: labeledWeekDates(chartWidth: width)) { value in
                    if let date = value.as(Date.self) {
                        AxisValueLabel(anchor: axisLabelAnchor(for: date)) {
                            Text(store.weekLabelRange(date: date))
                                .font(Self.axisLabelTextStyle)
                        }
                    }
                }
            }
        }
        .chartYAxisLabel("Hours")
        .chartLegend(.hidden)
        .animation(.easeInOut(duration: 0.15), value: store.highlightedSegmentKey)
        .chartOverlay { proxy in
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                if let seg = segment(at: location, proxy: proxy, geo: geo) {
                                    hovered = seg
                                    hoverPoint = location
                                    store.setHighlight(seg.key)
                                } else {
                                    hovered = nil
                                    store.setHighlight(nil)
                                }
                                menuSegmentKey = hovered?.key
                                updateCursor(for: hovered)
                            case .ended:
                                hovered = nil
                                store.setHighlight(nil)
                                NSCursor.arrow.set()
                            }
                        }
                        .onTapGesture { location in
                            guard let seg = segment(at: location, proxy: proxy, geo: geo),
                                  store.hasDetailPage(forSegment: seg.key) else { return }
                            // The new scope re-stacks the chart under the
                            // stationary cursor, so the old segment's tooltip and
                            // highlight no longer describe what's beneath it.
                            hovered = nil
                            store.setHighlight(nil)
                            store.openDetail(segmentKey: seg.key)
                        }
                        .contextMenu {
                            // Right-clicking empty plot area (no tracked slice)
                            // builds an empty menu, which AppKit doesn't show.
                            if let key = menuSegmentKey {
                                SegmentMenuItems(store: store, segmentKey: key)
                            }
                        }
                    if let seg = hovered {
                        tooltip(for: seg)
                            .fixedSize()
                            .background(GeometryReader { tip in
                                Color.clear
                                    .onAppear { tooltipSize = tip.size }
                                    .onChange(of: tip.size) { tooltipSize = $0 }
                            })
                            .offset(x: min(max(hoverPoint.x - 70, 0), max(geo.size.width - tooltipSize.width, 0)),
                                    y: min(max(hoverPoint.y - 44, 0), max(geo.size.height - tooltipSize.height, 0)))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    /// Resolves the stacked segment drawn under a point in the overlay's
    /// coordinate space. Nil when the point misses the plot, falls outside the
    /// axis domains, or lands above the week's stack.
    private func segment(at location: CGPoint,
                         proxy: ChartProxy,
                         geo: GeometryProxy) -> DashboardStore.HoveredSegment? {
        guard let plotAnchor = proxy.plotFrame else { return nil }
        let plot = geo[plotAnchor]
        guard let date: Date = proxy.value(atX: location.x - plot.origin.x),
              let week = store.nearestWeek(to: date),
              let hours: Double = proxy.value(atY: location.y - plot.origin.y)
        else { return nil }
        return store.segment(inWeek: week, atHours: hours)
    }

    /// Shows a pointing-hand cursor over slices that open a page, so the chart
    /// reads as clickable. Set on every hover event rather than once on entry
    /// because AppKit resets the cursor as the pointer moves within the window.
    private func updateCursor(for segment: DashboardStore.HoveredSegment?) {
        let clickable = segment.map { store.hasDetailPage(forSegment: $0.key) } ?? false
        (clickable ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    private static let axisLabelTextStyle = Font.caption2
    private static let axisLabelFont = NSFont.preferredFont(forTextStyle: .caption2)

    /// Which weeks get a label. Week ranges are twice as wide as the bare start
    /// dates they replaced, so at eight weeks in a narrow window they collide;
    /// when that happens, label every Nth week instead of truncating the range.
    /// Counted from the last week so the current one is always labeled.
    ///
    /// A tick needs ~1.5 label widths of room: the endpoint labels are anchored
    /// inward, so they reach a full width toward their neighbor's half width.
    private func labeledWeekDates(chartWidth: CGFloat) -> [Date] {
        let dates = store.windowWeekDates
        guard dates.count > 1 else { return dates }
        // The plot is inset by the Y axis labels on the trailing side only.
        let spacing = max(chartWidth - 52, 1) / CGFloat(dates.count - 1)
        let widest = dates
            .map { (store.weekLabelRange(date: $0) as NSString)
                .size(withAttributes: [.font: Self.axisLabelFont]).width }
            .max() ?? 0
        let stride = max(1, Int(ceil(widest * 1.5 / spacing)))
        return dates.enumerated()
            .filter { (dates.count - 1 - $0.offset) % stride == 0 }
            .map(\.element)
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
