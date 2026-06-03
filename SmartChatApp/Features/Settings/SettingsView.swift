import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @StateObject private var config = ConfigurationManager.shared
    @State private var showConnectionSheet = false
    @State private var isOperatorConnected = false
    @State private var isNodeConnected = false
    @State private var nodeConnectionError: String? = nil
    @State private var connectedDeviceName = ""

    private static let buildDate: Date = {
        return Date()
    }()

    private var buildDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Self.buildDate)
    }

    private var openClawVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section("Gateway") {
                HStack {
                    Text("Gateway")
                    Spacer()
                    Text(config.isConfigured ? config.displayURL : "Not configured")
                        .foregroundColor(config.isConfigured ? theme.textSecondary : .gray)
                        .lineLimit(1)
                }

                if config.gatewayRole == .operatorAndNode || config.gatewayRole == .operatorOnly {
                HStack {
                    Text("Operator Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isOperatorConnected ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(isOperatorConnected ? "Connected" : "Disconnected")
                            .foregroundColor(isOperatorConnected ? theme.primary : theme.textSecondary)
                    }
                }
                }

                if config.gatewayRole == .operatorAndNode || config.gatewayRole == .nodeOnly {
                HStack {
                    Text("Node Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isNodeConnected ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(isNodeConnected ? "Connected" : "Disconnected")
                            .foregroundColor(isNodeConnected ? theme.primary : theme.textSecondary)
                    }
                }

                if let error = nodeConnectionError, !isNodeConnected {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                }

                HStack {
                    Text("Role")
                    Spacer()
                    Text(config.gatewayRole.rawValue)
                        .foregroundColor(theme.textSecondary)
                }

                if isOperatorConnected {
                    HStack {
                        Text("Device ID")
                        Spacer()
                        Text(String(connectedDeviceName.prefix(16)))
                            .foregroundColor(theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                HStack {
                    Text("OpenClaw SDK Version")
                    Spacer()
                    Text(openClawVersion)
                        .foregroundColor(theme.textSecondary)
                }

                Toggle("Auto-connect on launch", isOn: $config.autoConnectOnLaunch)

                Button("Configure Connection") {
                    showConnectionSheet = true
                }
                .foregroundColor(theme.primary)

                DisclosureGroup("Advanced") {
                    Toggle("Gateway Debug Logs", isOn: $config.gatewayDebugLogs)
                        .onChange(of: config.gatewayDebugLogs) { _, newValue in
                            Task {
                                await SessionManager.shared.setDebugLoggingEnabled(newValue)
                            }
                        }
                    Toggle("Discovery Debug Logs", isOn: $config.discoveryDebugLogs)
                        .onChange(of: config.discoveryDebugLogs) { _, newValue in
                            Task {
                                await SessionManager.shared.setDiscoveryDebugLoggingEnabled(newValue)
                            }
                        }
                    NavigationLink("Discovery Logs") {
                        DiscoveryLogsView()
                    }
                }
            }

            Section("Device") {
                HStack {
                    Text("Name")
                    Spacer()
                    TextField("Device Name", text: $config.deviceDisplayName)
                        .multilineTextAlignment(.trailing)
                        .foregroundColor(theme.textSecondary)
                }

                HStack {
                    Text("Device ID")
                    Spacer()
                    Text(connectedDeviceName.isEmpty ? "—" : String(connectedDeviceName.prefix(16)))
                        .foregroundColor(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $config.appearanceTheme) {
                    ForEach(AppearanceTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(theme.textSecondary)
                }

                HStack {
                    Text("Build")
                    Spacer()
                    Text(buildDateString)
                        .foregroundColor(theme.textSecondary)
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showConnectionSheet) {
            ConnectionConfigSheet(onStatusChange: { [self] connected, deviceName in
                isOperatorConnected = connected
                connectedDeviceName = deviceName
                Task {
                    let nodeStatus = await SessionManager.shared.nodeConnectionStatus
                    let nodeError = await SessionManager.shared.nodeConnectionErrorMessage
                    await MainActor.run {
                        isNodeConnected = nodeStatus
                        nodeConnectionError = nodeError
                    }
                }
            })
        }
        .task {
            await checkConnection()
            await SessionManager.shared.setDebugLoggingEnabled(config.gatewayDebugLogs)
            await SessionManager.shared.setDiscoveryDebugLoggingEnabled(config.discoveryDebugLogs)
        }
    }

    private func checkConnection() async {
        let operatorConnected = await SessionManager.shared.operatorConnectionStatus
        let nodeConnected = await SessionManager.shared.nodeConnectionStatus
        let nodeError = await SessionManager.shared.nodeConnectionErrorMessage
        let deviceName = await SessionManager.shared.deviceName ?? ""
        await MainActor.run {
            isOperatorConnected = operatorConnected
            isNodeConnected = nodeConnected
            nodeConnectionError = nodeError
            connectedDeviceName = deviceName
        }
    }
}

struct ConnectionConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @StateObject private var config = ConfigurationManager.shared
    @State private var serverHost: String = ""
    @State private var serverPort: String = ""
    @State private var useTLS: Bool = true
    @State private var authToken: String = ""
    @State private var isTesting: Bool = false
    @State private var isConnected: Bool = false
    @State private var testResult: String?
    @State private var testStatus: TestStatus = .idle
    @State private var connectedDeviceName: String = ""

    var onStatusChange: ((Bool, String) -> Void)?

    enum TestStatus {
        case idle, testing, success, failure
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Gateway Configuration") {
                    TextField("Host (e.g., api.openclaw.ai)", text: $serverHost)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    TextField("Port", text: $serverPort)
                        .keyboardType(.numberPad)

                    Toggle("Use TLS/SSL", isOn: $useTLS)

                    Picker("Role", selection: $config.gatewayRole) {
                        ForEach(GatewayConnectionRole.allCases, id: \.self) { role in
                            Text(role.rawValue).tag(role)
                        }
                    }
                }

                Section("Authentication") {
                    SecureField("Auth Token", text: $authToken)
                        .textContentType(.password)
                }

                Section {
                    HStack {
                        Button(action: isConnected ? disconnectConnection : testConnection) {
                            HStack {
                                Spacer()
                                if isTesting {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                    Text("Connecting...")
                                } else if isConnected {
                                    Image(systemName: "link.badge.plus")
                                    Text("Disconnect")
                                        .foregroundColor(.red)
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                    Text("Connect")
                                }
                                Spacer()
                            }
                        }
                        .disabled(serverHost.isEmpty || authToken.isEmpty || isTesting)

                        if let result = testResult {
                            HStack(spacing: 4) {
                                Image(systemName: testStatus == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                Text(result)
                            }
                            .font(.subheadline)
                            .foregroundColor(testStatus == .success ? .green : .red)
                            .padding(.leading, 8)
                        }
                    }
                }

                Section {
                    Button("Clear Configuration") {
                        Task {
                            await SessionManager.shared.disconnect()
                            await MainActor.run {
                                config.clear()
                                serverHost = ""
                                serverPort = ""
                                useTLS = true
                                authToken = ""
                                testResult = nil
                                isConnected = false
                                connectedDeviceName = ""
                                onStatusChange?(false, "")
                            }
                        }
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Connection Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        config.gatewayHost = serverHost
                        config.gatewayPort = Int(serverPort) ?? 443
                        config.gatewayUseTLS = useTLS
                        config.authToken = authToken
                        onStatusChange?(isConnected, connectedDeviceName)
                        dismiss()
                    }
                }
            }
            .onAppear {
                serverHost = config.gatewayHost
                serverPort = config.gatewayPort > 0 ? String(config.gatewayPort) : "443"
                useTLS = config.gatewayUseTLS
                authToken = config.authToken

                Task {
                    let connected = await SessionManager.shared.connectionStatus
                    let deviceName = await SessionManager.shared.deviceName ?? ""
                    await MainActor.run {
                        isConnected = connected
                        connectedDeviceName = deviceName
                    }
                }
            }
        }
    }

    private func testConnection() {
        guard !serverHost.isEmpty else { return }

        isTesting = true
        testResult = nil
        testStatus = .testing
        connectedDeviceName = ""

        let port = Int(serverPort) ?? 443
        let scheme = useTLS ? "wss" : "ws"
        let urlString = "\(scheme)://\(serverHost):\(port)/gateway"

        guard let url = URL(string: urlString) else {
            isTesting = false
            testStatus = .failure
            testResult = "Invalid URL"
            return
        }

        print("[ConnectionConfigSheet] Connecting to: \(urlString)")

        Task {
            do {
                let manager = SessionManager.shared
                try await manager.connectWithRole(gatewayURL: url, authToken: authToken, role: config.gatewayRole)
                let deviceName = await manager.deviceName ?? "unknown"

                await MainActor.run {
                    connectedDeviceName = deviceName
                    isTesting = false
                    testStatus = .success
                    testResult = "Connected"
                    isConnected = true
                }

                print("[ConnectionConfigSheet] Connected, deviceName: \(deviceName)")
                onStatusChange?(true, deviceName)

            } catch {
                print("[ConnectionConfigSheet] Connection error: \(error)")
                await MainActor.run {
                    isTesting = false
                    testStatus = .failure
                    testResult = "Connection failed: \(error.localizedDescription)"
                    isConnected = false
                }
                onStatusChange?(false, "")
            }
        }
    }

    private func disconnectConnection() {
        Task {
            await SessionManager.shared.disconnect()
            await MainActor.run {
                isConnected = false
                connectedDeviceName = ""
                testResult = "Disconnected"
                testStatus = .idle
                onStatusChange?(false, "")
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .preferredColorScheme(.dark)
}
