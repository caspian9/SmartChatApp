import Foundation
import OpenClawKit

enum MessageFormatters {
    /// Builds a short human-readable label for a tool call: "name: args".
    /// Falls back to a one-line JSON dump of args so the bubble has something
    /// to show even when no friendly field is present.
    static func formatToolCallText(name: String, args: Any?) -> String {
        if name.isEmpty { return "" }
        guard let args else { return name }
        if let str = args as? String, !str.isEmpty {
            return "\(name): \(str)"
        }
        if let dict = args as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.fragmentsAllowed, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return "\(name): \(json)"
            }
        }
        if let arr = args as? [Any] {
            if let data = try? JSONSerialization.data(withJSONObject: arr, options: [.fragmentsAllowed, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                return "\(name): \(json)"
            }
        }
        return name
    }

    /// Pretty-prints a tool result payload. JSON values get indented; raw
    /// strings pass through. The MessageBubbleView will further pretty-print
    /// anything it sees for `role == "toolResult"`, so this stays minimal.
    static func formatToolResultText(result: Any?) -> String {
        guard let result else { return "" }
        if let str = result as? String { return str }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .fragmentsAllowed, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return String(describing: result)
    }
}

extension MessageFormatters {
    static func formatAnyCodableValue(_ value: Any) -> String {
        if let str = value as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "" }
            let first = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
            if first.count > 160 { return String(first.prefix(157)) + "…" }
            return first
        }
        if let num = value as? Int { return String(num) }
        if let num = value as? Double { return String(num) }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        if let array = value as? [Any] {
            let items = array.compactMap { MessageFormatters.formatAnyCodableValue($0) }
            guard !items.isEmpty else { return "" }
            let preview = items.prefix(3).joined(separator: ", ")
            return items.count > 3 ? "\(preview)…" : preview
        }
        if let dict = value as? [String: Any] {
            let keys = ["name", "id", "command", "action", "path", "node", "nodeId"]
            for key in keys {
                if let label = dict[key] {
                    let str = MessageFormatters.formatAnyCodableValue(label)
                    if !str.isEmpty { return str }
                }
            }
        }
        if let dict = value as? [String: AnyCodable] {
            let keys = ["name", "id", "command", "action", "path", "node", "nodeId"]
            for key in keys {
                if let anyCodable = dict[key] {
                    let formatted = MessageFormatters.formatAnyCodableValue(anyCodable.value)
                    if !formatted.isEmpty { return formatted }
                }
            }
            // Generic scan for first non-empty string value
            for (_, anyCodable) in dict {
                let formatted = MessageFormatters.formatAnyCodableValue(anyCodable.value)
                if !formatted.isEmpty {
                    return formatted
                }
            }
        }
        return ""
    }

    /// Renders a toolCall bubble's text. Three forms depending on what's available:
    /// ```
    /// // 1. history / legacy verbose=on — full key: value list from args
    /// ToolCall: <name>
    /// command: <cmd>
    /// timeout: <timeout>
    ///
    /// // 2. modern `item` event with meta — second line shows the action summary
    /// ToolCall: <name>
    /// with: <meta>
    ///
    /// // 3. modern `item` event without meta — name only
    /// ToolCall: <name>
    /// ```
    static func formatToolCallBubbleText(name: String, arguments: AnyCodable?, meta: String? = nil) -> String {
        guard !name.isEmpty else { return "" }
        var callText = "ToolCall: \(name)"
        if let arguments {
            var argsLines: [String] = []
            let appendArgLine: (String, Any) -> Void = { key, value in
                let valueStr: String
                if key == "command", let str = value as? String {
                    valueStr = str
                } else {
                    valueStr = MessageFormatters.formatAnyCodableValue(value)
                }
                if !valueStr.isEmpty {
                    argsLines.append("\(key): \(valueStr)")
                }
            }
            if let dict = arguments.value as? [String: AnyCodable] {
                for (key, anyCodable) in dict {
                    appendArgLine(key, anyCodable.value)
                }
            } else if let dict = arguments.value as? [String: Any] {
                for (key, value) in dict {
                    appendArgLine(key, value)
                }
            }
            if !argsLines.isEmpty {
                callText += "\n" + argsLines.joined(separator: "\n")
                return callText
            }
        }
        if let meta, !meta.isEmpty {
            callText += "\nwith: \(meta)"
        }
        return callText
    }
}
