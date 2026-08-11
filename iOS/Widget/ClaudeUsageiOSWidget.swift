import WidgetKit
import SwiftUI

@main
struct ClaudeUsageiOSWidgets: WidgetBundle {
    var body: some Widget {
        UsageWidget()
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeUsageiOS", provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Usage")
        .description("Claude Code rate-limit usage, synced from your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline, .accessoryRectangular])
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
        if context.isPreview {
            completion(.sample)
        } else {
            Task { completion(await current()) }
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            let entry = await current()
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    private func current() async -> UsageEntry {
        if let fetched = try? await CloudUsage.fetch() {
            return UsageEntry(date: Date(), rows: fetched.data.rows, updated: fetched.updated)
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
            switch family {
            case _ where entry.rows.isEmpty:
                emptyView
            case .accessoryCircular:
                circularView
            case .accessoryInline:
                inlineView
            case .accessoryRectangular:
                rectangularView
            case .systemSmall:
                smallView
            default:
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
            Image(systemName: "icloud")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Waiting for Mac")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // Lock screen ring
    private var circularView: some View {
        Gauge(value: min(100, primary?.percent ?? 0), in: 0...100) {
            Text("CC")
        } currentValueLabel: {
            Text("\(Int((primary?.percent ?? 0).rounded()))")
        }
        .gaugeStyle(.accessoryCircular)
    }

    // Lock screen one-liner
    private var inlineView: some View {
        let pct = Int((primary?.percent ?? 0).rounded())
        let reset = primary?.resetsAt.flatMap(compactReset) ?? ""
        return Text("Claude \(pct)% · \(reset)")
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(entry.rows.prefix(3)) { row in
                HStack(spacing: 4) {
                    Text(shortName(row))
                        .font(.caption2)
                    Spacer(minLength: 2)
                    Text("\(Int(row.percent.rounded()))%")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                    if let resetsAt = row.resetsAt, let reset = compactReset(resetsAt) {
                        Text(reset)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
    }

    // StandBy hero — big ring, high contrast
    private var smallView: some View {
        VStack(spacing: 6) {
            if let row = primary {
                ZStack {
                    UsageRing(percent: row.percent, lineWidth: 9)
                    VStack(spacing: 0) {
                        Text("\(Int(row.percent.rounded()))%")
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                        Text(row.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 76, height: 76)

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
                        .frame(width: 82, alignment: .leading)
                        .lineLimit(1)
                    UsageBar(percent: row.percent)
                        .frame(height: 5)
                    Text("\(Int(row.percent.rounded()))%")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                    if let resetsAt = row.resetsAt, let reset = compactReset(resetsAt) {
                        Text(reset)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func shortName(_ row: UsageRow) -> String {
        row.name
            .replacingOccurrences(of: "7-day ", with: "")
            .replacingOccurrences(of: "7-day", with: "7d")
            .replacingOccurrences(of: "5-hour", with: "5h")
    }
}
