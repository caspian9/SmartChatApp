import Foundation
import os

final class MarkdownCache: @unchecked Sendable {
    static let shared = MarkdownCache()

    private let lock = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])
    private var cache: [String: Bool] {
        lock.withLock { $0 }
    }

    /// Returns true if `message` should be rendered as markdown.
    ///
    /// **Lazy**: first call computes via `CardRegistry.containsMarkdown`,
    /// subsequent calls hit the cache. The cache is keyed by
    /// `message.text` (content), NOT by `message.id` — the id is
    /// unstable across the client-streaming / server-history boundary:
    /// streaming uses `id=runId` (which `toOpenClawChatMessage`
    /// synthesizes into a fresh UUID for disk persistence) and the
    /// server returns `id=server-assigned-UUID`. After
    /// `MessageCacheStore.replaceForSession` swaps the in-memory
    /// store to the server's payload, an id-based lookup misses
    /// every entry, and `MessageBubbleView.shouldRenderMarkdown`
    /// falls back to `false` — the bubble reverts to plain text
    /// even though the content is identical. Content-keyed lookup
    /// survives the id swap.
    ///
    /// **Performance**: with `LazyVStack`, only 5-10 bubbles are
    /// materialized per body evaluation, so the first compute is
    /// ~50-100 regex matches (~0.5-2ms on a physical iPhone). The
    /// detached precompute the previous design used to offload the
    /// 2000-regex up-front cost is no longer needed — the cost is
    /// bounded by visible-bubble count, not session length.
    func needsMarkdown(for message: ChatMessage) -> Bool {
        guard !message.isOutgoing else { return false }
        guard !message.text.isEmpty else { return false }
        guard message.role != "toolResult" && message.role != "thinking" else { return false }
        if let cached = cache[message.text] { return cached }
        let result = CardRegistry.containsMarkdown(content: message.text)
        lock.withLock { $0[message.text] = result }
        return result
    }

    /// Pre-fills the cache for a batch of messages. Now a no-op —
    /// see `needsMarkdown(for:)` for the lazy-lookup rationale.
    /// The detached precompute was originally added to avoid a
    /// main-thread regex pass on session entry, but the per-visible-
    /// bubble cost is well below the threshold where offloading is
    /// worth the complexity. Kept as an empty function for backward
    /// compatibility with the `HistoryLoader` call site — removing
    /// the call site entirely is the clean fix.
    func precomputeForMessages(_ messages: [ChatMessage]) {
        // No-op. See docstring above.
    }

    /// Eager-mark for a streaming message. Now a no-op — see
    /// `needsMarkdown(for:)` for the lazy-lookup rationale. The
    /// lifecycle-start placeholder has empty text, so the cheap
    /// pre-filters in `needsMarkdown(for:)` short-circuit to
    /// `false` regardless of this hint. The final-state message
    /// (with full text) is computed lazily on first view read.
    func setNeedsMarkdown(_ messageId: String, value: Bool = true) {
        // No-op. See docstring above.
    }

    func clear() {
        lock.withLock { $0.removeAll() }
    }

    func remove(for messageId: String) {
        // Cache is content-keyed — no per-id removal. Use `clear()`
        // when the whole session is gone.
    }
}
