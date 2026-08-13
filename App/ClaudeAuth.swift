import Foundation
import CryptoKit
import Network
import AppKit

/// The app's own OAuth credentials, stored in its own keychain item —
/// created by this app, owned by this app, so macOS never shows the
/// cross-app keychain consent dialog for it.
struct StoredCredentials: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

enum AuthError: LocalizedError {
    case notSignedIn
    case portBusy
    case timedOut
    case stateMismatch
    case exchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in — use “Sign in with Claude”"
        case .portBusy: return "Port 54545 is in use (is a Claude Code login running?)"
        case .timedOut: return "Sign-in timed out — try again"
        case .stateMismatch: return "Sign-in callback failed a security check"
        case .exchangeFailed(let msg): return "Token exchange failed: \(msg)"
        }
    }
}

/// OAuth 2.0 + PKCE against Anthropic's Claude endpoints, using the same
/// public client as Claude Code. The grant is independent of Claude Code's —
/// signing in here does not disturb the CLI session.
enum ClaudeAuth {
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let redirectURI = "http://localhost:54545/callback"
    private static let callbackPort: UInt16 = 54545
    private static let keychainService = "com.ekkasit.ClaudeUsage.oauth"

    // MARK: - Public surface

    static var isSignedIn: Bool { loadCredentials() != nil }

    /// Interactive login: opens the browser, waits for the redirect back.
    static func signIn() async throws {
        let verifier = randomURLSafe(bytes: 48)
        let state = randomURLSafe(bytes: 24)

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
        let authorizeURL = comps.url!

        let callbackTask = Task { try await waitForCallback(expectedState: state) }
        _ = await MainActor.run { NSWorkspace.shared.open(authorizeURL) }
        let code = try await callbackTask.value

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

    /// Returns a valid access token, silently refreshing when it is near
    /// expiry (or when `force` is set after a server-side rejection).
    static func validToken(force: Bool = false) async throws -> String {
        guard let creds = loadCredentials() else { throw AuthError.notSignedIn }
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Keychain (app-owned item)

    static func loadCredentials() -> StoredCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(StoredCredentials.self, from: data)
    }

    private static func save(_ creds: StoredCredentials) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(creds)
        signOut()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrLabel as String: "Claude Usage OAuth",
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.exchangeFailed("keychain save failed (\(status))")
        }
    }

    // MARK: - Token endpoint

    private static func tokenRequest(body: [String: Any]) async throws -> StoredCredentials {
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
            throw AuthError.exchangeFailed(detail)
        }
        return StoredCredentials(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    // MARK: - Localhost callback listener

    private static func waitForCallback(expectedState: String) async throws -> String {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func first() -> Bool {
                lock.lock(); defer { lock.unlock() }
                if done { return false }
                done = true
                return true
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: callbackPort)!
            )
            let listener: NWListener
            do {
                listener = try NWListener(using: params)
            } catch {
                continuation.resume(throwing: AuthError.portBusy)
                return
            }

            let once = Once()
            let finish: (Result<String, Error>) -> Void = { result in
                guard once.first() else { return }
                listener.cancel()
                continuation.resume(with: result)
            }

            listener.stateUpdateHandler = { state in
                if case .failed = state { finish(.failure(AuthError.portBusy)) }
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .global(qos: .userInitiated))
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                    guard let data, let request = String(data: data, encoding: .utf8),
                          let requestLine = request.components(separatedBy: "\r\n").first,
                          requestLine.hasPrefix("GET ") else {
                        connection.cancel()
                        return
                    }
                    let path = requestLine.components(separatedBy: " ")[1]
                    guard path.hasPrefix("/callback"),
                          let comps = URLComponents(string: "http://localhost\(path)"),
                          let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
                        respond(connection, status: "404 Not Found", html: "Not found") {}
                        return
                    }
                    let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value
                    guard returnedState == expectedState else {
                        respond(connection, status: "400 Bad Request", html: failureHTML) {
                            finish(.failure(AuthError.stateMismatch))
                        }
                        return
                    }
                    respond(connection, status: "200 OK", html: successHTML) {
                        finish(.success(code))
                    }
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                finish(.failure(AuthError.timedOut))
            }
        }
    }

    private static func respond(_ connection: NWConnection, status: String, html: String, then: @escaping () -> Void) {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: payload.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
            then()
        })
    }

    private static let successHTML = """
    <!doctype html><meta charset=utf-8><title>Claude Usage</title>
    <body style="font-family:-apple-system,sans-serif;display:grid;place-items:center;height:90vh;background:#1a1a18;color:#eee">
    <div style="text-align:center"><div style="font-size:56px">✳︎</div>
    <h2>Signed in</h2><p>You can close this tab and return to Claude Usage.</p></div>
    """

    private static let failureHTML = """
    <!doctype html><meta charset=utf-8><title>Claude Usage</title>
    <body style="font-family:-apple-system,sans-serif;display:grid;place-items:center;height:90vh">
    <p>Sign-in failed a security check — please try again from the app.</p>
    """

    // MARK: - PKCE helpers

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private static func codeChallenge(for verifier: String) -> String {
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
