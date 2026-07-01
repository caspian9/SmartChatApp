import XCTest
import SwiftUI
import UIKit
@testable import SmartChatApp

/// Covers the role/state -> badge mapping that drives the
/// trailing metadata chip in `MessageBubbleView`. The badge
/// decision lives in `MessageBubbleBadgeResolver` (file-scope,
/// internal) so the full role matrix is XCTest-coverable
/// without rendering SwiftUI.
final class MessageBubbleBadgeTests: XCTestCase {

    // MARK: - Helpers

    /// Mirror of `ChatMessage`'s canonical initializer. Lifted
    /// from `NativeChatViewModel.swift:651-666` so tests can
    /// construct role-bearing messages without going through
    /// the full VM lifecycle. Field order matches the memberwise
    /// init that `ChatMessage`'s declaration synthesizes — verify
    /// against `MessageBubbleView.swift:555-572` if fields change.
    private func makeMessage(
        role: String,
        state: String = "final",
        text: String = "body"
    ) -> ChatMessage {
        ChatMessage(
            id: UUID().uuidString,
            text: text,
            timestamp: Date(timeIntervalSince1970: 0),
            role: role,
            state: state,
            runId: nil,
            seq: nil,
            startedAt: nil,
            endedAt: nil,
            livenessState: nil,
            inputTokens: nil,
            outputTokens: nil,
            cacheRead: nil,
            cacheWrite: nil,
            toolCallId: nil,
            toolName: nil,
            stopReason: nil,
            isFresh: false
        )
    }

    // MARK: - Role mapping

    func test_role_toolResult_returnsToolResultBadge() {
        let msg = makeMessage(role: "toolResult")
        XCTAssertEqual(
            MessageBubbleBadgeResolver.badge(for: msg),
            .toolResult
        )
    }

    func test_role_thinking_returnsThinkingBadge() {
        let msg = makeMessage(role: "thinking")
        XCTAssertEqual(
            MessageBubbleBadgeResolver.badge(for: msg),
            .thinking
        )
    }

    func test_role_toolCall_returnsToolCallBadge() {
        let msg = makeMessage(role: "toolCall")
        XCTAssertEqual(
            MessageBubbleBadgeResolver.badge(for: msg),
            .toolCall
        )
    }

    func test_role_system_returnsSlashCommandBadge() {
        // Slash-command results are appended with role: "system"
        // via NativeChatViewModel.appendSystemBubble; the
        // dedicated system card at MessageBubbleView.swift:339
        // handles the chrome, and the chip is the badge slot
        // for these.
        let msg = makeMessage(role: "system")
        XCTAssertEqual(
            MessageBubbleBadgeResolver.badge(for: msg),
            .slashCommand
        )
    }

    func test_role_assistant_stateFinal_returnsAssistantBadge() {
        let msg = makeMessage(role: "assistant", state: "final")
        XCTAssertEqual(
            MessageBubbleBadgeResolver.badge(for: msg),
            .assistant
        )
    }

    func test_role_assistant_stateStreaming_returnsNone() {
        // The typing indicator is the indicator; no badge.
        let msg = makeMessage(role: "assistant", state: "streaming")
        XCTAssertEqual(
            MessageBubbleBadgeResolver.badge(for: msg),
            .none
        )
    }

    func test_role_user_returnsNone() {
        // Outgoing user bubbles have no metadata chip.
        let msg = makeMessage(role: "user")
        XCTAssertEqual(
            MessageBubbleBadgeResolver.badge(for: msg),
            .none
        )
    }

    func test_role_empty_returnsNone() {
        let msg = makeMessage(role: "")
        XCTAssertEqual(
            MessageBubbleBadgeResolver.badge(for: msg),
            .none
        )
    }

    func test_role_unknownReturnsNone() {
        let msg = makeMessage(role: "agent-some-other-thing")
        XCTAssertEqual(
            MessageBubbleBadgeResolver.badge(for: msg),
            .none
        )
    }

    // MARK: - Cross-case sanity

    func test_slashCommandBadge_doesNotCollideWithToolResult() {
        // Different role strings map to different badges.
        let system = makeMessage(role: "system")
        let toolResult = makeMessage(role: "toolResult")
        XCTAssertNotEqual(
            MessageBubbleBadgeResolver.badge(for: system),
            MessageBubbleBadgeResolver.badge(for: toolResult)
        )
    }

    func test_allCasesHaveUniqueValues() {
        // Catches future regressions when new roles are added:
        // every badge case must remain distinct so the view's
        // switch is exhaustive and the label/color mapping
        // stays 1:1.
        let all = MessageBubbleBadge.allCases
        XCTAssertEqual(all.count, Set(all).count)
    }

    // MARK: - Label + backgroundColor pinning

    func test_label_isStablePerCase() {
        // Pinned labels so a future refactor doesn't change them
        // without a corresponding test update. The chip's visible
        // text comes from `label`, not the case name — a typo here
        // (e.g. "ToolReslt") would ship silently without these pins.
        XCTAssertEqual(MessageBubbleBadge.none.label, "")
        XCTAssertEqual(MessageBubbleBadge.toolResult.label, "ToolResult")
        XCTAssertEqual(MessageBubbleBadge.thinking.label,   "Thinking")
        XCTAssertEqual(MessageBubbleBadge.toolCall.label,   "ToolCall")
        XCTAssertEqual(MessageBubbleBadge.assistant.label,  "Assistant")
        XCTAssertEqual(MessageBubbleBadge.slashCommand.label, "Slash")
    }

    func test_backgroundColor_eachCasePinsItsColor() {
        let theme = Theme(colorScheme: .light)

        // Pre-existing hardcoded colors (kept out of scope per PR plan).
        XCTAssertEqual(
            UIColor(MessageBubbleBadge.toolResult.backgroundColor(theme: theme)),
            UIColor(Color.purple))
        XCTAssertEqual(
            UIColor(MessageBubbleBadge.thinking.backgroundColor(theme: theme)),
            UIColor(Color.blue))
        XCTAssertEqual(
            UIColor(MessageBubbleBadge.toolCall.backgroundColor(theme: theme)),
            UIColor(Color.orange))

        // New theme-aware tokens — the resolver must reach the
        // theme rather than baking a hex.
        XCTAssertEqual(
            UIColor(MessageBubbleBadge.assistant.backgroundColor(theme: theme)),
            UIColor(theme.badgeAssistant))
        XCTAssertEqual(
            UIColor(MessageBubbleBadge.slashCommand.backgroundColor(theme: theme)),
            UIColor(theme.badgeSlashCommand))
    }
}