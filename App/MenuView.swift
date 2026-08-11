import SwiftUI
import AppKit

struct MenuView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Claude Usage").font(.headline)
                Spacer()
                if let updated = state.updatedAt {
                    (Text(updated, style: .relative) + Text(" ago"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let data = state.data {
                ForEach(data.rows) { row in
                    RowView(row: row)
                }
                if let extra = data.extraUsage, extra.isEnabled == true, let util = extra.utilization {
                    RowView(row: UsageRow(id: "extra", name: "Extra usage", percent: util, resetsAt: nil))
                }
            } else {
                Text(state.errorText ?? "Loading…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = state.errorText, state.data != nil {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Divider()

            Picker("Menu bar shows", selection: $state.menuBucket) {
                ForEach(state.data?.rows ?? []) { row in
                    Text(row.name).tag(row.id)
                }
            }
            .pickerStyle(.menu)
            .font(.callout)

            Toggle("Launch at login", isOn: $state.launchAtLogin)
                .font(.callout)

            HStack {
                Button("Refresh now") {
                    Task { await state.refresh(force: true) }
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct RowView: View {
    let row: UsageRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name).font(.callout)
                Spacer()
                Text("\(Int(row.percent.rounded()))%")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            UsageBar(percent: row.percent)
                .frame(height: 6)
            if let resetsAt = row.resetsAt, let reset = compactReset(resetsAt) {
                Text("resets in \(reset)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
