import Foundation

public enum SlashCommandResult: Sendable, Equatable {
    case bubble(String)
    case clearAndBubble(String)
    case silent
}
