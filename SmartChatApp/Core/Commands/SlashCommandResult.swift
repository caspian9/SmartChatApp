import Foundation

public enum SlashCommandResult: Sendable {
    case bubble(String)
    case clearAndBubble(String)
    case silent
}
