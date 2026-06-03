import SwiftUI
import ComposableArchitecture

struct HomeView: View {
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showChatList = false
    @State private var showNativeChat = false
    @State private var showSettings = false
    @State private var isConnected = false
    @State private var connectedDeviceName = ""
    @State private var gatewayHost = ""

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Connection status banner
                connectionBanner

                // Main entry cards grid
                if isCompact {
                    // iPhone portrait: 2x2 grid
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16)
                    ], spacing: 16) {
                        EntryCard(
                            title: "Native Chat",
                            icon: "bubble.left.and.bubble.right",
                            action: { showNativeChat = true }
                        )

                        EntryCard(
                            title: "Chat List",
                            icon: "list.bullet",
                            action: { showChatList = true }
                        )

                        EntryCard(
                            title: "Settings",
                            icon: "gear",
                            action: { showSettings = true }
                        )
                    }
                } else {
                    // iPad: horizontal row
                    HStack(spacing: 20) {
                        EntryCard(
                            title: "Native Chat",
                            icon: "bubble.left.and.bubble.right",
                            action: { showNativeChat = true }
                        )

                        EntryCard(
                            title: "Chat List",
                            icon: "list.bullet",
                            action: { showChatList = true }
                        )

                        EntryCard(
                            title: "Settings",
                            icon: "gear",
                            action: { showSettings = true }
                        )
                    }
                }
            }
            .padding(24)
        }
        .background(theme.background)
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

    @ViewBuilder
    private var connectionBanner: some View {
        if isConnected {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected to OpenClaw")
                        .font(.subheadline)
                        .foregroundColor(theme.textPrimary)

                    Text("\(connectedDeviceName) • \(gatewayHost)")
                        .font(.caption)
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()
            }
            .padding(16)
            .background(theme.cardBackground)
            .cornerRadius(12)
        } else if ConfigurationManager.shared.isConfigured {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.yellow)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connecting...")
                        .font(.subheadline)
                        .foregroundColor(theme.textPrimary)

                    Text(gatewayHost)
                        .font(.caption)
                        .foregroundColor(theme.textSecondary)
                }

                Spacer()
            }
            .padding(16)
            .background(theme.cardBackground)
            .cornerRadius(12)
        }
    }

    private func checkConnectionStatus() async {
        let config = ConfigurationManager.shared

        guard config.isConfigured else {
            await MainActor.run {
                isConnected = false
                connectedDeviceName = ""
                gatewayHost = ""
            }
            return
        }

        await MainActor.run {
            isConnected = false
            connectedDeviceName = ""
            gatewayHost = config.displayURL
        }

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