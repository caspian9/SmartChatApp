import SwiftUI
import UIKit

struct DebugLogsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var logger = AppLogger.shared

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(logger.entries) { entry in
                        entryRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: logger.entries.count) { _, _ in
                if let lastId = logger.entries.last?.id {
                    DispatchQueue.main.async {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Debug Logs")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func entryRow(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Self.timeFormatter.string(from: entry.ts))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text("[\(entry.category.displayName)]")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.blue)
            }
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
