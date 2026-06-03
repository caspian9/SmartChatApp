import SwiftUI

@main
struct SmartChatAppApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ChatListView()
            }
            .preferredColorScheme(.dark)
        }
    }
}