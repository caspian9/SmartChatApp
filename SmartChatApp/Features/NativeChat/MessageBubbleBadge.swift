import Foundation
import SwiftUI

/// One source of truth for which metadata chip a bubble should show
/// in its trailing HStack (issue #33). The previous code had three
/// hardcoded `if message.role == "..."` blocks in `MessageBubbleView`
/// (lines 66-94); centralizing the decision here lets the full
/// matrix be covered by XCTest without rendering SwiftUI.
///
/// `CaseIterable` so tests can iterate every case and assert no
/// two roles map to the same badge (catches future regressions
/// when new roles are added).
enum MessageBubbleBadge: Equatable, CaseIterable {
    case none
    case toolResult
    case thinking
    case toolCall
    case assistant
    case slashCommand
}

enum MessageBubbleBadgeResolver {
    /// Maps a `ChatMessage`'s `role` (and for `assistant`, its `state`)
    /// to the chip the trailing metadata row should render.
    ///
    /// - `role == "toolResult"`: ToolResult chip (purple).
    /// - `role == "thinking"`: Thinking chip (blue).
    /// - `role == "toolCall"`: ToolCall chip (orange).
    /// - `role == "system"`: SlashCommand chip (info blue). Slash
    ///   command results land in the cache as `role: "system"`
    ///   (`NativeChatViewModel.appendSystemBubble`), so this is
    ///   the natural badge slot for them.
    /// - `role == "assistant"` AND `state == "final"`: Assistant
    ///   chip (primary green). Streaming assistant bubbles have
    ///   `state == "streaming"`; the typing indicator is the
    ///   indicator, no badge needed.
    /// - All others (`user`, empty, unknown): no chip.
    static func badge(for message: ChatMessage) -> MessageBubbleBadge {
        switch message.role {
        case "toolResult": return .toolResult
        case "thinking": return .thinking
        case "toolCall": return .toolCall
        case "system": return .slashCommand
        case "assistant":
            return message.state == "final" ? .assistant : .none
        default: return .none
        }
    }
}

extension MessageBubbleBadge {
    /// Human-readable chip label rendered inside the trailing
    /// metadata HStack. Keep these short (the chip is ~6pt
    /// horizontal padding) so the label + padding don't exceed
    /// the metadata row's width budget.
    var label: String {
        // `slashCommand` renders as "Slash" (not "SlashCommand") —
        // the longer label pushes the chip past the 6pt padding
        // budget on narrow rows. The case name keeps the
        // descriptive form for code-level references.
        switch self {
        case .none: return ""
        case .toolResult: return "ToolResult"
        case .thinking: return "Thinking"
        case .toolCall: return "ToolCall"
        case .assistant: return "Assistant"
        case .slashCommand: return "Slash"
        }
    }

    /// Background fill for the chip. Pre-existing colors
    /// (toolResult / thinking / toolCall) stay hardcoded
    /// per plan B.5 — only the two NEW badges
    /// (assistant / slashCommand) go through the theme.
    /// `Theme` is in the same target so no extra import
    /// is needed beyond `import SwiftUI` above.
    func backgroundColor(theme: Theme) -> Color {
        switch self {
        case .none: return .clear
        case .toolResult: return .purple
        case .thinking: return .blue
        case .toolCall: return .orange
        case .assistant: return theme.badgeAssistant
        case .slashCommand: return theme.badgeSlashCommand
        }
    }
}