# ClaudeUsage

Native macOS menu bar app + desktop widget showing your Claude Code rate-limit usage.

- **Menu bar**: live `21% 3h39m` (usage % + time until reset), refreshed every 60s
- **Popover**: all buckets — 5-hour, 7-day, and model-scoped weekly limits — with capacity bars and reset countdowns
- **Widget**: small (ring gauge) and medium (all buckets), for the desktop or Notification Center
- No Electron, no dependencies — a single small Swift app

## Requirements

- macOS 14+
- [Claude Code](https://claude.com/claude-code) logged in with a subscription (OAuth). The app reads your own OAuth token from the macOS Keychain — API-key-only setups won't work.

## Install

1. Download `ClaudeUsage-x.y.zip` from Releases, unzip, drag `ClaudeUsage.app` into `/Applications`
2. First launch is blocked by Gatekeeper (the app isn't notarized). Either:
   - System Settings › Privacy & Security → scroll down → **Open Anyway**, or
   - `xattr -dr com.apple.quarantine /Applications/ClaudeUsage.app`
3. On first refresh, macOS asks for Keychain access to `Claude Code-credentials` → enter your login password → **Always Allow**
4. Optional: right-click the desktop → *Edit Widgets* → add **Claude Usage**
5. Optional: enable *Launch at login* in the popover

## Build from source

Needs Xcode 15+ and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`):

```bash
xcodegen generate
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage -configuration Release -derivedDataPath build build
ditto build/Build/Products/Release/ClaudeUsage.app /Applications/ClaudeUsage.app
```

Set your own `DEVELOPMENT_TEAM` in `project.yml` (or pick your team in Xcode's Signing settings).

## How it works

- Reads the Claude Code OAuth token from the login Keychain (service `Claude Code-credentials`) and calls `https://api.anthropic.com/api/oauth/usage`
- Caches responses in `~/.claude/.usage-cache.json` — the same file (and format) used by companion SwiftBar/VS Code scripts, so all consumers share one cache and stay within rate limits
- The widget extension is sandboxed; it reads the shared cache via a home-relative read-only sandbox exception for `~/.claude/`, so it needs no App Group and shows data even when only other tools refreshed the cache
- The app pokes WidgetKit to reload timelines only when displayed values change, staying inside the widget refresh budget
