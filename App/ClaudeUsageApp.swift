import SwiftUI

@main
struct ClaudeUsageApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            Text(state.title)
        }
        .menuBarExtraStyle(.window)
    }
}
