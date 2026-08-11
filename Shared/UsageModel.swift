import Foundation

// Mirrors the JSON from https://api.anthropic.com/api/oauth/usage
// (same payload the shell scripts cache in ~/.claude/.usage-cache.json)

struct UsageData: Codable {
    var fiveHour: Bucket?
    var sevenDay: Bucket?
    var sevenDayOpus: Bucket?
    var sevenDaySonnet: Bucket?
    var limits: [Limit]?
    var extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
        case extraUsage = "extra_usage"
    }
}

struct Bucket: Codable {
    var utilization: Double?
    var resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct Limit: Codable {
    var kind: String?
    var percent: Double?
    var severity: String?
    var resetsAt: Date?
    var isActive: Bool?
    var scope: Scope?

    struct Scope: Codable {
        var model: Model?

        struct Model: Codable {
            var displayName: String?

            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }
}

struct ExtraUsage: Codable {
    var isEnabled: Bool?
    var utilization: Double?
    var monthlyLimit: Double?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case utilization
        case monthlyLimit = "monthly_limit"
    }
}

// MARK: - Display rows

struct UsageRow: Identifiable, Equatable {
    let id: String
    let name: String
    let percent: Double
    let resetsAt: Date?
}

extension UsageData {
    /// Buckets in display order, skipping ones the API returned as null.
    /// Model-scoped weekly limits (Fable etc.) only appear in the limits array.
    var rows: [UsageRow] {
        var out: [UsageRow] = []
        let named: [(String, String, Bucket?)] = [
            ("five_hour", "5-hour", fiveHour),
            ("seven_day", "7-day", sevenDay),
            ("seven_day_opus", "7-day Opus", sevenDayOpus),
            ("seven_day_sonnet", "7-day Sonnet", sevenDaySonnet),
        ]
        for (id, name, bucket) in named {
            if let bucket, let util = bucket.utilization {
                out.append(UsageRow(id: id, name: name, percent: util, resetsAt: bucket.resetsAt))
            }
        }
        for limit in limits ?? [] {
            guard let model = limit.scope?.model?.displayName, let percent = limit.percent else { continue }
            out.append(UsageRow(id: "model_\(model)", name: "7-day \(model)", percent: percent, resetsAt: limit.resetsAt))
        }
        return out
    }
}

// MARK: - Formatting

/// "3h39m" / "1d4h" / "39m" — same format as claude-usage-compact.sh
func compactReset(_ date: Date) -> String? {
    let secs = max(0, Int(date.timeIntervalSinceNow))
    let days = secs / 86400
    let hours = (secs % 86400) / 3600
    let mins = (secs % 3600) / 60
    if secs >= 86400 { return "\(days)d\(hours)h" }
    if secs >= 3600 { return "\(hours)h\(mins)m" }
    return "\(mins)m"
}
