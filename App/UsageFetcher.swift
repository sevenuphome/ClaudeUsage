import Foundation
import Security

enum FetchError: LocalizedError {
    case noToken
    case badResponse
    case rateLimited
    case unauthorized
    case api(String)

    var errorDescription: String? {
        switch self {
        case .noToken: return "No token — use “Sign in with Claude”"
        case .badResponse: return "Unreadable API response"
        case .rateLimited: return "Usage API rate-limited — backing off"
        case .unauthorized: return "Token rejected — sign in again"
        case .api(let msg): return msg
        }
    }
}

enum UsageFetcher {

    /// Reads the Claude Code OAuth access token from the login keychain
    /// (service "Claude Code-credentials").
    ///
    /// Goes through /usr/bin/security rather than SecItemCopyMatching: the
    /// keychain ACL prompt is per accessing binary, and `security` is the one
    /// the user has already blessed for the SwiftBar/VS Code scripts — so the
    /// app inherits that standing approval instead of prompting on each build.
    static func keychainToken() throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { throw FetchError.noToken }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw FetchError.noToken
        }
        return token
    }

    /// Fetches usage from the OAuth API. Returns both the raw JSON object
    /// (written back to the shared cache verbatim) and the typed model.
    ///
    /// Token preference: the app's own OAuth credentials (silent, refreshed
    /// in place), falling back to Claude Code's keychain item only when the
    /// user has not signed in. One forced refresh + retry on auth rejection.
    static func fetch() async throws -> (raw: [String: Any], typed: UsageData) {
        if ClaudeAuth.isSignedIn {
            do {
                return try await fetchOnce(token: ClaudeAuth.validToken())
            } catch FetchError.unauthorized {
                return try await fetchOnce(token: ClaudeAuth.validToken(force: true))
            }
        }
        return try await fetchOnce(token: keychainToken())
    }

    private static func fetchOnce(token: String) async throws -> (raw: [String: Any], typed: UsageData) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badResponse
        }
        if let error = dict["error"] {
            if let details = error as? [String: Any], let type = details["type"] as? String {
                if type == "rate_limit_error" { throw FetchError.rateLimited }
                if type == "authentication_error" { throw FetchError.unauthorized }
                throw FetchError.api((details["message"] as? String) ?? type)
            }
            throw FetchError.api("API error: \(error)")
        }
        let typed = try UsageCache.decoder.decode(UsageData.self, from: data)
        return (dict, typed)
    }
}
