import Foundation
import Security

enum FetchError: LocalizedError {
    case noToken
    case badResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .noToken: return "No OAuth token in Keychain"
        case .badResponse: return "Unreadable API response"
        case .api(let msg): return msg
        }
    }
}

enum UsageFetcher {

    /// Reads the Claude Code OAuth access token from the login keychain
    /// (service "Claude Code-credentials"). First access triggers the macOS
    /// consent dialog — "Always Allow" makes it permanent.
    static func keychainToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw FetchError.noToken
        }
        return token
    }

    /// Fetches usage from the OAuth API. Returns both the raw JSON object
    /// (written back to the shared cache verbatim) and the typed model.
    static func fetch() async throws -> (raw: [String: Any], typed: UsageData) {
        let token = try keychainToken()

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
            throw FetchError.api("API error: \(error)")
        }
        let typed = try UsageCache.decoder.decode(UsageData.self, from: data)
        return (dict, typed)
    }
}
