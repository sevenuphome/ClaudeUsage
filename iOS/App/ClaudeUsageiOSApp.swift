import SwiftUI
import WidgetKit

@main
struct ClaudeUsageiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var fetched: CloudUsage.Fetched?
    @State private var errorText: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Group {
                if let fetched {
                    List {
                        Section {
                            ForEach(fetched.data.rows) { row in
                                UsageRowView(row: row)
                            }
                        } footer: {
                            (Text("Updated on Mac ") + Text(fetched.updated, style: .relative) + Text(" ago"))
                        }
                    }
                } else if loading {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label("No data yet", systemImage: "icloud")
                    } description: {
                        Text(errorText ?? "Open the Claude Usage app on your Mac — it publishes usage to iCloud, then it shows up here and in the widget.")
                    } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                }
            }
            .navigationTitle("Claude Usage")
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        loading = fetched == nil
        defer { loading = false }
        do {
            fetched = try await CloudUsage.fetch()
            errorText = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct UsageRowView: View {
    let row: UsageRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name)
                Spacer()
                Text("\(Int(row.percent.rounded()))%")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            UsageBar(percent: row.percent)
                .frame(height: 6)
            if let resetsAt = row.resetsAt, let reset = compactReset(resetsAt) {
                Text("resets in \(reset)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
