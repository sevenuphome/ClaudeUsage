import Foundation

enum UsageAPIError: LocalizedError {
    case badResponse
    case unauthorized
    case rateLimited
    case api(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unreadable API response"
        case .unauthorized: return "Token rejected — sign in again"
        case .rateLimited: return "Usage API rate-limited"
        case .api(let msg): return msg
        }
    }
}

/// Direct usage fetch with the app's own OAuth token. Used by the iOS app
/// and widget; the Mac app has its own fetcher wired into the shared cache.
enum UsageAPI {

    /// Fetch with the stored own-token, forcing one refresh + retry when the
    /// server rejects the token.
    static func fetchWithOwnToken() async throws -> UsageData {
        do {
            return try await fetch(token: ClaudeOAuth.validToken())
        } catch UsageAPIError.unauthorized {
            return try await fetch(token: ClaudeOAuth.validToken(force: true))
        }
    }

    static func fetch(token: String) async throws -> UsageData {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageAPIError.badResponse
        }
        if let error = dict["error"] {
            if let details = error as? [String: Any], let type = details["type"] as? String {
                if type == "rate_limit_error" { throw UsageAPIError.rateLimited }
                if type == "authentication_error" { throw UsageAPIError.unauthorized }
                throw UsageAPIError.api((details["message"] as? String) ?? type)
            }
            throw UsageAPIError.api("API error: \(error)")
        }
        return try UsageCache.decoder.decode(UsageData.self, from: data)
    }
}
