import SwiftUI

struct HomeView: View {
    @State private var showChatList = false

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            HStack(spacing: 20) {
                EntryCard(
                    title: "Native Chat",
                    icon: "bubble.left.and.bubble.right",
                    action: {
                        // TODO: Navigate to NativeChatView
                    }
                )

                EntryCard(
                    title: "Chat List",
                    icon: "list.bullet",
                    action: {
                        showChatList = true
                    }
                )
            }

            Spacer()

            DeviceInfoView()
        }
        .padding()
        .background(Color.black)
        .navigationTitle("SmartChatApp")
        .navigationDestination(isPresented: $showChatList) {
            ChatListView()
        }
    }
}
