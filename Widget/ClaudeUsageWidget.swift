import WidgetKit
import SwiftUI

@main
struct ClaudeUsageWidgets: WidgetBundle {
    var body: some Widget {
        UsageWidget()
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeUsage", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Claude Code rate-limit usage.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    let date: Date
    let rows: [UsageRow]
    let updated: Date?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(context.isPreview ? .sample : current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // The menu bar app pokes reloadAllTimelines() whenever values change;
        // this schedule is just the fallback when the app isn't running.
        completion(Timeline(entries: [current()], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func current() -> UsageEntry {
        if let cached = UsageCache.load() {
            return UsageEntry(date: Date(), rows: cached.data.rows, updated: cached.updated)
        }
        return UsageEntry(date: Date(), rows: [], updated: nil)
    }
}

extension UsageEntry {
    static var sample: UsageEntry {
        UsageEntry(date: Date(), rows: [
            UsageRow(id: "five_hour", name: "5-hour", percent: 21, resetsAt: Date().addingTimeInterval(3 * 3600 + 39 * 60)),
            UsageRow(id: "seven_day", name: "7-day", percent: 36, resetsAt: Date().addingTimeInterval(2 * 86400)),
            UsageRow(id: "model_Fable", name: "7-day Fable", percent: 54, resetsAt: Date().addingTimeInterval(2 * 86400)),
        ], updated: Date())
    }
}

// MARK: - Views

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Group {
            if entry.rows.isEmpty {
                emptyView
            } else if family == .systemSmall {
                smallView
            } else {
                mediumView
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var primary: UsageRow? {
        entry.rows.first { $0.id == "five_hour" } ?? entry.rows.first
    }

    private var secondaryRows: [UsageRow] {
        entry.rows.filter { $0.id != primary?.id }
    }

    private var emptyView: some View {
        VStack(spacing: 4) {
            Image(systemName: "gauge")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No usage data")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Run the Claude Usage app")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var smallView: some View {
        VStack(spacing: 6) {
            if let row = primary {
                ZStack {
                    Ring(percent: row.percent)
                    VStack(spacing: 0) {
                        Text("\(Int(row.percent.rounded()))%")
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                        Text(row.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 72, height: 72)

                if let resetsAt = row.resetsAt {
                    (Text("resets ") + Text(resetsAt, style: .relative))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !secondaryRows.isEmpty {
                    Text(secondaryRows.prefix(2)
                        .map { "\(shortName($0)) \(Int($0.percent.rounded()))%" }
                        .joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude Usage")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let updated = entry.updated {
                    (Text(updated, style: .relative) + Text(" ago"))
                        .font(.caption2)
                        .foregroundStyle(entry.date.timeIntervalSince(updated) > 30 * 60 ? .orange : .secondary)
                }
            }
            ForEach(entry.rows.prefix(4)) { row in
                HStack(spacing: 8) {
                    Text(row.name)
                        .font(.caption)
                        .frame(width: 78, alignment: .leading)
                        .lineLimit(1)
                    UsageBar(percent: row.percent)
                        .frame(height: 5)
                    Text("\(Int(row.percent.rounded()))%")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                    if let resetsAt = row.resetsAt, let reset = compactReset(resetsAt) {
                        Text(reset)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func shortName(_ row: UsageRow) -> String {
        row.name.replacingOccurrences(of: "7-day ", with: "").replacingOccurrences(of: "7-day", with: "7d")
    }
}

private struct Ring: View {
    let percent: Double

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(1, percent / 100))
                .stroke(usageTint(percent), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}
