import Foundation

/// Shared cache at ~/.claude/.usage-cache.json — same file (and format) used by
/// claude-usage.sh, claude-usage-compact.sh, and the VS Code extension:
/// { "timestamp": <ms epoch>, "data": { ...API response... } }
enum UsageCache {

    /// The real home directory, even inside the sandboxed widget extension
    /// (NSHomeDirectory there points at the container, but the widget has a
    /// home-relative read exception for ~/.claude/).
    static var realHome: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var fileURL: URL {
        realHome.appendingPathComponent(".claude/.usage-cache.json")
    }

    struct Loaded {
        let data: UsageData
        let updated: Date
        var age: TimeInterval { Date().timeIntervalSince(updated) }
    }

    private struct Snapshot: Codable {
        let timestamp: Int64
        let data: UsageData
    }

    static func load() -> Loaded? {
        guard let raw = try? Data(contentsOf: fileURL),
              let snap = try? decoder.decode(Snapshot.self, from: raw) else { return nil }
        return Loaded(data: snap.data, updated: Date(timeIntervalSince1970: Double(snap.timestamp) / 1000))
    }

    /// Writes the raw API response verbatim so other cache consumers keep
    /// seeing every field, not just the ones this app decodes.
    static func write(raw: Any) {
        let wrapper: [String: Any] = [
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
            "data": raw,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Handles ISO8601 with microseconds ("2026-08-11T05:50:00.203215+00:00"),
    /// milliseconds, or none.
    static let decoder: JSONDecoder = {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = isoFrac.date(from: s) ?? iso.date(from: s) { return date }
            // Fall back: strip the fractional-seconds part entirely
            if let range = s.range(of: #"\.\d+"#, options: .regularExpression) {
                var trimmed = s
                trimmed.removeSubrange(range)
                if let date = iso.date(from: trimmed) { return date }
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unparseable date: \(s)"))
        }
        return d
    }()
}
