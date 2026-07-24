import SwiftUI
import ChronicleCore

/// A thumbnail of when the selected task actually happens, drawn beside its name
/// in the detail header. Weekly tasks get the current Mon–Sun week plotted over an
/// 8am–10pm band; tasks that only recur monthly get a mini month grid instead.
///
/// Deliberately tiny and label-free — there is only room for one- or two-letter
/// day headers, so the shape of the routine, not its detail, is what it conveys.
/// Renders nothing when there's no preview to show.
struct SchedulePreviewView: View {
    /// What to draw, or nil for nothing at all.
    let preview: SchedulePreview?
    /// The selected task's color, so its marks read as the same activity the
    /// sidebar swatch and chart band do.
    let color: Color

    /// Column geometry, shared by the week plot and the month grid so their day
    /// columns line up under the same headers.
    private static let columnWidth: CGFloat = 14
    private static let columnSpacing: CGFloat = 2
    /// Kept just under the height of the name + subtitle it sits beside, so the
    /// preview never grows the header.
    private static let plotHeight: CGFloat = 28
    /// Floor on a mark's height. Deliberately below the ~2pt an hour occupies, so
    /// the common one-hour event still renders at its true size and only much
    /// shorter events get rounded up to stay visible.
    private static let markHeight: CGFloat = 2
    private static let dotSize: CGFloat = 4

    private static let dayLetters = ["M", "T", "W", "Th", "F", "Sa", "Su"]

    var body: some View {
        if let preview {
            VStack(spacing: 3) {
                headers
                switch preview {
                case .week(let days): weekPlot(days)
                case .month(let month): monthGrid(month)
                }
            }
            // Never compress: the columns are fixed-width, so a squeezed header
            // would overflow them instead of shrinking. The task name beside it
            // wraps to absorb the narrowing.
            .fixedSize()
            .help(summary(preview))
            .accessibilityElement()
            .accessibilityLabel("Schedule preview")
            .accessibilityValue(summary(preview))
        }
    }

    private var headers: some View {
        HStack(spacing: Self.columnSpacing) {
            ForEach(Self.dayLetters, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: Self.columnWidth)
            }
        }
    }

    // MARK: - Week

    /// One column per day. The faint column fill gives each day a readable extent
    /// without drawing grid lines; marks sit at their time's height within it.
    private func weekPlot(_ days: [[ScheduleMark]]) -> some View {
        HStack(spacing: Self.columnSpacing) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, marks in
                GeometryReader { geo in
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.05))
                        ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                            // As tall as the event is long, floored so a short one
                            // stays visible, and nudged up if it would run off the
                            // bottom of the band.
                            let height = max(Self.markHeight,
                                             mark.durationFraction * geo.size.height)
                            let top = min(mark.fraction * geo.size.height,
                                          geo.size.height - height)
                            Capsule()
                                .fill(color)
                                .frame(width: Self.columnWidth - 4, height: height)
                                .position(x: geo.size.width / 2, y: top + height / 2)
                        }
                    }
                }
                .frame(width: Self.columnWidth)
            }
        }
        .frame(height: Self.plotHeight)
    }

    // MARK: - Month

    /// The current month as Monday-first rows of dots: filled on days the task
    /// occurs, faint otherwise, ringed on today.
    private func monthGrid(_ month: MonthPreview) -> some View {
        // Blank cells (0) for the days before the 1st, then each day of the month,
        // then blanks again to fill the final row. Padding both ends keeps every
        // row exactly seven fixed-width cells: a short row would otherwise be the
        // only flexible one, and would drift out of column when the header is
        // narrow enough to squeeze the preview.
        let leading = Array(repeating: 0, count: month.leadingBlanks)
        let cells = leading + Array(1...month.dayCount)
        let padded = cells + Array(repeating: 0, count: (7 - cells.count % 7) % 7)
        let rows = stride(from: 0, to: padded.count, by: 7).map {
            Array(padded[$0..<$0 + 7])
        }
        // Spread whatever rows this month needs (5 or 6) across the same height as
        // the week plot, so the header doesn't resize from month to month.
        let spacing = rows.count > 1
            ? (Self.plotHeight - CGFloat(rows.count) * Self.dotSize) / CGFloat(rows.count - 1)
            : 0
        return VStack(spacing: spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Self.columnSpacing) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, day in
                        dot(day, month: month)
                            .frame(width: Self.columnWidth)
                    }
                }
            }
        }
        .frame(height: Self.plotHeight, alignment: .top)
    }

    @ViewBuilder
    private func dot(_ day: Int, month: MonthPreview) -> some View {
        let marked = month.markedDays.contains(day)
        Circle()
            .fill(day == 0 ? Color.clear
                  : marked ? color : Color.primary.opacity(0.12))
            .frame(width: Self.dotSize, height: Self.dotSize)
            .overlay(
                Circle()
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                    .frame(width: Self.dotSize + 3, height: Self.dotSize + 3)
                    .opacity(day != 0 && day == month.today ? 1 : 0)
            )
    }

    // MARK: - Text description

    /// A plain-text reading of the preview, for the tooltip and VoiceOver — the
    /// marks themselves carry no text.
    private func summary(_ preview: SchedulePreview) -> String {
        switch preview {
        case .week(let days):
            let parts = days.enumerated().flatMap { index, marks in
                marks.map { "\(Self.dayLetters[index]) \(Self.time($0.minutes))" }
            }
            return parts.isEmpty ? "Nothing scheduled this week"
                                 : parts.joined(separator: " · ")
        case .month(let month):
            let count = month.markedDays.count
            return count == 1 ? "Occurs once this month"
                              : "Occurs \(count) times this month"
        }
    }

    /// Minutes from midnight as a locale-aware clock time, e.g. `9:00 AM`.
    private static func time(_ minutes: Int) -> String {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        guard let date = Calendar.current.date(from: components) else { return "" }
        return timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()
}
