import SwiftUI
import ComposableArchitecture

struct HomeView: View {
    @State private var showChatList = false
    @State private var showNativeChat = false

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            HStack(spacing: 20) {
                EntryCard(
                    title: "Native Chat",
                    icon: "bubble.left.and.bubble.right",
                    action: {
                        showNativeChat = true
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
        .navigationDestination(isPresented: $showNativeChat) {
            NativeChatView(
                store: StoreOf<NativeChatViewModel>(initialState: NativeChatViewModel.State()) {
                    NativeChatViewModel()
                }
            )
        }
    }
}
