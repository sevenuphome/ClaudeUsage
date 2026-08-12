import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "asterisk")
                Text(state.title)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
