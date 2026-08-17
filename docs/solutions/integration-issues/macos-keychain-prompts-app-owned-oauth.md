---
title: "Recurring macOS keychain consent prompts for another app's credentials, solved with app-owned OAuth sign-in"
category: integration-issues
date: 2026-08-14
problem_type: integration_issue
component:
  - ClaudeUsage macOS menu bar app (UsageFetcher keychain read)
  - ClaudeAuth / ClaudeOAuth (OAuth sign-in + token storage)
  - ClaudeUsage iOS app and widget (paste-flow sign-in, shared keychain group)
symptoms:
  - 'macOS dialog on launch/fetch: "Claude Usage wants to access key "Claude Code-credentials" in your keychain." with password field "To allow this, enter the "login" keychain password."'
  - Dialog reappeared across multiple days (Aug 12-14) despite the user approving it each time
  - Clicking "Allow" granted only single-use access, so every app relaunch re-prompted
  - Each rebuild/reinstall during the dev cycle made the app a new keychain applicant, re-triggering the prompt even after approvals
  - An interim fix (reading the token via /usr/bin/security) never reached the installed app because the rebuild was interrupted, so prompts continued from the stale binary
tags:
  - macos-keychain
  - keychain-acl
  - always-allow
  - cross-app-credentials
  - oauth
  - pkce
  - claude-code-token
  - menu-bar-app
  - sign-in-with-claude
  - loopback-redirect
  - paste-code-flow
  - keychain-access-group
  - widgetkit
severity: medium  # friction
platforms:
  - macOS
  - iOS
---

## Problem

The ClaudeUsage menu bar app read the Claude Code OAuth token directly from the `Claude Code-credentials` keychain item, so macOS repeatedly showed the "Claude Usage wants to access key…" password dialog — on day one, again the next morning, and again after updates. Each dialog demanded the login-keychain password, training the user to type their Mac password into an unexpected popup, and made the app feel broken even though fetches succeeded once allowed.

## Investigation

**a) Clicking "Allow"** — permitted exactly one access. The next app launch (or next day) re-prompted. Lesson: "Allow" is single-use; only "Always Allow" writes a persistent ACL entry.

**b) Expecting "Always Allow" to persist** — the ACL rule is tied to the specific approved binary (its code-signing designated requirement). During active development the app was rebuilt and reinstalled many times per day (CloudKit fix, rate-limit backoff, menu bar icon, widget tweaks…), and each new build could present as a new applicant, resurrecting the prompt. Lesson: per-binary grants and a fast rebuild cadence are structurally incompatible.

**c) Shelling out to `/usr/bin/security`** — replacing `SecItemCopyMatching` with:

```swift
proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
```

Apple's `security` tool is one stable binary the user had already blessed (it's how the SwiftBar and VS Code scripts read the token silently for weeks), so the app inherits that standing approval. This works, but it's a workaround riding a broad grant rather than a scoped one — and it was superseded by the OAuth design before it was ever rebuilt and deployed.

## Root cause

macOS keychain access control is per-item **and** per-accessing-binary. An app that reads *another program's* credential item is structurally prompt-prone: every "Allow" is one-shot, every "Always Allow" is pinned to one binary identity, and every rebuild during development risks presenting a new identity. No amount of dialog-clicking fixes the architecture. The durable fix is for the app to **own its credential**: obtain its own OAuth grant and store it in a keychain item the app itself creates — reading your own item never triggers the consent dialog.

## Solution

**Shared OAuth core** (`Shared/ClaudeOAuth.swift`) — OAuth 2.0 + PKCE against Anthropic's endpoints using Claude Code's public client, compiled into all four targets:

```swift
static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
// authorize: https://claude.ai/oauth/authorize with
//   code=true, response_type=code, scope="org:create_api_key user:profile user:inference",
//   code_challenge = base64url(SHA256(verifier)), code_challenge_method=S256, state
// exchange/refresh: POST https://console.anthropic.com/v1/oauth/token
```

Tokens are stored as JSON in the app's **own** keychain item — service `com.ekkasit.ClaudeUsage.oauth` — via `SecItemAdd`, so no cross-app consent dialog can ever fire. Signing in creates a *separate* grant; the Claude Code CLI session is untouched.

**macOS front-end** (`App/ClaudeAuth.swift`) — browser flow with an automatic hand-back: an `NWListener` bound to loopback only,

```swift
params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback),
                                                   port: NWEndpoint.Port(rawValue: 54545)!)
```

with `redirect_uri = http://localhost:54545/callback`. The handler verifies the returned `state` matches the expected value (rejecting with 400 on mismatch), serves a small "✳︎ Signed in" HTML page, and resolves the waiting continuation with the code; a 300 s timeout and an `Once` lock guard the continuation.

**iOS front-end** (paste flow in `ClaudeUsageiOSApp.swift`) — iOS suspends the app the moment Safari comes frontmost, so a loopback listener can't catch the redirect. Instead the authorize URL uses `redirect_uri = https://console.anthropic.com/oauth/code/callback` with `code=true`; after approval the console page displays an authorization code (`code#state`) that the user copies and pastes into the app once. The app splits on `#`, checks the state half against its own, then exchanges with the same PKCE verifier.

**iOS widget independence** — the token item is placed in a shared keychain access group readable by the widget even while the phone is locked (Always-On Display refreshes):

```swift
query[kSecAttrAccessGroup as String] = "XLD4Q2XZ63.com.ekkasit.ClaudeUsageiOS.shared"
add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
```

with `keychain-access-groups: $(AppIdentifierPrefix)com.ekkasit.ClaudeUsageiOS.shared` in both iOS targets' entitlements. The widget's timeline provider now fetches usage directly with the phone's own token; the Mac-published CloudKit record is demoted to fallback:

```swift
if ClaudeOAuth.isSignedIn, let data = try? await UsageAPI.fetchWithOwnToken() {
    return UsageEntry(date: Date(), rows: data.rows, updated: Date())
}
if let fetched = try? await CloudUsage.fetch() { /* iCloud fallback */ }
```

**Token lifecycle** — `validToken()` refreshes silently when less than 300 s from expiry; on a server-side `authentication_error` the fetch layer forces one refresh and retries once:

```swift
do { return try await fetch(token: ClaudeOAuth.validToken()) }
catch UsageAPIError.unauthorized { return try await fetch(token: ClaudeOAuth.validToken(force: true)) }
```

The Mac fetcher falls back to the legacy Claude Code-item read only when the user has not signed in, so the menu bar keeps working pre-login.

## Verification

Release builds succeeded for both platforms (`** BUILD SUCCEEDED **` macOS and iOS). The Mac app was installed to `/Applications`, confirmed running with the new binary (process start time checked; installed binary contains the sign-in strings), and the popover shows the "Sign in with Claude…" button; the iOS app installed to the iPhone with the sign-in sheet live. Commits `Add Sign in with Claude…` and `5d21c52` (iPhone standalone) were pushed. Honest caveat: the final end-to-end step — completing the browser authorization and observing a fetch on the app-owned token — is performed by the user and had not yet been observed at documentation time; the pre-login fallback path keeps the app functional until then.

## Prevention

- **Never build a product feature on reading another app's keychain item.** macOS enforces keychain ACLs per accessing binary; the consent dialog for `Claude Code-credentials` was structural, not a bug to be dismissed. Any app whose core loop depends on a cross-app `SecItemCopyMatching` will prompt again whenever the binary changes — which is exactly what happened across our rebuild cycles.
- **During active development, "Always Allow" is close to useless.** Each rebuild-reinstall (CloudKit entitlement fix, rate-limit backoff, menu bar icon, OAuth refactor — all within two days) presented a fresh binary to the ACL check. If a feature needs credentials during a rapid-iteration phase, design for token ownership from the start rather than expecting the user to re-approve per build.
- **Follow the credential-access ladder on macOS.** Prefer, in order: (1) the app's own OAuth grant stored in an item it owns — silent forever, survives rebuilds; (2) a user-supplied API key pasted once into the app; (3) shelling out to already-blessed `/usr/bin/security` — a stable Apple binary that inherits the user's standing approval (our interim fix); (4) direct cross-app SecItem read — last resort, prompt-prone. We climbed this ladder in reverse before landing on (1).
- **iOS cannot reuse a macOS loopback OAuth flow.** The Mac app catches the redirect on an `NWListener` at `localhost:54545`; on iOS the app suspends the moment Safari comes frontmost, so nobody is listening. Use the console "copy the code" paste flow (what Claude Code itself does on headless machines) or a claimed universal link. Decide this per-platform before writing the shared core.
- **Decide widget keychain semantics up front.** The iOS widget could only fetch during Always-On/locked refreshes because the token item was saved with `kSecAttrAccessibleAfterFirstUnlock` and a shared `keychain-access-groups` entitlement on both app and widget targets. Retrofitting either means a re-save of the credential and a provisioning change — cheap on day one, annoying later.
- **Keep a fallback data path through any auth migration.** The fetcher fell back to the legacy token read when not signed in, and the iOS side fell back to the Mac-published CloudKit record when a direct fetch failed. The product never went blank while auth was being rebuilt — migrations should degrade, not gate.

## Testing / verification checklist

After touching `ClaudeOAuth`, `ClaudeAuth`, `UsageAPI`, or the entitlements:

- [ ] Both platforms build: `xcodebuild … -scheme ClaudeUsage` and `-scheme ClaudeUsageiOS -destination 'generic/platform=iOS'` with `-allowProvisioningUpdates`.
- [ ] Mac sign-in end to end: "Sign in with Claude…" opens the browser, approval redirects to `localhost:54545`, the "✳︎ Signed in" page renders, popover flips to "✓ Signed in with Claude".
- [ ] iOS paste flow: Step 1 opens claude.ai, pasted `code#state` exchanges successfully; a code from a *previous* attempt (mismatched state) is rejected with the "different sign-in attempt" message, not a confusing server error.
- [ ] Token refresh: with an access token within 5 minutes of `expiresAt` (or using `force: true`), a fetch triggers a silent refresh and the keychain item is rewritten — verify no user-visible error and a new `expiresAt`.
- [ ] Auth-rejection retry: a 401/`authentication_error` from the usage endpoint produces exactly one forced refresh + retry, not a loop.
- [ ] Widget while locked: with the phone locked (AOD/StandBy), the widget timeline still updates — proves `kSecAttrAccessibleAfterFirstUnlock` + access group are intact.
- [ ] Fallbacks: signed out on Mac → legacy token read still fetches; signed out on iOS → widget and app fall back to the CloudKit record with "Updated on Mac" wording.
- [ ] Zero keychain consent dialogs appear at any point above — one appearing anywhere is a regression.

## Related

- Same project, adjacent lesson (not yet documented): CloudKit `CKError 15/2000 "Server Rejected Request"` required both the `com.apple.developer.icloud-container-environment` entitlement and a first-open activation of the container in the CloudKit Console.
- Key commits: "Add Sign in with Claude: app-owned OAuth token, no more keychain prompts", `5d21c52` "iPhone standalone: Sign in with Claude on iOS, widget fetches directly".
