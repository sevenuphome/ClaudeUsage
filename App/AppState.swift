import SwiftUI
import WidgetKit
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published var data: UsageData?
    @Published var updatedAt: Date?
    @Published var errorText: String?

    /// Which row drives the menu bar title (a UsageRow id, e.g. "five_hour", "model_Fable").
    @Published var menuBucket: String {
        didSet { UserDefaults.standard.set(menuBucket, forKey: "menuBucket") }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                errorText = "Login item: \(error.localizedDescription)"
            }
        }
    }

    private var timer: Timer?
    private var lastWidgetSignature = ""

    init() {
        menuBucket = UserDefaults.standard.string(forKey: "menuBucket") ?? "five_hour"
        launchAtLogin = SMAppService.mainApp.status == .enabled

        // Show cached data immediately, then refresh
        if let cached = UsageCache.load() {
            data = cached.data
            updatedAt = cached.updated
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    var title: String {
        guard let data else { return "…" }
        let rows = data.rows
        guard let row = rows.first(where: { $0.id == menuBucket }) ?? rows.first else { return "–" }
        var title = "\(Int(row.percent.rounded()))%"
        if let resetsAt = row.resetsAt, let reset = compactReset(resetsAt) {
            title += " \(reset)"
        }
        return title
    }

    func refresh(force: Bool = false) async {
        // Another cache client (SwiftBar, VS Code) may have fetched recently
        if !force, let cached = UsageCache.load(), cached.age < 60 {
            apply(cached.data, updated: cached.updated)
            return
        }
        do {
            let result = try await UsageFetcher.fetch()
            UsageCache.write(raw: result.raw)
            apply(result.typed, updated: Date())
            errorText = nil
        } catch {
            errorText = error.localizedDescription
            // Stale cache fallback — keep showing the last good value
            if let cached = UsageCache.load() {
                apply(cached.data, updated: cached.updated)
            }
        }
    }

    private func apply(_ newData: UsageData, updated: Date) {
        data = newData
        updatedAt = updated
        // Only poke WidgetKit when displayed values actually changed,
        // to stay well inside the refresh budget
        let signature = newData.rows.map { "\($0.id):\(Int($0.percent))" }.joined(separator: ",")
        if signature != lastWidgetSignature {
            lastWidgetSignature = signature
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
