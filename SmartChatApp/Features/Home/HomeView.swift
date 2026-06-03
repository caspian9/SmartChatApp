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
                } else if ConfigurationManager.shared.isConfigured {
                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.yellow)
                                .frame(width: 8, height: 8)
                            Text("Connecting...")
                                .font(.caption)
                                .foregroundColor(.white)
                        }

                        Text(gatewayHost)
                            .font(.caption2)
                            .foregroundColor(.gray)
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
            NativeChatView()
        }
        .navigationDestination(isPresented: $showSettings) {
            SettingsView()
        }
        .task {
            await checkConnectionStatus()
        }
    }

    private func checkConnectionStatus() async {
        let config = ConfigurationManager.shared

        // If not configured, just show disconnected state
        guard config.isConfigured else {
            await MainActor.run {
                isConnected = false
                connectedDeviceName = ""
                gatewayHost = ""
            }
            return
        }

        // Show connecting state
        await MainActor.run {
            isConnected = false
            connectedDeviceName = ""
            gatewayHost = config.displayURL
        }

        // Try to connect
        do {
            try await SessionManager.shared.ensureConnected()
            let connected = await SessionManager.shared.connectionStatus
            let deviceName = await SessionManager.shared.deviceName ?? ""

            await MainActor.run {
                isConnected = connected
                connectedDeviceName = deviceName
                gatewayHost = config.displayURL
            }
        } catch {
            await MainActor.run {
                isConnected = false
                connectedDeviceName = ""
                gatewayHost = config.displayURL
            }
        }
    }
}