import SwiftUI
import UIKit

struct DebugLogsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var logger = AppLogger.shared
    @State private var enabledChips: Set<LogCategory> = Set(LogCategory.allCases)

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var displayEntries: [LogEntry] {
        logger.entries.filter { enabledChips.contains($0.category) }
    }

    var body: some View {
        VStack(spacing: 0) {
            chipsBar
            scrollList
        }
        .navigationTitle("Debug Logs")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var chipsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LogCategory.allCases, id: \.self) { cat in
                    chip(for: cat)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func chip(for cat: LogCategory) -> some View {
        let on = enabledChips.contains(cat)
        return Button {
            if on { enabledChips.remove(cat) }
            else  { enabledChips.insert(cat) }
        } label: {
            Text(cat.displayName)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(on ? theme.primary : Color.gray.opacity(0.2))
                .foregroundColor(on ? .white : theme.textSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var scrollList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(displayEntries) { entry in
                        entryRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: displayEntries.count) { _, _ in
                if let lastId = displayEntries.last?.id {
                    DispatchQueue.main.async {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
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
