import Foundation
import CryptoKit

/// Cross-platform OAuth 2.0 + PKCE core for Anthropic's Claude endpoints,
/// using the same public client as Claude Code. Each platform supplies its
/// own interactive front-end: macOS opens the browser and catches a loopback
/// redirect; iOS uses the console "copy the code" flow. Tokens live in an
/// app-owned keychain item (shared with the widget on iOS), so reading them
/// never triggers the cross-app keychain consent dialog.
enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Redirect target for the paste flow: the console page displays the
    /// authorization code as "code#state" for the user to copy.
    static let consoleRedirectURI = "https://console.anthropic.com/oauth/code/callback"

    private static let keychainService = "com.ekkasit.ClaudeUsage.oauth"
    #if os(iOS)
    private static let accessGroup = "XLD4Q2XZ63.com.ekkasit.ClaudeUsageiOS.shared"
    #endif

    struct Credentials: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    enum OAuthError: LocalizedError {
        case notSignedIn
        case exchangeFailed(String)
        case keychainFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Not signed in with Claude"
            case .exchangeFailed(let msg): return "Token exchange failed: \(msg)"
            case .keychainFailed(let status): return "Keychain save failed (\(status))"
            }
        }
    }

    // MARK: - Public surface

    static var isSignedIn: Bool { load() != nil }

    static func authorizeURL(redirectURI: String, verifier: String, state: String) -> URL {
        var comps = URLComponents(string: "https://claude.ai/oauth/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "org:create_api_key user:profile user:inference"),
            URLQueryItem(name: "code_challenge", value: codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return comps.url!
    }

    /// Exchanges an authorization code for tokens and stores them.
    static func exchange(code: String, verifier: String, state: String, redirectURI: String) async throws {
        let creds = try await tokenRequest(body: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
            "state": state,
        ])
        try save(creds)
    }

    /// Returns a valid access token, silently refreshing when near expiry
    /// (or when `force` is set after a server-side rejection).
    static func validToken(force: Bool = false) async throws -> String {
        guard let creds = load() else { throw OAuthError.notSignedIn }
        if !force, creds.expiresAt.timeIntervalSinceNow > 300 {
            return creds.accessToken
        }
        let fresh = try await tokenRequest(body: [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": creds.refreshToken,
        ])
        try save(fresh)
        return fresh.accessToken
    }

    static func signOut() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    // MARK: - Keychain

    static func load() -> Credentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Credentials.self, from: data)
    }

    private static func save(_ creds: Credentials) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(creds)
        signOut()
        var add = baseQuery()
        add[kSecAttrLabel as String] = "Claude Usage OAuth"
        add[kSecValueData as String] = data
        #if os(iOS)
        // Readable by the widget while the phone is locked (AOD refreshes)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        #endif
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw OAuthError.keychainFailed(status) }
    }

    private static func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        #if os(iOS)
        query[kSecAttrAccessGroup as String] = accessGroup
        #endif
        return query
    }

    // MARK: - Token endpoint

    private static func tokenRequest(body: [String: Any]) async throws -> Credentials {
        var request = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String,
              let refresh = obj["refresh_token"] as? String,
              let expiresIn = obj["expires_in"] as? Double else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? "no detail"
            throw OAuthError.exchangeFailed(detail)
        }
        return Credentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    // MARK: - PKCE helpers

    static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
