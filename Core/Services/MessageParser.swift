import Foundation

actor MessageParser {
    func parseMarkdown(_ text: String) -> String {
        return text
    }

    func extractToolCalls(from content: String) -> [ToolCall] {
        return []
    }

    func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
