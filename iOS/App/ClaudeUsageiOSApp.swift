import SwiftUI
import WidgetKit

@main
struct ClaudeUsageiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    struct Display {
        var rows: [UsageRow]
        var updated: Date
        var fromMac: Bool
    }

    @State private var display: Display?
    @State private var errorText: String?
    @State private var loading = false
    @State private var signedIn = ClaudeOAuth.isSignedIn
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            Group {
                if let display {
                    List {
                        Section {
                            ForEach(display.rows) { row in
                                UsageRowView(row: row)
                            }
                        } footer: {
                            if display.fromMac {
                                (Text("Updated on Mac ") + Text(display.updated, style: .relative) + Text(" ago"))
                            } else {
                                (Text("Fetched directly ") + Text(display.updated, style: .relative) + Text(" ago"))
                            }
                        }
                    }
                } else if loading {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label("No data yet", systemImage: signedIn ? "exclamationmark.icloud" : "person.crop.circle.badge.questionmark")
                    } description: {
                        Text(errorText ?? (signedIn
                            ? "Couldn't fetch usage — pull to retry."
                            : "Sign in with Claude to fetch usage directly on this phone, or open the Mac app to sync via iCloud."))
                    } actions: {
                        if !signedIn {
                            Button("Sign in with Claude") { showSignIn = true }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Retry") { Task { await load() } }
                    }
                }
            }
            .navigationTitle("Claude Usage")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if signedIn {
                            Label("Signed in with Claude", systemImage: "checkmark.seal.fill")
                            Button("Sign out", role: .destructive) {
                                ClaudeOAuth.signOut()
                                signedIn = false
                                Task { await load() }
                            }
                        } else {
                            Button("Sign in with Claude…") { showSignIn = true }
                        }
                    } label: {
                        Image(systemName: signedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                    }
                }
            }
            .sheet(isPresented: $showSignIn) {
                SignInView {
                    signedIn = true
                    Task { await load() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private func load() async {
        loading = display == nil
        defer { loading = false }

        if signedIn {
            do {
                let data = try await UsageAPI.fetchWithOwnToken()
                display = Display(rows: data.rows, updated: Date(), fromMac: false)
                errorText = nil
                WidgetCenter.shared.reloadAllTimelines()
                return
            } catch {
                errorText = error.localizedDescription
                // fall through to the iCloud relay
            }
        }
        do {
            guard let fetched = try await CloudUsage.fetch() else { return }
            display = Display(rows: fetched.data.rows, updated: fetched.updated, fromMac: true)
            if signedIn == false { errorText = nil }
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            if errorText == nil { errorText = error.localizedDescription }
        }
    }
}

// MARK: - Sign in (paste flow)

/// iOS can't catch a loopback OAuth redirect (the app suspends while Safari
/// is frontmost), so this uses the console "copy the code" flow: approve in
/// the browser, Anthropic shows a code, paste it here once.
struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var verifier = ClaudeOAuth.randomURLSafe(bytes: 48)
    @State private var oauthState = ClaudeOAuth.randomURLSafe(bytes: 24)
    @State private var pasted = ""
    @State private var working = false
    @State private var errorText: String?

    let onSignedIn: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        openURL(ClaudeOAuth.authorizeURL(
                            redirectURI: ClaudeOAuth.consoleRedirectURI,
                            verifier: verifier,
                            state: oauthState
                        ))
                    } label: {
                        Label("Open claude.ai to authorize", systemImage: "safari")
                    }
                } header: {
                    Text("Step 1")
                } footer: {
                    Text("Sign in and approve. The page then shows an authorization code — copy it.")
                }

                Section {
                    TextField("Paste the code here", text: $pasted, axis: .vertical)
                        .font(.callout.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        Task { await complete() }
                    } label: {
                        if working {
                            ProgressView()
                        } else {
                            Label("Complete sign-in", systemImage: "checkmark.circle.fill")
                        }
                    }
                    .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                } header: {
                    Text("Step 2")
                } footer: {
                    if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Sign in with Claude")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func complete() async {
        working = true
        defer { working = false }
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        let code = parts[0]
        if parts.count == 2, parts[1] != oauthState {
            errorText = "That code belongs to a different sign-in attempt — reopen claude.ai from Step 1 and paste the new code."
            return
        }
        do {
            try await ClaudeOAuth.exchange(
                code: code,
                verifier: verifier,
                state: oauthState,
                redirectURI: ClaudeOAuth.consoleRedirectURI
            )
            onSignedIn()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct UsageRowView: View {
    let row: UsageRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name)
                Spacer()
                Text("\(Int(row.percent.rounded()))%")
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            UsageBar(percent: row.percent)
                .frame(height: 6)
            if let resetsAt = row.resetsAt, let reset = compactReset(resetsAt) {
                Text("resets in \(reset)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
