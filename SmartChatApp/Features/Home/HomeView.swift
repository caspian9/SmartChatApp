import SwiftUI
import ComposableArchitecture

struct HomeView: View {
    @State private var showChatList = false
    @State private var showNativeChat = false
    @State private var showSettings = false
    @State private var isConnected = false
    @State private var connectedDeviceName = ""
    @State private var gatewayHost = ""

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Spacer()
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                        .font(.title2)
                        .foregroundColor(Color(hex: "10A37F"))
                }
            }
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                if isConnected {
                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("Connected to OpenClaw")
                                .font(.caption)
                                .foregroundColor(.white)
                        }

                        VStack(spacing: 2) {
                            Text(connectedDeviceName)
                                .font(.caption2)
                                .foregroundColor(Color(hex: "10A37F"))

                            Text(gatewayHost)
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(Color(hex: "1E1E1E"))
                    .cornerRadius(8)
                }

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
        .navigationDestination(isPresented: $showSettings) {
            SettingsView()
        }
        .task {
            await checkConnectionStatus()
        }
    }

    private func checkConnectionStatus() async {
        let connected = await SessionManager.shared.connectionStatus
        let deviceName = await SessionManager.shared.deviceName ?? ""
        let config = ConfigurationManager.shared

        await MainActor.run {
            isConnected = connected
            connectedDeviceName = deviceName
            gatewayHost = config.displayURL
        }

        print("[HomeView] Connection check: connected=\(connected), device=\(deviceName), gateway=\(config.displayURL)")
    }
}