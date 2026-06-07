import SwiftUI

struct HomeView: View {
    @Environment(\.theme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showChatList = false
    @State private var showNativeChat = false
    @State private var showSettings = false
    @Bindable private var connectionState = ConnectionState.shared

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    private var hasProfile: Bool {
        ProfileManager.shared.activeProfile != nil
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
        .task { }
    }

    @ViewBuilder
    private var connectionBanner: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(bannerColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(bannerTitle)
                    .font(.subheadline)
                    .foregroundColor(theme.textPrimary)

                Text(bannerSubtitle)
                    .font(.caption)
                    .foregroundColor(theme.textSecondary)
            }

            Spacer()
        }
        .padding(16)
        .background(theme.cardBackground)
        .cornerRadius(12)
    }

    private var bannerColor: Color {
        switch connectionState.phase {
        case .connected:
            return .green
        case .connecting, .reconnecting:
            return .yellow
        case .disconnected:
            return .gray
        }
    }

    private var bannerTitle: String {
        switch connectionState.phase {
        case .connected:
            return "Connected to OpenClaw"
        case .connecting:
            return "Connecting..."
        case .reconnecting:
            return "Reconnecting..."
        case .disconnected:
            return hasProfile ? "Not connected" : ""
        }
    }

    private var bannerSubtitle: String {
        let device = connectionState.connectedDeviceName ?? ""
        let host = ProfileManager.shared.activeProfile?.host ?? ""
        switch connectionState.phase {
        case .connected:
            return "\(device) • \(host)"
        default:
            return host
        }
    }
}
