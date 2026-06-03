import SwiftUI
import UIKit

struct SettingsView: View {
    @StateObject private var config = ConfigurationManager.shared
    @State private var showConnectionSheet = false
    @State private var isConnected = false
    @State private var connectedDeviceName = ""

    private static let buildDate: Date = {
        // Capture build time at app launch - this becomes the static constant
        return Date()
    }()

    private var buildDateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Self.buildDate)
    }

    var body: some View {
        Form {
            Section("OpenClaw Gateway") {
                HStack {
                    Text("Gateway")
                    Spacer()
                    Text(config.isConfigured ? config.displayURL : "Not configured")
                        .foregroundColor(config.isConfigured ? .secondary : .gray)
                        .lineLimit(1)
                }

                HStack {
                    Text("Status")
                    Spacer()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isConnected ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(isConnected ? "Connected" : "Disconnected")
                            .foregroundColor(isConnected ? Color(hex: "10A37F") : .gray)
                    }
                }

                if isConnected {
                    HStack {
                        Text("Device ID")
                        Spacer()
                        Text(connectedDeviceName)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Button("Configure Connection") {
                    showConnectionSheet = true
                }
                .foregroundColor(Color(hex: "10A37F"))
            }

            Section("Appearance") {
                Toggle("Dark Mode", isOn: .constant(true))
                    .disabled(true)
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.gray)
                }

                HStack {
                    Text("Build")
                    Spacer()
                    Text(buildDateString)
                        .foregroundColor(.gray)
                }
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showConnectionSheet) {
            ConnectionConfigSheet(onStatusChange: { connected, deviceName in
                isConnected = connected
                connectedDeviceName = deviceName
            })
        }
        .task {
            await checkConnection()
        }
    }

    private func checkConnection() async {
        let connected = await SessionManager.shared.connectionStatus
        let deviceName = await SessionManager.shared.deviceName ?? ""
        await MainActor.run {
            isConnected = connected
            connectedDeviceName = deviceName
        }
    }
}

struct ConnectionConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
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
                }

                Section("Authentication") {
                    SecureField("Auth Token", text: $authToken)
                        .textContentType(.password)
                }

                Section {
                    if isConnected {
                        HStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                            Text("Connected: \(connectedDeviceName)")
                                .foregroundColor(Color(hex: "10A37F"))
                        }

                        Button(action: disconnectConnection) {
                            HStack {
                                Spacer()
                                Text("Disconnect")
                                    .foregroundColor(.red)
                                Spacer()
                            }
                        }
                    } else {
                        Button(action: testConnection) {
                            HStack {
                                Spacer()
                                if isTesting {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                    Text("Connecting...")
                                } else {
                                    Text("Connect")
                                }
                                Spacer()
                            }
                        }
                        .disabled(serverHost.isEmpty || authToken.isEmpty || isTesting)
                    }

                    if let result = testResult {
                        HStack {
                            Image(systemName: testStatus == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(testStatus == .success ? Color(hex: "10A37F") : .red)
                            Text(result)
                                .foregroundColor(testStatus == .success ? Color(hex: "10A37F") : .red)
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
                        // Save config before dismissing
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

                // Check current connection status
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
                try await manager.connect(gatewayURL: url, authToken: authToken)
                let deviceName = await manager.deviceName ?? "unknown"

                await MainActor.run {
                    connectedDeviceName = deviceName
                    isTesting = false
                    testStatus = .success
                    testResult = "Connected successfully!"
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