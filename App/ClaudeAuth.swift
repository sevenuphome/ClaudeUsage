import Foundation
import Network
import AppKit

enum AuthError: LocalizedError {
    case portBusy
    case timedOut
    case stateMismatch

    var errorDescription: String? {
        switch self {
        case .portBusy: return "Port 54545 is in use (is a Claude Code login running?)"
        case .timedOut: return "Sign-in timed out — try again"
        case .stateMismatch: return "Sign-in callback failed a security check"
        }
    }
}

/// macOS interactive sign-in: opens the browser and catches the OAuth
/// redirect on a loopback listener. Token storage/refresh lives in the
/// shared ClaudeOAuth core.
enum ClaudeAuth {
    private static let redirectURI = "http://localhost:54545/callback"
    private static let callbackPort: UInt16 = 54545

    static var isSignedIn: Bool { ClaudeOAuth.isSignedIn }
    static func validToken(force: Bool = false) async throws -> String {
        try await ClaudeOAuth.validToken(force: force)
    }
    static func signOut() { ClaudeOAuth.signOut() }

    /// Interactive login: opens the browser, waits for the redirect back.
    static func signIn() async throws {
        let verifier = ClaudeOAuth.randomURLSafe(bytes: 48)
        let state = ClaudeOAuth.randomURLSafe(bytes: 24)
        let authorizeURL = ClaudeOAuth.authorizeURL(redirectURI: redirectURI, verifier: verifier, state: state)

        let callbackTask = Task { try await waitForCallback(expectedState: state) }
        _ = await MainActor.run { NSWorkspace.shared.open(authorizeURL) }
        let code = try await callbackTask.value

        try await ClaudeOAuth.exchange(code: code, verifier: verifier, state: state, redirectURI: redirectURI)
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
}
