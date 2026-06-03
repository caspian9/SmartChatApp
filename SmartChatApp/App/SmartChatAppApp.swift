import SwiftUI
import ComposableArchitecture

@main
struct SmartChatAppApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ChatListView(
                    store: Store(
                        initialState: ChatListFeature.State(),
                        reducer: { ChatListFeature() }
                    )
                )
            }
            .preferredColorScheme(.dark)
        }
    }
}
