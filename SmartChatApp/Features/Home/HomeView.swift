import SwiftUI

struct HomeView: View {
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
                        // Navigation handled by NavigationLink in wrapped view
                    }
                )
            }

            Spacer()

            DeviceInfoView()
        }
        .padding()
        .background(Color.black)
        .navigationTitle("SmartChatApp")
    }
}
