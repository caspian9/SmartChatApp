import SwiftUI

@main
struct SmartChatAppApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                HomeView()
            }
            .preferredColorScheme(.dark)
        }
    }
}