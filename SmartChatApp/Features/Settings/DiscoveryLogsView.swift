import SwiftUI
import UIKit

struct DiscoveryLogsView: View {
    @Environment(\.theme) private var theme
    @State private var logEntries: [DebugLogEntry] = []
    @State private var isLoading = true
    @AppStorage("openclaw_discovery_debug") private var debugLogsEnabled = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    var body: some View {
        List {
            if !debugLogsEnabled {
                Text("Enable Discovery Debug Logs to start collecting events.")
                    .foregroundStyle(.secondary)
            }

            if logEntries.isEmpty && debugLogsEnabled {
                Text("No log entries yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(logEntries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.formatTime(entry.ts))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Discovery Logs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Copy") {
                    UIPasteboard.general.string = formattedLog()
                }
                .disabled(logEntries.isEmpty)
            }
        }
        .task {
            await loadLogs()
        }
    }

    private func loadLogs() async {
        let entries = await SessionManager.shared.getDebugLogs()
        await MainActor.run {
            logEntries = entries
            isLoading = false
        }
    }

    private func formattedLog() -> String {
        logEntries
            .map { "\(Self.formatISO($0.ts)) \($0.message)" }
            .joined(separator: "\n")
    }

    private static func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    private static func formatISO(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }
}

#Preview {
    NavigationStack {
        DiscoveryLogsView()
    }
    .preferredColorScheme(.dark)
}
