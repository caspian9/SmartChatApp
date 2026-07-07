import SwiftUI
import OpenClawChatUI
import OpenClawKit

/// Tunables for the streaming-delta accumulator. Centralized so
/// the threshold is greppable from the test target and so a
/// future revision can lift these to `ConfigurationManager` if
/// per-profile tuning becomes useful.
private enum StreamingDelta {
    /// Minimum longest-common-prefix length to trust a
    /// partial-overlap rewrite instead of falling back to plain
    /// concatenation. Below this, plain concat is the safer
    /// default — short common prefixes like "the " or " a "
    /// would otherwise wrongly mark unrelated fragments as
    /// overlapping.
    static let partialOverlapMinLCP = 8
}

@MainActor
final class EventInterpreter {
    weak var viewModel: NativeChatViewModel?

    /// Per-run assistant text accumulator. The server comment in
    /// `case "assistant"` (line ~131) claims it sends the full
    /// cumulative text on every chunk, but device testing shows it
    /// actually sends incremental suffixes ("ha" + "llo" + " there"
    /// instead of "ha" / "hello" / "hello there"). `MarkdownStreamManager`
    /// overwrites its `lastReceivedText` on each delta, so its
    /// `currentText()` would return just the last suffix — and
    /// the lifecycle-end extraction is what populates the
    /// persisted `text` / `startedAt` / `endedAt` / `seq` on
    /// the message that becomes the final bubble.
    ///
    /// We accumulate ourselves so the lifecycle end produces a
    /// ChatMessage with the full text regardless of what
    /// MarkdownStreamManager has tracked. Streamed into
    /// `MarkdownStreamManager.appendCumulative` for the live
    /// streaming display (which appends internally and would
    /// handle either cumulative or incremental deltas correctly
    /// for visual purposes) but the *authoritative* final text
    /// comes from this dict.
    private var accumulatedAssistantTextByRun: [String: String] = [:]
    /// Per-run assistant startedAt, recorded on `lifecycle=start` and
    /// re-stamped on every `assistant` delta. Without this, the
    /// per-delta `ChatMessage` would carry `startedAt: nil` and the
    /// `MessageCacheStorage.upsert` (id-based replace) would clobber
    /// the start time the lifecycle-start put in. Symptom: the
    /// bubble's "HH:mm" prefix appears briefly after the first delta,
    /// then disappears as more deltas come in, until `lifecycle=end`
    /// restores it. Same pattern as `toolStartedAtByCall` below.
    private var assistantStartedAtByRun: [String: Date] = [:]
    /// Per-run counter for the next assistant fragment's stable id
    /// slot. Each "tool boundary" (any `item phase=start` event)
    /// increments the counter so the next segment of assistant text
    /// gets a fresh id and upserts into a separate bubble instead of
    /// stitching onto the previous one. Without this split, the
    /// LCP-12 partial-overlap rewrite (issue #21) was producing
    /// Frankenstein text by stretching a single bubble across the
    /// model's "thinking aloud" segments and the actual response —
    /// see the user-reported EFB69836 weather run on 2026-06-29:
    /// pre-tool "Saturday is July 4 — 5 days out...", inter-tool
    /// "Only 3-day data...", inter-tool "Saturday is **July 4**...",
    /// and response "Found it. From..." all collapsed into one
    /// Frankenstein bubble. Each fragment id is
    /// "<runId>:assistant:<N>". The view's `sortForDisplay` puts
    /// these in order via the per-fragment `seq` (the seq of each
    /// fragment's last delta). Cleared at `lifecycle=end` along with
    /// the other per-run dicts.
    private var assistantFragmentIdxByRun: [String: Int] = [:]
    /// Per-run seq of the LAST assistant delta we processed.
    /// The finalize helper at every `item phase=start` boundary
    /// uses this so the finalize ChatMessage can carry the
    /// fragment's correct seq (otherwise it would write `seq: nil`
    /// in `recordStreamingMetadata`, and the per-run sort in
    /// `sortForDisplay` would interpret that as `Int.max` and put
    /// the finalized fragment AFTER the response fragment — the
    /// reverse of the user's "preamble first, response last"
    /// expectation).
    private var lastAssistantSeqByRun: [String: Int] = [:]
    /// Per-tool-call startedAt, keyed by "<runId>:<toolCallId>".
    /// The legacy `stream: "tool"` path fires `phase: "update"`
    /// events that wipe `startedAt` to nil on each call, which
    /// causes the bubble's "HH:mm" prefix to disappear the moment
    /// the tool starts producing output. We remember the
    /// timestamp from the `phase: "start"` event and re-stamp it
    /// on every subsequent `update` / `result` for the same
    /// toolCallId so the bubble keeps its start time.
    private var toolStartedAtByCall: [String: Date] = [:]
    /// Per-tool-call local-received-time at `phase: "start"`, keyed
    /// by "<runId>:<toolCallId>". Used as the toolCall bubble's
    /// sort `timestamp` so it sorts BEFORE the toolResult (which
    /// is upserted later via `command_output` / `tool (result)`).
    /// Pairs with `toolStartedAtByCall` (server's `payload.ts`,
    /// used for `startedAt` display) but tracks the *local*
    /// arrival time so clock-skew between the gateway and the
    /// device can't push the toolCall's sort key past the
    /// toolResult's. See `case "item"` for the matching sort-time
    /// read.
    private var toolReceivedAtByCall: [String: Date] = [:]
    /// Per-tool-call incremental-output accumulator, keyed by
    /// `"<runId>:<canonical>"` (canonical = `toolCallId ?? itemId`).
    /// The streaming `command_output` events arrive as
    /// `phase: "delta"` chunks, then a final `phase: "end"`.
    /// The end event's `output` field is *sometimes* the full
    /// accumulated text (typical SDK) and *sometimes* just the
    /// last chunk (server-side truncation / aggregator bug
    /// reproduced on 2026-07-07: a toolResult bubble that
    /// contained only the first ~30% of the tool's stdout, with
    /// later output lost because the end event arrived with an
    /// incremental `output` rather than the full text).
    ///
    /// Without this accumulator the bubble would show only the
    /// latest delta — the user sees a truncated JSON body with
    /// `(live output truncated)` mid-text and `exit=0
    /// duration=Nms` at the end, while the server's
    /// `chat.history` later returns the FULL text and dedup
    /// replaces the bubble with the complete version.
    ///
    /// The accumulator strategy: on each `command_output`
    /// event, append the event's `output` to the accumulator
    /// (regardless of phase). On `phase: "end"`, use the
    /// accumulator's length — if it's longer than the
    /// end-event's `output` alone, the accumulator is more
    /// complete and wins. The dedup-replace path against the
    /// server's `chat.history` payload is unchanged; this
    /// fix only affects the live streaming display (so the
    /// user sees the full content without having to wait for
    /// a refresh).
    ///
    /// Cleared on `phase: "end` after the bubble is written
    /// (matches `toolStartedAtByCall`'s cleanup at line ~1326).
    /// Also cleared on `lifecycle=end` so stale partial
    /// accumulators don't leak across runs.
    private var accumulatedToolOutputByCall: [String: String] = [:]
    /// Per-run thinking text accumulator. Mirrors
    /// `accumulatedAssistantTextByRun` for the thinking stream —
    /// without an accumulator, incremental deltas ("thinking
    /// part 1" + " part 2" + " part 3") would each upsert over
    /// the previous entry and the final bubble would contain
    /// only the last fragment. The accumulator preserves the
    /// full thinking across the run, similar to the assistant
    /// text path. Cleared on `lifecycle=end`.
    private var accumulatedThinkingTextByRun: [String: String] = [:]
    /// Per-run `toolCallId → canonical id` alias map. The modern
    /// `item phase=start` populates this when a tool call begins,
    /// recording (a) the toolCallId's self-mapping to itself and
    /// (b) the itemId's mapping to the toolCallId. The legacy
    /// `stream: "tool"` path may emit the same logical tool under
    /// a different toolCallId than the modern path's; this map
    /// lets the legacy path resolve its toolCallId to the modern
    /// canonical id before computing its bubble id and toolKey, so
    /// the upsert collapses legacy + modern writes into a single
    /// bubble. Without this alias, two failure modes surface:
    ///
    /// 1. Different toolCallIds across paths → two distinct
    ///    `<runId>:toolResult:<...>` bubble ids → the user sees
    ///    duplicate toolCall + toolResult bubbles for one logical
    ///    tool call (user-reported 2026-07-02).
    /// 2. Same toolCallId across paths → the legacy `tool (result)`
    ///    handler's `toolStartedAtByCall.removeValue(forKey:)` at
    ///    line ~904 wipes the entry before the modern
    ///    `command_output (end)` reads it → modern toolResult
    ///    ChatMessage carries `startedAt: nil` → bubble footer
    ///    shows only the end time (user-reported 2026-07-02).
    ///
    /// Cleared on `lifecycle=end`.
    private var toolCallIdAliasByRun: [String: [String: String]] = [:]
    /// Per-run "most-recent tool-call canonical id" pointer. When
    /// the modern `item phase=start` fires first with id `M` and
    /// the legacy `tool phase=start` arrives later with id `L`
    /// for the same logical tool, the alias map's key `L` is
    /// unknown at lookup time. The latest-canonical pointer
    /// captures the most recent canonical that any path
    /// (modern or legacy) registered for this runId, so the
    /// legacy can adopt it as its own canonical and the
    /// upsert collapses both paths' writes. Bounded per run —
    /// at most one canonical at a time because tools are
    /// sequential within a run. Cleared on `lifecycle=end`.
    private var toolLatestCanonicalByRun: [String: String] = [:]

    /// runIds whose `lifecycle=end` has already been processed for
    /// the current session. The transport (or upstream server) can
    /// re-deliver the same `lifecycle=end` event multiple times
    /// for the same runId (same payload, same seq). Without
    /// idempotency, the 2nd arrival sees
    /// `accumulatedAssistantTextByRun[runId] == nil` (the 1st
    /// cleared it after `await viewModel?.receiveMessage` returned)
    /// AND `MarkdownStreamManager.currentText == ""` (the 1st's
    /// `end()` call drained the buffer), so it falls through to
    /// `effectiveFullText = fullText = ""` and `store.upsert`
    /// overwrites the bubble's `text` with the empty string —
    /// silently wiping the streaming response.
    /// Symptom (reproduced 2026-06-18 08:29:30 on device):
    ///   `bubbleExists=true storedTextLen=30` after the assistant
    ///   delta, then 3 `agent lifecycle end` lines fire for the
    ///   same runId; the 3rd shows `accumulated len: -1,
    ///   effective: 0` and the view renders an empty bubble with
    ///   the lifecycle=end footer ("#17 13:52 -> 13:52") but no
    ///   body. Tracking processed runIds and short-circuiting the
    ///   2nd/3rd arrival keeps the bubble intact.
    @ObservationIgnored
    private var processedLifecycleEndByRun: Set<String> = []
    /// Per-(runId, stream) `seq` watermark. The server's
    /// `payload.seq` is monotonic per-stream (assistant and
    /// thinking are independent streams with their own seq
    /// counters; an assistant seq of 2 and a thinking seq of 1
    /// for the same run are both valid and unrelated). Rejecting
    /// a delta with `seq <= lastSeen` drops transport-level
    /// retransmits and out-of-order arrivals at the gate, before
    /// any text comparison runs. Cleared on `lifecycle=end`
    /// alongside the other per-run accumulators.
    @ObservationIgnored
    private var lastSeenSeqByRun: [String: [String: Int]] = [:]

    func handleTransportEvent(_ event: OpenClawChatTransportEvent, sessionKey: String) async {
        switch event {
        case .agent(let payload):
            AppLogger.log("agent event - stream=\(payload.stream) runId=\(payload.runId) seq=\(payload.seq ?? -1) ts=\(payload.ts ?? 0) data=\(EventInterpreter.serializeDataForLog(payload.data))", category: .nativeChat)
            let runId = payload.runId
            let ts = payload.ts ?? 0
            let timestamp = Date(timeIntervalSince1970: Double(ts) / 1000)
            let data = payload.data
            let seq = payload.seq
            let phase = data["phase"]?.stringValue
            let startedAtMs = data["startedAt"]?.doubleValue ?? 0
            let endedAtMs = data["endedAt"]?.doubleValue ?? 0
            let livenessState = data["livenessState"]?.stringValue

            switch payload.stream {
            case "lifecycle":
                if phase == "start" {
                    // Start of a new run. The lifecycle signal alone doesn't know
                    // what content is coming — it could be assistant text, thinking,
                    // or tool calls. Create a generic placeholder (id=runId) so the
                    // UI has a 3-dot indicator immediately. First real content
                    // (assistant/thinking/tool) creates its own sibling message with
                    // a typed id; assistant deltas also land on this placeholder
                    // since they share id=runId, so it doubles as the assistant
                    // bubble when text arrives.
                    AppLogger.log("agent lifecycle start - runId: \(runId), seq: \(seq ?? -1), startedAt: \(startedAtMs)", category: .nativeChat)
                    // Eager-mark removed: `MarkdownCache.needsMarkdown(for:)`
                    // is now lazy and content-keyed, so the lifecycle-start
                    // No-op placeholder for the lifecycle=start
                    // branch. Previously this eagerly pre-created a
                    // `MarkdownStreamManager` holder so the streaming
                    // view could mount a `MarkdownViewTextKit` for the
                    // run; with the third-party lib removed (2026-06-29
                    // flicker fix), there's no streaming markdown view
                    // to prime. The bubble's lifecycle=start bubble
                    // still emits a placeholder ChatMessage below so
                    // the view can show its "typing" indicator.
                    // Remember the start time so subsequent `assistant`
                    // deltas can re-stamp it (the per-delta
                    // `ChatMessage` below has no other way to know it).
                    let startedAt = startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : timestamp
                    assistantStartedAtByRun[runId] = startedAt
                    // Placeholder uses fragment 0's id so the first
                    // streaming delta (which also reads N=0) lands
                    // on the same slot — without this match, the
                    // delta would upsert onto a different UUID and
                    // spawn a duplicate empty placeholder.
                    let placeholderFragmentId = "\(runId):assistant:\(assistantFragmentIdxByRun[runId, default: 0])"
                    let message = ChatMessage(
                        id: placeholderFragmentId,
                        text: "",
                        // Use the local received time (Date()) for the
                        // sort key, NOT `timestamp` (the server's
                        // `payload.ts` — the gateway clock is often
                        // several seconds behind the device, and if
                        // we sort by the server's ts the response
                        // would land ABOVE the just-sent user
                        // bubble, which the user reads as
                        // "the first response bubble lands above the
                        // just-sent user message". The
                        // server's ts is preserved in `startedAt`
                        // for the "HH:MM" display label, and in
                        // `endedAt` for the lifecycle end event.
                        timestamp: Date(),
                        role: "assistant",
                        state: "streaming",
                        runId: runId,
                        seq: seq,
                        startedAt: startedAt,
                        endedAt: nil,
                        livenessState: livenessState,
                        toolCallId: nil,
                        toolName: nil,
                        stopReason: nil,
                        isFresh: true
                    )
                    await viewModel?.receiveMessage(message)
                } else if phase == "end" {
                    // End of run. The previous implementation keyed off phase=end
                    // for every event, which caused tool end phases to prematurely
                    // finalize the run and reset sending. With stream-based dispatch,
                    // only the actual lifecycle end reaches here, so the run-level
                    // state (tokens, endedAt, setSending(false)) is correctly tied
                    // to the real terminal signal.
                    // Idempotency guard: the upstream transport can re-deliver the
                    // same `lifecycle=end` event for a runId that's already been
                    // processed (e.g. WebSocket retransmit). The 2nd arrival would
                    // see an empty accumulator + an empty
                    // `MarkdownStreamManager.currentText` (both drained by the
                    // 1st), and `store.upsert` would overwrite the bubble's text
                    // with `""`. Skip silently — the 1st processing has already
                    // written the correct final state. See the comment on
                    // `processedLifecycleEndByRun` for the full repro.
                    if processedLifecycleEndByRun.contains(runId) {
                        AppLogger.log("agent lifecycle end - SKIP (already processed): runId: \(runId)", category: .nativeChat, level: .debug)
                        return
                    }
                    // Mark the runId as processed BEFORE any await. The
                    // line 306 `await viewModel?.receiveMessage(message)`
                    // yields the MainActor — without this early insert, a
                    // racing re-delivery of the same `lifecycle=end` (the
                    // WS server retransmits the terminal event after the
                    // final ack) can enter this branch, read
                    // `accumulatedAssistantTextByRun[runId]` after we
                    // drain it at line ~321, compute `effective=0`, and
                    // upsert an empty bubble over the streamed text.
                    // Reproduced on device 2026-06-29 07:01:22 with the
                    // weather agent run (runId FA2B00AB-DA1E-...):
                    //   1st delivery → accumulated=305, effective=305
                    //   2nd delivery → accumulated=-1 (nil), effective=0
                    //   → assistant bubble shows empty.
                    // Inserting synchronously at the top, before any
                    // await, makes the guard at line ~201 above
                    // monotonic. The duplicate insert at the end of
                    // this branch stays as a no-op (Set.insert is
                    // idempotent) and keeps the comment intent —
                    // `processedLifecycleEndByRun` is the
                    // "already-handled" record aligned with the per-run
                    // accumulator lifetimes.
                    processedLifecycleEndByRun.insert(runId)
                    AppLogger.log("agent lifecycle end - runId: \(runId), data keys: \(data.keys.map { $0 })", category: .nativeChat)
                    var inputTokens: Int?
                    var outputTokens: Int?
                    var cacheRead: Int?
                    var cacheWrite: Int?
                    if let usage = data["usage"]?.value as? [String: Any] {
                        AppLogger.log("found usage dict: \(String(describing: usage))", category: .nativeChat)
                        if let input = usage["input"] as? Int { inputTokens = input }
                        if let output = usage["output"] as? Int { outputTokens = output }
                        if let cr = usage["cacheRead"] as? Int { cacheRead = cr }
                        if let cw = usage["cacheWrite"] as? Int { cacheWrite = cw }
                    }
                    if inputTokens == nil, let input = data["inputTokens"]?.intValue { inputTokens = input }
                    if outputTokens == nil, let output = data["outputTokens"]?.intValue { outputTokens = output }
                    if cacheRead == nil, let cr = data["cacheRead"]?.intValue { cacheRead = cr }
                    if cacheWrite == nil, let cw = data["cacheWrite"]?.intValue { cacheWrite = cw }
                    AppLogger.log("agent lifecycle end - tokens: input: \(inputTokens ?? -1), output: \(outputTokens ?? -1), cacheRead: \(cacheRead ?? -1), cacheWrite: \(cacheWrite ?? -1)", category: .nativeChat)
                    // Cache anchor for the final assistant bubble's
                    // sort `timestamp`. Priority:
                    //   1. event `endedAtMs` (the lifecycle=end
                    //      payload's ms-since-epoch) — the most
                    //      accurate "when did this run actually
                    //      finish" timestamp, falls within the run's
                    //      wall-clock window.
                    //   2. `assistantStartedAtByRun[runId]` (the
                    //      lifecycle=start wall clock) — only used
                    //      when the server omits `endedAtMs`.
                    //   3. event `startedAtMs` (often 0 on the end
                    //      event).
                    //   4. now() as a last resort.
                    //
                    // Rationale for preferring `endedAtMs` over the
                    // old default (`assistantStartedAtByRun`): the
                    // bubble's persisted `timestamp` doubles as the
                    // cache-sort key for post-exit re-entry. After
                    // `clearMemory(for:)` clears the VM's
                    // `receivedAt` overlay, the view falls back to
                    // `timestamp` for ordering. Using the run's
                    // START time (the old behavior) sorts the
                    // assistant final EARLIER than its own
                    // toolCall/toolResult siblings (which were
                    // written at `Date()` mid-run), making the
                    // assistant bubble appear at the top of the
                    // run's group instead of the bottom — the
                    // user-reported ordering regression on
                    // 2026-07-06.
                    //
                    // Dedup compatibility with the server's
                    // `chat.history` copy is preserved by
                    // `MessageCacheStorage.dedupKey`'s 60-second
                    // `tsBucket`: stream end and server history
                    // land in the same bucket as long as the
                    // timestamps are within ~60s of each other
                    // (always true for a single run; the server's
                    // history copy uses its own end-time ts which
                    // is within a few ms of the streaming
                    // `endedAtMs`).
                    let chosenAnchor: Date = {
                        if endedAtMs > 0 { return Date(timeIntervalSince1970: endedAtMs / 1000) }
                        if let start = assistantStartedAtByRun[runId] { return start }
                        if startedAtMs > 0 { return Date(timeIntervalSince1970: startedAtMs / 1000) }
                        return Date()
                    }()
                    AppLogger.log("agent lifecycle end - cache anchor: startedAtRun=\(assistantStartedAtByRun[runId]?.timeIntervalSince1970 ?? -1) endedAtMs=\(endedAtMs) → chosen=\(chosenAnchor.timeIntervalSince1970)", category: .nativeChat)
                    // Authoritative source for the final bubble's text is
                    // `accumulatedAssistantTextByRun[runId]` (populated by
                    // every `assistant` delta). Previously this code
                    // also queried `MarkdownStreamManager.currentText`
                    // as a secondary fallback, but with the third-party
                    // lib removed the manager is gone and the accumulator
                    // is the only authoritative store. Runs that produced
                    // no assistant text (only thinking/tools) will
                    // resolve to an empty `effectiveFullText`, which
                    // the bubble view renders as an empty assistant
                    // bubble; the lifecycle=end's `chatMessages` upsert
                    // below will skip the empty-assistant path so we
                    // don't show a stray placeholder.
                    let effectiveFullText: String = accumulatedAssistantTextByRun[runId] ?? ""
                    AppLogger.log("agent lifecycle end - accumulated len: \(accumulatedAssistantTextByRun[runId]?.count ?? -1), effective: \(effectiveFullText.count) for runId: \(runId)", category: .nativeChat)
                    // Pull startedAt from the lifecycle=start record
                    // when the server omits it on the end event (the
                    // end event's `startedAt` is sometimes 0). Falls
                    // back to whatever the event provided, then to
                    // the event timestamp as a last resort.
                    let resolvedStartedAt: Date? = {
                        if startedAtMs > 0 { return Date(timeIntervalSince1970: startedAtMs / 1000) }
                        return assistantStartedAtByRun[runId] ?? timestamp
                    }()
                    // Use the current fragment id so the final-state
                    // upsert REPLACES the streaming entry for the
                    // last fragment (same UUID), not a different
                    // fragment id (which would create a duplicate
                    // bubble after the streaming finalize on the
                    // previous tool boundary already incremented the
                    // fragment counter).
                    let finalFragmentId = "\(runId):assistant:\(assistantFragmentIdxByRun[runId, default: 0])"
                    let message = ChatMessage(
                        id: finalFragmentId,
                        text: effectiveFullText,
                        // Cache-anchor: the run's
                        // `lifecycle=start` `startedAt` (recorded in
                        // `assistantStartedAtByRun[runId]` above).
                        // This is the same value the server's
                        // `chat.history` projection uses as the
                        // message `timestamp` field for the same
                        // run, so the streaming entry and the
                        // server's later history entry land in the
                        // same `MessageCacheStorage.dedupKey` 10s
                        // bucket and dedup against each other. The
                        // same `chosenAnchor` is logged above so the
                        // value the log shows is the value that
                        // actually reaches the cache (no chance of
                        // drift between the two).
                        timestamp: chosenAnchor,
                        role: "assistant",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: resolvedStartedAt,
                        endedAt: endedAtMs > 0 ? Date(timeIntervalSince1970: endedAtMs / 1000) : timestamp,
                        livenessState: livenessState,
                        inputTokens: inputTokens,
                        outputTokens: outputTokens,
                        cacheRead: cacheRead,
                        cacheWrite: cacheWrite,
                        toolCallId: nil,
                        toolName: nil,
                        stopReason: nil,
                        isFresh: true
                    )
                    await viewModel?.receiveMessage(message)
                    // Streaming bubbles (the lifecycle=start placeholder
                    // and all deltas) share the same `id=runId` as
                    // this final message, so the receiveMessage
                    // upsert above has already replaced them in place
                    // inside `MessageCacheStore`. No explicit
                    // "clear pending" call is needed — and in fact
                    // would be harmful, since a session with multiple
                    // in-flight runs (nested tool call, etc.) would
                    // have those other runs' pending entries nuked.
                    // Cleanup: drop the per-run accumulators. Holder
                    // is released below — `MarkdownStreamManager.release`
                    // would have been the right place to also nil the
                    // accumulators, but they live on EventInterpreter
                    // not on the manager.
                    accumulatedAssistantTextByRun.removeValue(forKey: runId)
                    assistantStartedAtByRun.removeValue(forKey: runId)
                    accumulatedThinkingTextByRun.removeValue(forKey: runId)
                    lastSeenSeqByRun.removeValue(forKey: runId)
                    toolCallIdAliasByRun.removeValue(forKey: runId)
                    toolLatestCanonicalByRun.removeValue(forKey: runId)
                    // BUG-8: clear any per-tool accumulated
                    // output for this run (tools whose
                    // `command_output (end)` never arrived —
                    // e.g. run aborted — would otherwise leave
                    // stale entries that could leak into the
                    // next run via a toolKey collision).
                    for (key, _) in accumulatedToolOutputByCall where key.hasPrefix("\(runId):") {
                        accumulatedToolOutputByCall.removeValue(forKey: key)
                    }
                    // Fragment counter — must be reset so the next
                    // run for this same runId (in the unusual case
                    // of a session resume or a re-spawn) starts from
                    // fragment 0 instead of appending onto the
                    // previous run's count.
                    assistantFragmentIdxByRun.removeValue(forKey: runId)
                    lastAssistantSeqByRun.removeValue(forKey: runId)
                    // Mark the runId as processed BEFORE returning so any
                    // racing re-delivery of the same `lifecycle=end` event
                    // short-circuits at the top of this branch. Inserting
                    // after the cleanup also keeps the set's lifetime
                    // aligned with the per-run accumulators above — they're
                    // all torn down together at the natural end of the run.
                    processedLifecycleEndByRun.insert(runId)
                    // No-op cleanup. With the third-party
                    // `MarkdownStreamManager` removed, there's no
                    // streaming-view holder to release on lifecycle=end.
                    // The bubble's lifecycle=end upserts the final
                    // ChatMessage below, which is what `MessageReceiver`
                    // persists and the bubble view renders.
                    // Only the real terminal signal resets the sending flag.
                    // `resetSendState` (instead of a direct assignment) also
                    // cancels the send-timeout watchdog armed in
                    // `sendMessage`, so a normal response short-circuits
                    // the watchdog before it can fire spuriously.
                    viewModel?.resetSendState()
                } else {
                    // Any phase other than "start" / "end" is a server
                    // shape we don't recognize — log a warning so the
                    // gap is visible (unknown phase → server contract
                    // drift; would otherwise be silently swallowed by
                    // the if/else-if chain). .warning so the line is
                    // greppable for triage alongside the start/end
                    // lines.
                    AppLogger.log("agent lifecycle UNHANDLED phase=\(phase ?? "nil") runId=\(runId) seq=\(seq ?? -1) data=\(EventInterpreter.serializeDataForLog(data))", category: .nativeChat, level: .warning)
                }
            case "assistant":
                // The server's actual streaming shape is **not**
                // consistent across runs and the upstream comment
                // ("device testing shows incremental suffixes") was
                // wrong for at least one real run. In the failing
                // case the server sent the full text so far on
                // every chunk — delta N was delta N-1 plus a
                // prepended/inserted fragment ("hello" → "hello there").
                // Naively appending to the accumulator then produced a
                // doubled (sum) bubble text with the earlier fragments
                // repeated at every position ("ok" + "this is **ok" +
                // "this is **flowed ok" = "ok" appearing three times in
                // the final bubble).
                //
                // Resolution: detect the shape of each delta and
                // dispatch:
                // - delta is a *superset* of the accumulator
                //   (`text.hasPrefix(prev)`) → server is sending
                //   cumulative. Replace, don't append.
                // - accumulator is a *superset* of the delta
                //   (`prev.hasPrefix(text)`) → out-of-order / late
                //   stale state from the server. Ignore, the
                //   accumulator is already newer.
                // - otherwise (no prefix overlap) → server is
                //   sending incremental. Append.
                // The lifecycle end still re-upserts with the
                // accumulator at that point so the final
                // `effectiveFullText` reflects the most recent
                // accumulator value, regardless of shape.
                let text = data["text"]?.stringValue ?? ""
                AppLogger.log("agent assistant delta - text len: \(text.count), runId: \(runId)", category: .nativeChat)
                guard !text.isEmpty else { return }
                let prev = accumulatedAssistantTextByRun[runId] ?? ""

                // Seq guard: drop retransmits / out-of-order
                // arrivals before any text comparison runs.
                // payload.seq is monotonic per-stream (assistant
                // and thinking are independent; the assistant
                // seq of 2 and thinking seq of 1 for the same
                // run are unrelated). The `payload.stream` value
                // is included in the watermark key so the two
                // streams don't share a counter — see the
                // matching comment on `lastSeenSeqByRun` above
                // for the per-stream keying rationale. Skipped
                // when seq is nil so older servers without a seq
                // field aren't blocked at the gate.
                if let seq, let seen = lastSeenSeqByRun[runId]?[payload.stream], seq <= seen {
                    AppLogger.log(
                        "agent assistant delta - ignored (seq replay): runId: \(runId), stream: \(payload.stream), seen: \(seen), deltaSeq: \(seq)",
                        category: .nativeChat, level: .warning)
                    return
                }
                if let seq {
                    var perStream = lastSeenSeqByRun[runId] ?? [:]
                    perStream[payload.stream] = seq
                    lastSeenSeqByRun[runId] = perStream
                }

                // Exact-duplicate short-circuit. If the new delta
                // is byte-identical to the accumulator we already
                // have, there's nothing to update. log only when
                // seq is also identical (transport-level
                // retransmit); a same-text different-seq arrival
                // is a no-op and stays silent.
                guard text != prev else {
                    AppLogger.log(
                        "agent assistant delta - ignored (identical text): runId: \(runId), text len: \(text.count)",
                        category: .nativeChat, level: .debug)
                    return
                }

                let accText: String
                if prev.isEmpty || text.hasPrefix(prev) {
                    // First delta, or cumulative shape: server is
                    // sending the full-so-far text on every chunk.
                    // Replace, don't append — using the new delta
                    // as-is keeps the bubble growing monotonically
                    // along the server's actual progression
                    // instead of producing a concatenation of past
                    // deltas.
                    accText = text
                } else if prev.hasPrefix(text) {
                    // Out-of-order / stale: the new delta is a
                    // state we already passed through. The
                    // accumulator is already ahead. Drop the
                    // delta so we don't regress the visible text.
                    AppLogger.log(
                        "agent assistant delta - ignored (stale): prev len: \(prev.count), delta len: \(text.count)",
                        category: .nativeChat, level: .warning)
                    return
                } else {
                    // Partial overlap: neither is a full prefix of
                    // the other, but they share a common prefix of
                    // meaningful length. This is the
                    // LLM-rewrites-earlier-tokens shape that the
                    // old "Incremental: append" branch mishandled
                    // (issue #21 real-world example: "this is **ok"
                    // → "this is **flowed ok" produced
                    // "this is **okthis is **flowed ok").
                    let lcp = EventInterpreter.longestCommonPrefix(prev, text)
                    if lcp >= StreamingDelta.partialOverlapMinLCP {
                        AppLogger.log(
                            "agent assistant delta - partial-overlap: lcp=\(lcp), prev len: \(prev.count), delta len: \(text.count)",
                            category: .nativeChat)
                        accText = String(prev.prefix(lcp)) + String(text.dropFirst(lcp))
                    } else {
                        // LCP < 8: the prefix-overlap rewrite above
                        // doesn't apply. BUT the server's incremental
                        // deltas often SUFFIX-overlap prev (the next
                        // fragment starts with the same chars prev
                        // ends with, e.g. prev="...看看这个功能怎么用。",
                        // text="看看这个功能"). Naive `prev + text`
                        // here duplicates "看看这个功能" in the visible
                        // bubble. Reproduced on device 2026-06-29
                        // 07:50:35 with the Beijing-location agent
                        // run — short Chinese deltas ("！", "°",
                        // "E", "**") stacked across the LCP<8
                        // branch and produced visible redundancy
                        // ("让我让我们查一下", "iOSiOS",
                        // "看到了看到了", etc.).
                        //
                        // Resolution: check whether prev's suffix
                        // matches text's prefix and trim before
                        // appending. Three sub-cases:
                        //  - text is fully contained in prev's
                        //    suffix (delta is a redundant replay) →
                        //    drop, no accumulator change.
                        //  - text's prefix overlaps prev's suffix by
                        //    some chars → append only the unique tail
                        //    of text (`prev + text.dropFirst(overlap)`).
                        //  - no overlap → truly independent fragments,
                        //    plain concat is correct.
                        let suffixOverlap = EventInterpreter.longestSuffixPrefixOverlap(prev, text)
                        if suffixOverlap == text.count {
                            AppLogger.log(
                                "agent assistant delta - ignored (text already in accumulator): runId: \(runId), prev len: \(prev.count), text len: \(text.count)",
                                category: .nativeChat, level: .debug)
                            return
                        }
                        if suffixOverlap > 0 {
                            AppLogger.log(
                                "agent assistant delta - suffix-overlap: overlap=\(suffixOverlap), prev len: \(prev.count), delta len: \(text.count)",
                                category: .nativeChat)
                            accText = prev + String(text.dropFirst(suffixOverlap))
                        } else {
                            accText = prev + text
                        }
                    }
                }
                accumulatedAssistantTextByRun[runId] = accText
                // Track the latest seq per run so the finalize at
                // the next tool boundary can propagate the right
                // `seq` into the streaming-metadata overlay (the
                // finalize ChatMessage itself is built with
                // `seq: nil` because it doesn't represent a single
                // payload — `lastAssistantSeqByRun` is the source
                // of truth for the "sort key" the per-run
                // `sortForDisplay` reads).
                if let seq {
                    lastAssistantSeqByRun[runId] = seq
                }
                // Re-stamp startedAt from the lifecycle=start record
                // so the bubble's "HH:mm" prefix doesn't disappear
                // on each subsequent delta (the upsert-by-id path
                // would otherwise clobber the start time the first
                // delta put in).
                let startedAt = assistantStartedAtByRun[runId] ?? timestamp
                // Fragment id: `<runId>:assistant:<N>`. N is the current
                // fragment index; each tool-boundary finalize (see
                // `item phase=start` branch) bumps it so the next
                // segment gets its own slot. The deterministic-UUID
                // converter maps this string to a stable UUID per
                // fragment, so `MessageCacheStorage.upsert` keeps each
                // fragment separate instead of merging them.
                let fragmentId = "\(runId):assistant:\(assistantFragmentIdxByRun[runId, default: 0])"
                let message = ChatMessage(
                    id: fragmentId,
                    text: accText,
                    // Local received time for the sort key — see
                    // the matching comment on the lifecycle=start
                    // branch above. The view's `startedAt` keeps
                    // the server's payload.ts so the "HH:MM" label
                    // is still correct.
                    timestamp: Date(),
                    role: "assistant",
                    state: "streaming",
                    runId: runId,
                    seq: seq,
                    startedAt: startedAt,
                    endedAt: nil,
                    livenessState: livenessState,
                    toolCallId: nil,
                    toolName: nil,
                    stopReason: nil,
                    isFresh: true
                )
                AppLogger.log("agent assistant delta - building ChatMessage: id=\(message.id.prefix(12)) seq=\(seq ?? -1) textLen=\(accText.count) textPreview=\"\(String(accText.prefix(40)))\(accText.count > 40 ? "…(\(accText.count))" : "")\"", category: .nativeChat)
                await viewModel?.receiveMessage(message)
                // Post-upsert: confirm the bubble is in the store
                // and what it looks like. Helps diagnose "bubble
                // not shown" issues — if this log shows the bubble
                // but the view doesn't, the problem is in the
                // view's read path; if this log shows the bubble
                // ISN'T there, the upsert is being dropped.
                //
                // IMPORTANT: `MessageCacheStore.messages(for:)` keys on
                // SESSION (not runId) — looking up by the runId
                // returns an empty array even when the bubble is
                // correctly stored, which is the bug the first version
                // of this log shipped. Use the VM's selectedSession
                // key (the same key `MessageReceiver` just upserted
                // under) for an accurate post-upsert probe.
                let postSessionKey = viewModel?.selectedSession?.key ?? "?"
                let postUpsert = viewModel?.store.messages(for: postSessionKey, since: nil) ?? []
                let postForOurId = postUpsert.first(where: { $0.id.uuidString == runId })
                AppLogger.log("agent assistant delta - post-upsert in store: sessionKey=\(String(postSessionKey.prefix(20))) bubbleExists=\(postForOurId != nil) storedTextLen=\(postForOurId?.content.first?.text?.count ?? -1) storedTextPreview=\"\(String((postForOurId?.content.first?.text ?? "").prefix(40)))\"", category: .nativeChat)
            case "thinking":
                // Thinking deltas are emitted as a separate stream from the
                // assistant text — they don't share an id with the assistant
                // placeholder. Use a synthetic id so the message dedups against
                // itself across deltas and renders as a thinking bubble.
                //
                // Field-name handling: the data key carrying the thinking
                // payload is inconsistent across server versions. Some emit
                // `data["text"]` (the older contract this handler was
                // written against), some emit `data["thinking"]` (the
                // semantically accurate name and the one used by
                // `sessionMessage`'s `block.thinking` field). We prefer
                // `thinking` when present, fall back to `text`. Without
                // the `thinking` branch, a server that switched to the
                // accurate field name would silently drop the bubble —
                // the `guard !text.isEmpty` below would short-circuit
                // and no ChatMessage is created, the user would see
                // "thinking content not displayed during receiving".
                let text = data["thinking"]?.stringValue
                    ?? data["text"]?.stringValue
                    ?? ""
                AppLogger.log(
                    "agent thinking delta - text len: \(text.count), data keys: \(data.keys.map { $0 }.sorted())",
                    category: .nativeChat)
                guard !text.isEmpty else { return }
                // Cumulative vs incremental handling. Mirrors the
                // `case "assistant"` accumulator pattern: detect the
                // shape of each delta and dispatch. The server's
                // thinking stream is not guaranteed to be one shape
                // across runs — sometimes it sends the full
                // cumulative text on every chunk (so the new delta
                // starts with the previous accumulator), sometimes
                // it sends incremental fragments (no prefix overlap),
                // and sometimes an out-of-order stale delta arrives
                // (new delta is a prefix of the accumulator). Each
                // case has a different action so the final entry
                // holds the complete thinking rather than the last
                // fragment.
                let prev = accumulatedThinkingTextByRun[runId] ?? ""

                // Seq guard: drop retransmits / out-of-order
                // arrivals for the thinking stream too. Per-stream
                // watermark — see the matching comment in
                // `case "assistant"` for why we key on
                // `(runId, stream)` rather than just `runId`.
                if let seq, let seen = lastSeenSeqByRun[runId]?[payload.stream], seq <= seen {
                    AppLogger.log(
                        "agent thinking delta - ignored (seq replay): runId: \(runId), stream: \(payload.stream), seen: \(seen), deltaSeq: \(seq)",
                        category: .nativeChat, level: .warning)
                    return
                }
                if let seq {
                    var perStream = lastSeenSeqByRun[runId] ?? [:]
                    perStream[payload.stream] = seq
                    lastSeenSeqByRun[runId] = perStream
                }

                // Exact-duplicate short-circuit (mirror of the
                // assistant branch above).
                guard text != prev else {
                    AppLogger.log(
                        "agent thinking delta - ignored (identical text): runId: \(runId), text len: \(text.count)",
                        category: .nativeChat, level: .debug)
                    return
                }

                let accText: String
                if prev.isEmpty || text.hasPrefix(prev) {
                    accText = text
                } else if prev.hasPrefix(text) {
                    AppLogger.log(
                        "agent thinking delta - ignored (stale): prev len: \(prev.count), delta len: \(text.count)",
                        category: .nativeChat, level: .warning)
                    return
                } else {
                    // Partial overlap — same algorithm as the
                    // assistant branch. See the matching comment
                    // in `case "assistant"` for the issue #21
                    // (LCP≥8 LLM-rewrite) and the suffix-overlap
                    // (LCP<8 incremental-delta duplication) cases.
                    let lcp = EventInterpreter.longestCommonPrefix(prev, text)
                    if lcp >= StreamingDelta.partialOverlapMinLCP {
                        AppLogger.log(
                            "agent thinking delta - partial-overlap: lcp=\(lcp), prev len: \(prev.count), delta len: \(text.count)",
                            category: .nativeChat)
                        accText = String(prev.prefix(lcp)) + String(text.dropFirst(lcp))
                    } else {
                        let suffixOverlap = EventInterpreter.longestSuffixPrefixOverlap(prev, text)
                        if suffixOverlap == text.count {
                            AppLogger.log(
                                "agent thinking delta - ignored (text already in accumulator): prev len: \(prev.count), text len: \(text.count)",
                                category: .nativeChat, level: .debug)
                            return
                        }
                        if suffixOverlap > 0 {
                            AppLogger.log(
                                "agent thinking delta - suffix-overlap: overlap=\(suffixOverlap), prev len: \(prev.count), text len: \(text.count)",
                                category: .nativeChat)
                            accText = prev + String(text.dropFirst(suffixOverlap))
                        } else {
                            accText = prev + text
                        }
                    }
                }
                accumulatedThinkingTextByRun[runId] = accText
                let message = ChatMessage(
                    id: "\(runId):thinking",
                    text: accText,
                    // Local received time for sort — see the
                    // matching comment on `case "lifecycle"`
                    // `phase: "start"`. The thinking stream's
                    // server ts can be in the past relative to
                    // the user message; using `Date()` here
                    // guarantees the thinking bubble lands
                    // after the user message and after the
                    // toolCall it reasoned about.
                    timestamp: Date(),
                    role: "thinking",
                    state: "final",
                    runId: runId,
                    // Carry the server's per-run monotonic `seq`
                    // so the view's `chatMessages(for:)` can sort
                    // thinking BEFORE the response even when the
                    // chat event (carrying the same thinking text,
                    // id `runId:thinking`) arrives AFTER
                    // `lifecycle=end`. Without `seq`, a pure
                    // timestamp sort rendered the response
                    // (received first) before the thinking
                    // (received later).
                    seq: seq,
                    startedAt: nil,
                    endedAt: nil,
                    livenessState: nil,
                    toolCallId: nil,
                    toolName: nil,
                    stopReason: nil,
                    isFresh: true
                )
                await viewModel?.receiveMessage(message)
            case "tool":
                // Tool events share stream="tool" and discriminate via phase.
                // - start: tool begins (name + args)
                // - update: tool sends an intermediate state (progress, partial
                //   result). Many tools skip this; bash/web_search do not.
                // - result: tool finished (result or error)
                // Each toolCallId gets its own synthetic id so concurrent tools
                // (or the same tool called twice in one run) don't collide.
                // This branch is only hit when verbose level is on (the modern
                // path goes through `stream: "item"` and `stream: "command_output"`
                // below). The id namespace is shared with the modern `item`
                // path (`<runId>:toolCall:<toolCallId>`) so when the server
                // emits both legacy and modern events for the same tool, the
                // `upsert` collapses them to a single bubble instead of two.
                guard let toolCallId = data["toolCallId"]?.stringValue else {
                    AppLogger.log("agent tool event missing toolCallId, skipping. data keys: \(data.keys.map { $0 })", category: .nativeChat, level: .warning)
                    return
                }
                let toolName = data["name"]?.stringValue ?? ""
                // Resolve the legacy toolCallId to the modern canonical id
                // so both paths share the same `<runId>:toolCall:<canonical>`
                // / `<runId>:toolResult:<canonical>` bubble id and the
                // same `toolKey` for the per-call dicts. Without this
                // alias resolution, two failure modes surface when the
                // server emits both legacy and modern events for the same
                // logical tool with different toolCallIds (or even with
                // the same id, where the legacy cleanup race drops the
                // modern entry's startedAt). See the doc comment on
                // `toolCallIdAliasByRun` above for the full rationale.
                //
                // Three-tier resolution:
                // 1. Exact alias hit — the modern path already
                //    registered `<legacyId> → canonical`. Use it.
                // 2. The legacy path fired BEFORE the modern path —
                //    the legacy's own `phase=start` registered
                //    `<legacyId> → legacyId`. Adopt that identity.
                // 3. The modern path fired earlier with a
                //    DIFFERENT canonical, and the alias map does
                //    NOT have this legacyId — adopt the most
                //    recently registered canonical for this runId.
                //    Safe within a single run because tools are
                //    sequential: at any moment at most one tool
                //    call's `phase=start` has fired without its
                //    matching result. We track the latest
                //    canonical per run via `toolLatestCanonicalByRun`.
                let resolvedCanonical: String = {
                    if let hit = toolCallIdAliasByRun[runId]?[toolCallId] {
                        return hit
                    }
                    if let latest = toolLatestCanonicalByRun[runId] {
                        return latest
                    }
                    return toolCallId
                }()
                let toolKey = "\(runId):\(resolvedCanonical)"
                if phase == "start" {
                    let text = MessageFormatters.formatToolCallBubbleText(name: toolName, arguments: data["args"])
                    AppLogger.log("agent tool start - tool: \(toolName), callId: \(toolCallId), canonical: \(resolvedCanonical)", category: .nativeChat)
                    // Remember BOTH the server's start timestamp (for the
                    // `startedAt` display field — "HH:MM" label) and the
                    // local-received time (for the sort `timestamp` so
                    // the toolCall sorts BEFORE the toolResult). The local
                    // time is needed because the gateway's clock is
                    // usually a few seconds behind the device, and using
                    // the server's ts for sort would push the toolCall's
                    // key past the toolResult's and render the response
                    // in reversed order.
                    toolStartedAtByCall[toolKey] = timestamp
                    toolReceivedAtByCall[toolKey] = Date()
                    // Register the toolCallId → canonical alias and
                    // record this canonical as the run's latest. The
                    // modern path reads both: the alias map to
                    // resolve when it fires later under a different
                    // toolCallId, and `toolLatestCanonicalByRun` to
                    // handle the case where the modern path fired
                    // earlier (this canonical stays in the alias
                    // map only if the modern path's toolCallId
                    // matches ours; otherwise the modern path's own
                    // canonical sits in the alias map and this
                    // legacy start updates the "latest" pointer so
                    // future legacy events for the SAME logical
                    // tool resolve to the same canonical). One
                    // legacy event per tool call typically — the
                    // race that matters is "modern fires first
                    // with id M, then legacy fires with id L for
                    // the same tool" — covered by the legacy's
                    // `toolLatestCanonicalByRun` lookup above.
                    var perRunAlias = toolCallIdAliasByRun[runId] ?? [:]
                    perRunAlias[toolCallId] = resolvedCanonical
                    toolCallIdAliasByRun[runId] = perRunAlias
                    toolLatestCanonicalByRun[runId] = resolvedCanonical
                    let message = ChatMessage(
                        id: "\(runId):toolCall:\(resolvedCanonical)",
                        text: text,
                        timestamp: toolReceivedAtByCall[toolKey] ?? Date(),
                        role: "toolCall",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: timestamp,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: resolvedCanonical,
                        toolName: toolName,
                        stopReason: nil,
                        isFresh: true
                    )
                    await viewModel?.receiveMessage(message)
                } else if phase == "update" {
                    // Intermediate state. Refresh the toolCall bubble with the
                    // latest args/progress so the user sees the tool is alive.
                    // Re-stamp `startedAt` from the saved `start` event so
                    // the bubble's "HH:mm" prefix doesn't disappear when
                    // the server omits startedAt on update events. Use the
                    // local-received time of the start event (NOT the
                    // update event's `timestamp`) for the sort key — see
                    // the matching comment in the `phase: "start"`
                    // branch and in `case "item"` for the modern path.
                    let text = MessageFormatters.formatToolCallBubbleText(name: toolName, arguments: data["args"])
                    AppLogger.log("agent tool update - tool: \(toolName), callId: \(toolCallId), text len: \(text.count)", category: .nativeChat)
                    let startedAt = toolStartedAtByCall[toolKey] ?? timestamp
                    let message = ChatMessage(
                        id: "\(runId):toolCall:\(resolvedCanonical)",
                        text: text,
                        timestamp: toolReceivedAtByCall[toolKey] ?? Date(),
                        role: "toolCall",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: startedAt,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: resolvedCanonical,
                        toolName: toolName,
                        stopReason: nil,
                        isFresh: true
                    )
                    await viewModel?.receiveMessage(message)
                } else if phase == "result" {
                    let resultValue = data["result"]?.value
                    let text = MessageFormatters.formatToolResultText(result: resultValue)
                    let isError = (data["isError"]?.value as? Bool) ?? false
                    AppLogger.log("agent tool result - tool: \(toolName), callId: \(toolCallId), canonical: \(resolvedCanonical), isError: \(isError), text len: \(text.count)", category: .nativeChat)
                    let startedAt = toolStartedAtByCall[toolKey]
                        ?? (startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil)
                    // toolResult id also unified to the same namespace so
                    // `command_output` / `item` (end) for the same call
                    // upsert into the same entry instead of producing
                    // separate bubbles.
                    //
                    // IMPORTANT: do NOT clear `toolStartedAtByCall[toolKey]`
                    // here. The modern `command_output (end)` handler reads
                    // the same entry to populate its own toolResult's
                    // `startedAt`; clearing it here would race with the
                    // modern path and silently drop the start time. The
                    // modern path's `command_output (end)` handler clears
                    // the entry itself at line ~1142 (after its own read),
                    // so this legacy handler leaving the entry alone is
                    // safe and prevents the startedAt-loss regression.
                    let message = ChatMessage(
                        id: "\(runId):toolResult:\(resolvedCanonical)",
                        text: text,
                        // Local received time for sort — see the
                        // matching comment on `case "lifecycle"`
                        // `phase: "start"`. The previous
                        // server-timestamp value could be a few
                        // seconds before the user message due to
                        // gateway clock skew, which would render
                        // the toolResult above the user bubble.
                        timestamp: Date(),
                        role: "toolResult",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: startedAt,
                        endedAt: timestamp,
                        livenessState: nil,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        stopReason: isError ? "error" : nil,
                        isFresh: true
                    )
                    await viewModel?.receiveMessage(message)
                    // Tool call is fully done — the modern
                    // `command_output (end)` handler reads
                    // `toolStartedAtByCall[toolKey]` to populate its
                    // own toolResult ChatMessage's `startedAt`; if it
                    // fires AFTER this legacy result, clearing the
                    // entry here would race and drop the start time
                    // (user-reported 2026-07-02 "toolResult has no
                    // start time" regression). The modern path's
                    // `command_output (end)` handler clears the
                    // entry itself after its own read, so leaving the
                    // entry alone here is the correct fix. Memory
                    // growth is bounded per run (one entry per tool
                    // call, reclaimed at app restart).
                } else {
                    // Any phase other than "start" / "update" / "result"
                    // is a server shape we don't recognize. Log a
                    // warning so the gap is visible (unknown phase →
                    // server contract drift; would otherwise be
                    // silently swallowed by the if/else-if chain). The
                    // `guard let toolCallId` above has already
                    // established the callId, so we can include it in
                    // the log for cross-referencing with `tool start`
                    // / `tool result` lines.
                    AppLogger.log("agent tool UNHANDLED phase=\(phase ?? "nil") tool=\(toolName) callId=\(toolCallId) runId=\(runId) seq=\(seq ?? -1) data=\(EventInterpreter.serializeDataForLog(data))", category: .nativeChat, level: .warning)
                }
            case "item":
                // Modern tool/command/patch lifecycle events. Each toolCallId
                // emits one `item` event per kind: tool, command (bash/exec),
                // patch, search, analysis. We map them all to a toolCall
                // bubble keyed by the same `<runId>:toolCall:<canonical>`
                // namespace as the legacy `tool` path (canonical =
                // `toolCallId ?? itemId`) so when the server emits both
                // legacy and modern events for the same tool, the
                // `upsert` collapses them to a single bubble. For
                // non-command kinds, the actual result content is in the
                // `stream: "tool"` event which is only emitted when verbose
                // level is on; without it the toolResult bubble only has
                // metadata (status/error). For command kind, the output
                // arrives via `stream: "command_output"` events.
                guard let itemId = data["itemId"]?.stringValue else {
                    AppLogger.log("agent item event missing itemId, skipping. keys: \(data.keys.map { $0 })", category: .nativeChat, level: .warning)
                    return
                }
                let itemPhase = data["phase"]?.stringValue
                let kind = data["kind"]?.stringValue ?? "tool"
                let name = data["name"]?.stringValue ?? ""
                let status = data["status"]?.stringValue
                let progressText = data["progressText"]?.stringValue
                let summary = data["summary"]?.stringValue
                let errorText = data["error"]?.stringValue
                let itemToolCallId = data["toolCallId"]?.stringValue
                let meta = data["meta"]?.stringValue
                // Canonical id: prefer the toolCallId (shared with the
                // legacy `tool` path), fall back to itemId. Same key
                // means `upsert` will replace the legacy bubble's entry
                // rather than appending a second one.
                let canonical = itemToolCallId ?? itemId
                let toolKey = "\(runId):\(canonical)"
                AppLogger.log("agent item - kind: \(kind), phase: \(itemPhase ?? "nil"), itemId: \(itemId), status: \(status ?? "?")", category: .nativeChat)
                // Build text representation for the toolCall bubble. Use the
                // shared formatter so live bubbles match the history format
                // ("ToolCall: <name>" + "key: value" lines per arg). The
                // modern `item` event does not include the actual command
                // string in its data, so when args are missing the bubble
                // uses `meta` (server-side human-readable summary) as the
                // second line. When args are present (legacy `stream: "tool"`
                // path, or future server changes), they flow through
                // automatically. progressText is appended during running
                // state so the user sees the tool is alive.
                var callText = MessageFormatters.formatToolCallBubbleText(name: name, arguments: data["args"], meta: meta)
                if callText.isEmpty {
                    callText = "ToolCall: \(kind)"
                }
                if let progressText, !progressText.isEmpty {
                    callText += "\n" + progressText
                }
                if itemPhase == "start" {
                    // Tool-boundary finalize: any assistant text the
                    // model emitted BEFORE this tool (preamble or
                    // post-previous-tool thinking) becomes its own
                    // assistant bubble. Without this, the buffer
                    // would carry over and the next fragment's
                    // partial-overlap rewrite (LCP ≥ 8) or
                    // plain-concat branch (LCP < 8) would stitch
                    // the prior fragment's tail onto the new fragment's
                    // head, producing the user-reported Frankenstein
                    // bubble. The fragment counter is bumped inside
                    // `finalizeAssistantFragmentIfAny`, so subsequent
                    // deltas in the new segment go to `runId:assistant:<N+1>`.
                    await finalizeAssistantFragmentIfAny(runId)
                    // Resolve to the canonical id used by any prior
                    // legacy `tool phase=start` for the same runId.
                    // If a legacy event fired earlier with a
                    // different toolCallId and registered
                    // `<runId>:legacyId → legacyId` in the alias
                    // map, we want THIS modern event to share the
                    // same canonical id so legacy + modern writes
                    // collapse to one bubble. Scan the existing
                    // alias map for any pre-registered entry that
                    // already maps to a stable canonical (the
                    // legacy path's `phase=start` registers
                    // `toolCallId → toolCallId`); when the modern
                    // path fires, it adopts that legacy canonical
                    // as its own. The scan is bounded by the
                    // number of tool calls in a single run (a
                    // small handful).
                    let resolvedCanonical: String = {
                        for (aliasKey, aliasedValue) in toolCallIdAliasByRun[runId] ?? [:] {
                            // Legacy registered `L → L`. If our
                            // canonical (or itemId) matches the
                            // legacy's value, that's the bridge.
                            if aliasedValue == canonical || aliasedValue == itemId {
                                return aliasKey
                            }
                        }
                        return canonical
                    }()
                    let resolvedToolKey = "\(runId):\(resolvedCanonical)"
                    // Remember BOTH the server's start timestamp (for
                    // `startedAt` display — "HH:MM" label) and the
                    // local-received time (for the sort key so the
                    // toolCall sorts BEFORE the toolResult AND after
                    // the user message). The server's ts is unreliable
                    // for sort because the gateway clock is usually
                    // a few seconds behind the device, which would
                    // push the response's sort key before the user
                    // message's `Date()`-based key. Mirrors the
                    // legacy `case "tool"` `phase: "start"` branch.
                    toolStartedAtByCall[resolvedToolKey] = timestamp
                    toolReceivedAtByCall[resolvedToolKey] = Date()
                    // Register the toolCallId → canonical alias so
                    // the legacy `stream: "tool"` path can resolve
                    // its toolCallId to this canonical id and
                    // share the same bubble id / toolKey. We map
                    // both `toolCallId` → `canonical` (identity
                    // case) and `itemId` → `canonical` (legacy may
                    // surface the call under the itemId when the
                    // server doesn't supply a toolCallId on the
                    // legacy event). Cleared at `lifecycle=end`.
                    var perRunAlias = toolCallIdAliasByRun[runId] ?? [:]
                    perRunAlias[resolvedCanonical] = resolvedCanonical
                    if resolvedCanonical != itemId {
                        perRunAlias[itemId] = resolvedCanonical
                    }
                    toolCallIdAliasByRun[runId] = perRunAlias
                    // Mirror the legacy path: record this canonical
                    // as the run's latest so a later legacy event
                    // for the SAME logical tool can adopt it via
                    // `toolLatestCanonicalByRun`.
                    toolLatestCanonicalByRun[runId] = resolvedCanonical
                }
                if itemPhase == "end" {
                    // End phase. If there's a summary (e.g., command output
                    // captured at end), fold it into a toolResult bubble so
                    // the user can read what the tool produced. Otherwise just
                    // mark the toolCall as ended. Id unified with the
                    // `tool` (result) and `command_output` namespaces.
                    let resultText = summary ?? errorText ?? ""
                    if !resultText.isEmpty {
                        let message = ChatMessage(
                            id: "\(runId):toolResult:\(canonical)",
                            text: resultText,
                            // Local received time for sort — see
                            // the matching comment on
                            // `case "lifecycle"` `phase: "start"`.
                            timestamp: Date(),
                            role: "toolResult",
                            state: "final",
                            runId: runId,
                            seq: seq,
                            startedAt: toolStartedAtByCall[toolKey]
                                ?? (startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil),
                            endedAt: timestamp,
                            livenessState: nil,
                            toolCallId: canonical,
                            toolName: name,
                            stopReason: (errorText != nil) ? "error" : nil,
                            isFresh: true
                        )
                        await viewModel?.receiveMessage(message)
                    }
                }
                // Always update the toolCall bubble so start/update/end phases
                // surface a running indicator. In-place update by id matches
                // the same item across phases.
                let startedAt = toolStartedAtByCall[toolKey]
                    ?? (startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil)
                // For the toolCall's sort `timestamp`, use the
                // local-received time of `item (start)` (or
                // `tool (start)` for the legacy path) so the toolCall
                // sorts BEFORE the toolResult AND after the user
                // message. The local time is required because the
                // gateway's server `payload.ts` is typically a few
                // seconds in the past; using the server ts directly
                // would either (a) render the toolResult above the
                // toolCall when `command_output (end)` arrives before
                // `item (end)`, or (b) render the entire response
                // above the user message due to clock skew.
                let toolCallSortTimestamp = toolReceivedAtByCall[toolKey] ?? Date()
                let message = ChatMessage(
                    id: "\(runId):toolCall:\(canonical)",
                    text: callText,
                    timestamp: toolCallSortTimestamp,
                    role: "toolCall",
                    state: itemPhase == "end" ? "final" : "streaming",
                    runId: runId,
                    seq: seq,
                    startedAt: startedAt,
                    endedAt: itemPhase == "end" ? timestamp : nil,
                    livenessState: nil,
                    toolCallId: canonical,
                    toolName: name,
                    stopReason: nil,
                    isFresh: true
                )
                await viewModel?.receiveMessage(message)
            case "command_output":
                // Per-item command output stream. For exec/bash tools the
                // result body arrives here in `output` (incremental on
                // `phase: "delta"`, final on `phase: "end"`). Accumulate into
                // a toolResult bubble keyed by the unified
                // `<runId>:toolResult:<canonical>` namespace (canonical =
                // `toolCallId ?? itemId`) so it upserts into the same
                // entry created by `item` (end) / legacy `tool` (result).
                //
                // BUG-8 (user-reported 2026-07-07): the streaming
                // toolResult bubble showed only a partial chunk of the
                // tool's stdout (cut off mid-JSON), even though the
                // server's later `chat.history` returned the FULL
                // text. Root cause: each `command_output (delta)` event
                // upserted its `output` chunk into the cache (replace
                // by id), overwriting the previous chunk. When the
                // final `command_output (end)` arrived, its `output`
                // field was either incremental (last chunk only) or
                // short of the full accumulated body — leaving the
                // bubble with only the last few lines of stdout and
                // the `exit=0 duration=Nms` trailer appended.
                //
                // The fix: maintain a per-toolKey accumulator
                // (`accumulatedToolOutputByCall`) that concatenates
                // every event's `output` field across phases. On
                // `phase: "end"`, use the accumulator's text as
                // `resultText` (it's monotonically growing; the
                // end event's own `output` is a strict subset if it's
                // incremental, or equal if the SDK sends the full
                // final text). Suffix-overlap dedup (same as the
                // `accumulatedAssistantTextByRun` path) avoids
                // doubling the boundary between an event's tail and
                // the next event's head when the SDK sends a few
                // bytes of overlap for safety.
                guard let itemId = data["itemId"]?.stringValue else {
                    AppLogger.log("agent command_output missing itemId, skipping. keys: \(data.keys.map { $0 })", category: .nativeChat, level: .warning)
                    return
                }
                let outputToolCallId = data["toolCallId"]?.stringValue
                let canonical = outputToolCallId ?? itemId
                let toolKey = "\(runId):\(canonical)"
                let outputPhase = data["phase"]?.stringValue
                let output = data["output"]?.stringValue ?? ""
                let toolName = data["name"]?.stringValue ?? ""
                let exitCode = data["exitCode"]?.intValue
                let durationMs = data["durationMs"]?.intValue
                AppLogger.log("agent command_output - phase: \(outputPhase ?? "nil"), itemId: \(itemId), output len: \(output.count), exitCode: \(exitCode.map(String.init) ?? "nil")", category: .nativeChat)
                // Accumulate `output` across phases. Suffix-overlap
                // dedup mirrors `accumulatedAssistantTextByRun`'s
                // pattern (the SDK occasionally sends a few bytes of
                // overlap between adjacent chunks for safety; without
                // dedup the boundary would be doubled).
                if !output.isEmpty {
                    let prev = accumulatedToolOutputByCall[toolKey] ?? ""
                    if prev.isEmpty {
                        accumulatedToolOutputByCall[toolKey] = output
                    } else if output.hasPrefix(prev) {
                        // Server sent the full final text on end —
                        // accept it as the new accumulator value
                        // (it includes any text the deltas may have
                        // missed).
                        accumulatedToolOutputByCall[toolKey] = output
                    } else if prev.hasSuffix(output) {
                        // Delta already accumulated; no-op.
                    } else {
                        // Find the longest suffix of `prev` that's a
                        // prefix of `output`; concatenate without
                        // the overlap. Common when both ends emit
                        // partial chunks.
                        var overlap = 0
                        let maxOverlap = min(prev.count, output.count)
                        if maxOverlap > 0 {
                            for k in stride(from: maxOverlap, through: 1, by: -1) {
                                let prevSuffix = prev.suffix(k)
                                if output.hasPrefix(prevSuffix) {
                                    overlap = k
                                    break
                                }
                            }
                        }
                        accumulatedToolOutputByCall[toolKey] =
                            prev + output.dropFirst(overlap)
                    }
                }
                var resultText = accumulatedToolOutputByCall[toolKey] ?? output
                if outputPhase == "end" {
                    // Append exit info so the bubble shows the command's
                    // disposition even if `output` is empty.
                    var trailer: [String] = []
                    if let exitCode { trailer.append("exit=\(exitCode)") }
                    if let durationMs { trailer.append("duration=\(durationMs)ms") }
                    if !trailer.isEmpty {
                        if !resultText.isEmpty { resultText += "\n" }
                        resultText += trailer.joined(separator: " ")
                    }
                }
                guard !resultText.isEmpty else { return }
                let startedAt = toolStartedAtByCall[toolKey]
                    ?? (startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil)
                let message = ChatMessage(
                    id: "\(runId):toolResult:\(canonical)",
                    text: resultText,
                    // Local received time for sort — see the
                    // matching comment on `case "lifecycle"`
                    // `phase: "start"`. The previous server-ts
                    // value could be a few seconds before the
                    // user message; using `Date()` guarantees
                    // the toolResult lands after the user
                    // message and after the toolCall it pairs
                    // with.
                    timestamp: Date(),
                    role: "toolResult",
                    state: outputPhase == "end" ? "final" : "streaming",
                    runId: runId,
                    seq: seq,
                    startedAt: startedAt,
                    endedAt: outputPhase == "end" ? timestamp : nil,
                    livenessState: nil,
                    toolCallId: canonical,
                    toolName: toolName,
                    stopReason: exitCode.map { $0 != 0 ? "error" : nil } ?? nil,
                    isFresh: true
                )
                await viewModel?.receiveMessage(message)
                // Cleanup of `toolStartedAtByCall` only — the
                // `toolReceivedAtByCall` value is the toolCall's sort
                // timestamp and is consumed by the `item phase=end`
                // branch (line 954), which for exec/bash tools may
                // arrive AFTER this `command_output (end)`. Clearing
                // `toolReceivedAtByCall` here would make `item (end)`
                // fall back to `Date()` and put the toolCall's sort
                // key LATER than the toolResult's command_output (end)
                // timestamp — exactly the user-reported
                // "#11 toolCall appears below #12 toolResult" bug.
                // Cleanup of `toolStartedAtByCall` is correct here
                // because we want `command_output (end)` to see the
                // recorded start time (see the note in the legacy
                // `tool (result)` branch for the symmetric reasoning).
                // The orphaned `toolReceivedAtByCall` entries are
                // bounded by the number of tool calls in a single run
                // and are reclaimed at app restart; the dict is not
                // expected to grow unboundedly across runs in a single
                // session because lifecycle=end typically follows the
                // last tool's item (end) shortly after.
                //
                // BUG-8: also clear `accumulatedToolOutputByCall`
                // on `phase: "end"` so the next tool call (with a
                // different `toolKey`) starts fresh. Without this,
                // a reuse of the same `toolKey` would inherit stale
                // text — see also the lifecycle=end bulk cleanup
                // below.
                if outputPhase == "end" {
                    toolStartedAtByCall.removeValue(forKey: toolKey)
                    accumulatedToolOutputByCall.removeValue(forKey: toolKey)
                }
            default:
                // plan, approval, patch, compaction, error — not yet surfaced.
                AppLogger.log("agent UNHANDLED stream=\(payload.stream) runId=\(payload.runId) seq=\(payload.seq ?? -1) data=\(EventInterpreter.serializeDataForLog(data))", category: .nativeChat)
            }

        case .chat(let chat):
            // Log full structure so we can see if server delivers thinking as
            // content blocks here (the 2026.5.28 model) vs as separate agent events.
            // Mirrors the sessionMessage log below so we can spot {type:"thinking", thinking:"..."} blocks.
            var role = "?"
            var blockSummaries: [String] = []
            var thinkingBlocks: [(text: String, blockIndex: Int)] = []
            var textBlocks: [(text: String, blockIndex: Int)] = []
            if let msgAny = chat.message?.value {
                // AnyCodable stores dicts/arrays as [String: AnyCodable] / [AnyCodable] — unwrap recursively.
                let unwrapped = EventInterpreter.unwrapAnyCodable(msgAny)
                if let dict = unwrapped as? [String: Any] {
                    role = (dict["role"] as? String) ?? "?"
                    if let content = dict["content"] as? [Any] {
                        for (i, block) in content.enumerated() {
                            if let blockDict = block as? [String: Any] {
                                var parts: [String] = ["#\(i)"]
                                if let type = blockDict["type"] as? String { parts.append("type=\(type)") }
                                if let t = blockDict["text"] as? String, !t.isEmpty {
                                    let preview = t.prefix(80)
                                    parts.append("text=\"\(preview)\(t.count > 80 ? "…(\(t.count))" : "")\"")
                                    // Capture full text for bubble creation.
                                    // The preview above is log-only; the
                                    // bubble gets the complete text so the
                                    // user can read the model's full reply.
                                    textBlocks.append((text: t, blockIndex: i))
                                }
                                if let th = blockDict["thinking"] as? String, !th.isEmpty {
                                    let preview = th.prefix(80)
                                    parts.append("thinking=\"\(preview)\(th.count > 80 ? "…(\(th.count))" : "")\"")
                                    // Capture the full (untruncated) text for
                                    // bubble creation. The preview above is
                                    // log-only; the bubble gets the complete
                                    // thinking so the user can read the
                                    // model's full reasoning.
                                    thinkingBlocks.append((text: th, blockIndex: i))
                                }
                                if let n = blockDict["name"] as? String { parts.append("name=\(n)") }
                                if let id = blockDict["id"] as? String { parts.append("id=\(id)") }
                                blockSummaries.append(parts.joined(separator: " "))
                            } else {
                                blockSummaries.append("#\(i)=<\(type(of: block))>")
                            }
                        }
                    } else if let content = dict["content"] {
                        blockSummaries = ["content=\(EventInterpreter.formatValue(content))"]
                    }
                } else if let str = unwrapped as? String {
                    blockSummaries = ["string=\"\(str.prefix(100))\""]
                }
            }
            AppLogger.log("chat event runId=\(chat.runId ?? "nil") sessionKey=\(chat.sessionKey ?? "nil") state=\(chat.state ?? "nil") role=\(role) blocks=[\(blockSummaries.joined(separator: " | "))] errorMessage=\(chat.errorMessage ?? "nil")", category: .nativeChat)
            // Verbose full-payload dump for diagnostics. The 80-char
            // blockSummaries preview above can hide content (e.g., a
            // thinking block's text is truncated to 80 chars, which
            // means a user grepping for a specific phrase like
            // (e.g., "Langfang") might miss the line if the match
            // sits past the 80-char cutoff). When the user reports
            // "thinking content not displayed during receiving" we
            // want the FULL message on disk so the bug is
            // reproducible from a Console.app log filter. The dump
            // is gated on a
            // user-toggle in ConfigurationManager (default OFF in
            // release, ON in debug) so production logs aren't
            // polluted. Gated on the user-toggleable
            // `logsNativeChat` setting (Settings → Debug & Logs →
            // "NativeChat verbose logs"). When the user enables
            // it, every chat / sessionMessage event's full JSON
            // payload is dumped to OSLog so the bug is
            // reproducible from a Console.app log filter. Until
            // the user toggles it on, the dump is silent and
            // production log volume is unaffected. The
            // `clientAppender` and `OSLog` writes always fire
            // (just at a less verbose level) for the existing
            // 80-char block preview above.
            if ConfigurationManager.shared.logsNativeChat {
                AppLogger.log(
                    "chat event FULL message dump (runId=\(chat.runId ?? "nil")): \(EventInterpreter.serializeDataForLog(chat.message?.value))",
                    category: .nativeChat)
            }
            // The previous implementation only logged the chat event's
            // content blocks. That was a regression for any server that
            // delivers the thinking payload as a `{type:"thinking",
            // thinking:"..."}` content block in the chat event rather
            // than as a separate `stream: "thinking"` agent event —
            // the thinking would reach the client but never make it into
            // the store, and the user would see
            // "thinking content not displayed during receiving" while
            // every other content type
            // (tool calls, assistant text) renders fine.
            //
            // Extract each thinking block and route it through the same
            // `viewModel?.receiveMessage` path the agent-event handler
            // uses. The id is `runId:thinking` (the same convention as
            // the `case "thinking"` agent handler) so the deterministic
            // UUID converter maps both paths to the same in-memory id
            // — if the server redundantly emits the thinking via both
            // the agent event and the chat event, the second arrival
            // upserts over the first and the bubble shows the latest
            // text rather than duplicating.
            //
            // Skip when `chat.runId` is nil: the chat event isn't
            // attached to a specific run, so we have no stable id
            // namespace to collate against the agent-event path.
            // (Logging-only events for global session state are rare
            // but possible; we'd rather drop the thinking than
            // create an unkeyed bubble that can't dedup.)
            if let runId = chat.runId, !thinkingBlocks.isEmpty {
                let now = Date()
                for (text, _) in thinkingBlocks {
                    let message = ChatMessage(
                        id: "\(runId):thinking",
                        text: text,
                        timestamp: now,
                        role: "thinking",
                        state: "final",
                        runId: runId,
                        seq: nil,
                        startedAt: nil,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: nil,
                        toolName: nil,
                        stopReason: nil,
                        isFresh: true
                    )
                    await viewModel?.receiveMessage(message)
                }
            }
            // Server slash-command responses (and any other server
            // text delivered via the chat-event stream rather than
            // the agent-event stream) arrive as content blocks with
            // `type: "text"`. The handler above captured them into
            // `textBlocks`; route them through the same
            // `viewModel?.receiveMessage` path the agent-event
            // handler uses. The id is just `runId` (matching the
            // agent `case "assistant"` id scheme) so any redundant
            // text from both streams upserts onto a single bubble
            // rather than producing a duplicate.
            //
            // Skip when `chat.runId` is nil (same rationale as the
            // thinking branch — no stable id namespace, would
            // create an unkeyed bubble that can't dedup).
            if let runId = chat.runId, !textBlocks.isEmpty {
                // Skip when the agent-event path is (or has been)
                // active for this runId. The agent-event path
                // writes a ChatMessage with proper startedAt /
                // endedAt from lifecycle=start / lifecycle=end.
                // The chat event's text blocks carry no timing
                // info, so upserting with `startedAt: nil,
                // endedAt: nil` here would wipe the time footer
                // the agent path set on the same id (`runId`).
                //
                // Keep this routing path for true
                // server-text-only flows — slash-command replies,
                // any other server reply that the agent-event
                // stream doesn't accompany — where the
                // agent-event path doesn't fire and this is the
                // only chance to display the response.
                let agentPathActiveOrDone =
                    accumulatedAssistantTextByRun[runId] != nil
                    || processedLifecycleEndByRun.contains(runId)
                if agentPathActiveOrDone {
                    AppLogger.log(
                        "chat event text - skipping routing (agent-event path active or completed for runId: \(runId))",
                        category: .nativeChat, level: .debug)
                } else {
                    let now = Date()
                    // Use `chat.state` if the server supplies one
                    // (typically "final" for slash-command responses);
                    // default to "final" so the bubble renders its
                    // complete content rather than the
                    // typing-indicator shell.
                    let resolvedState = chat.state ?? "final"
                    // Prefer the chat event's role when it's set;
                    // default to "assistant" so non-streaming slash-
                    // command replies render in the same visual lane
                    // as the agent's assistant deltas.
                    let resolvedRole = role == "?" ? "assistant" : role
                    // Concatenate text blocks in order. A single chat
                    // event can carry multiple text blocks (rare but
                    // possible — the SDK sometimes splits paragraphs).
                    // Use "\n\n" as the separator so the bubble's
                    // markdown renderer treats them as separate
                    // paragraphs rather than smushing them onto one
                    // line.
                    let combinedText = textBlocks
                        .sorted { $0.blockIndex < $1.blockIndex }
                        .map(\.text)
                        .joined(separator: "\n\n")
                    let message = ChatMessage(
                        // Fragment id (matches the streaming path's
                        // id scheme; slash-command replies don't
                        // produce streaming deltas so N is still 0
                        // here unless a prior tool split bumped it —
                        // either way the deterministic-UUID converter
                        // keeps this stable within the run).
                        id: "\(runId):assistant:\(assistantFragmentIdxByRun[runId, default: 0])",
                        text: combinedText,
                        timestamp: now,
                        role: resolvedRole,
                        state: resolvedState,
                        runId: runId,
                        seq: nil,
                        startedAt: nil,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: nil,
                        toolName: nil,
                        stopReason: nil,
                        isFresh: true
                    )
                    await viewModel?.receiveMessage(message)
                    // Slash-command responses are delivered via the
                    // chat-event stream (no agent-event lifecycle=end
                    // accompanies them), so the watchdog-armed
                    // `isSending = true` from `sendAsMessage` would
                    // stay stuck forever — the input box / send
                    // button would refuse touches until the 90s
                    // watchdog finally fires. Reset it here on the
                    // terminal chat event so the user can send the
                    // next message immediately.
                    //
                    // Skip on non-terminal states (a server that
                    // streams the slash-command reply across multiple
                    // chat events would deliver intermediate states
                    // here; resetting on each would prematurely drop
                    // `isSending` while text is still arriving).
                    if resolvedState == "final" {
                        viewModel?.resetSendState()
                    }
                }
            }

            // Recovery path: the server sends the authoritative
            // full assistant text in the chat event's `text`
            // content block when `state == "final"`. Use it to
            // correct our accumulator if the run is still
            // active. Skipped when:
            //  - state != "final" (chat events during streaming
            //    carry in-progress text, not authoritative)
            //  - runId is nil (no stable namespace to match)
            //  - accumulator is nil (lifecycle=end has already
            //    cleared it — bubble is already final)
            //  - chat event's text matches accumulator (no-op)
            if chat.state == "final",
               let runId = chat.runId,
               accumulatedAssistantTextByRun[runId] != nil,
               let unwrapped = chat.message?.value {
                let dict = EventInterpreter.unwrapAnyCodable(unwrapped)
                if let dict = dict as? [String: Any],
                   dict["role"] as? String == "assistant",
                   let content = dict["content"] as? [Any] {
                    let serverText = content
                        .compactMap { ($0 as? [String: Any])?["text"] as? String }
                        .joined(separator: "")
                    let prev = accumulatedAssistantTextByRun[runId] ?? ""
                    if !serverText.isEmpty, serverText != prev {
                        AppLogger.log(
                            "chat event - assistant state=final recovery: runId: \(runId), prev len: \(prev.count), server len: \(serverText.count)",
                            category: .nativeChat)
                        accumulatedAssistantTextByRun[runId] = serverText
                        // Do NOT clear the accumulator here —
                        // let the subsequent lifecycle=end run
                        // normally (it'll read the corrected
                        // accumulator value when computing
                        // effectiveFullText).
                        let resolvedStartedAt = assistantStartedAtByRun[runId]
                        // Use the current fragment id so the
                        // state=final recovery overwrites the
                        // streaming placeholder on the SAME slot
                        // (same UUID) instead of spawning a
                        // duplicate bubble at a different id.
                        let recoveryFragmentId = "\(runId):assistant:\(assistantFragmentIdxByRun[runId, default: 0])"
                        let message = ChatMessage(
                            id: recoveryFragmentId,
                            text: serverText,
                            // Local received time for sort —
                            // matches the lifecycle=start branch
                            // convention; the server's
                            // payload.ts could be in the past
                            // due to gateway clock skew.
                            timestamp: Date(),
                            role: "assistant",
                            state: "final",
                            runId: runId,
                            seq: nil,
                            startedAt: resolvedStartedAt,
                            endedAt: nil,
                            livenessState: nil,
                            toolCallId: nil, toolName: nil,
                            stopReason: nil,
                            isFresh: true
                        )
                        await viewModel?.receiveMessage(message)
                    }
                }
            }

        case .sessionMessage(let sm):
            // History/event-stream messages are typed OpenClawChatMessage.
            var blockSummaries: [String] = []
            // Track thinking blocks separately for the same reason
            // as the `case .chat` handler below — if the SDK emits
            // thinking as a typed `OpenClawChatMessageContent`
            // with `thinking: "..."` (rather than via the chat
            // event's untyped content blocks), we still need to
            // route it into a ChatMessage so the user sees it.
            // Use `messageId ?? message.id.uuidString` as the id
            // namespace — sessionMessage doesn't carry the agent
            // runId, so we can't collate with the agent-event
            // `case "thinking"` path's `runId:thinking` id. The
            // `_sm` suffix prevents accidental collision if a
            // later SDK version starts sending runId in
            // sessionMessage too.
            var thinkingEntries: [(text: String, namespace: String)] = []
            if let blocks = sm.message?.content {
                for (i, block) in blocks.enumerated() {
                    var parts: [String] = ["#\(i)", "type=\(block.type ?? "?")"]
                    if let t = block.text, !t.isEmpty { parts.append("text=\"\(t.prefix(80))\(t.count > 80 ? "…" : "")\"") }
                    if let th = block.thinking, !th.isEmpty {
                        parts.append("thinking=\"\(th.prefix(80))\(th.count > 80 ? "…" : "")\"")
                        thinkingEntries.append((text: th, namespace: "\(sm.messageId ?? sm.message?.id.uuidString ?? "sm-unknown"):thinking_sm"))
                    }
                    if let n = block.name { parts.append("name=\(n)") }
                    if let id = block.id { parts.append("id=\(id)") }
                    blockSummaries.append(parts.joined(separator: " "))
                }
            }
            AppLogger.log("sessionMessage messageId=\(sm.messageId ?? "nil") messageSeq=\(sm.messageSeq ?? -1) role=\(sm.message?.role ?? "nil") blocks=[\(blockSummaries.joined(separator: " | "))]", category: .nativeChat)
            // Same full-payload dump as `case .chat` — see the
            // matching comment there for the rationale (the
            // 80-char preview above hides content, which makes
            // grep-based log inspection for thinking text
            // unreliable).
            if ConfigurationManager.shared.logsNativeChat {
                AppLogger.log(
                    "sessionMessage FULL message dump (messageId=\(sm.messageId ?? "nil")): \(EventInterpreter.serializeDataForLog(sm.message))",
                    category: .nativeChat)
            }
            // Route each thinking block through the same
            // `viewModel?.receiveMessage` path the chat-event
            // handler uses. The id includes a `_sm` suffix so
            // the sessionMessage thinking bubble doesn't
            // accidentally collide with the agent-event
            // `runId:thinking` id when both paths emit the
            // same content for the same run.
            if !thinkingEntries.isEmpty {
                let now = Date()
                for entry in thinkingEntries {
                    let message = ChatMessage(
                        id: entry.namespace,
                        text: entry.text,
                        // Local received time for sort — see
                        // the matching comment on
                        // `case "lifecycle"` `phase: "start"`.
                        timestamp: now,
                        role: "thinking",
                        state: "final",
                        runId: nil,
                        seq: sm.messageSeq,
                        startedAt: nil,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: nil,
                        toolName: nil,
                        stopReason: nil,
                        isFresh: true
                    )
                    await viewModel?.receiveMessage(message)
                }
            }

        case .tick:
            AppLogger.log("transport tick", category: .nativeChat)
        case .seqGap:
            AppLogger.log("transport seqGap (out-of-order event detected)", category: .nativeChat)
        case .health(let ok):
            AppLogger.log("transport health ok=\(ok)", category: .nativeChat)
        @unknown default:
            // Forward-compat safety net: if the SDK adds a new
            // `OpenClawChatTransportEvent` case in a future version,
            // we want to see it in the log instead of silently
            // dropping the frame. `String(describing:)` renders the
            // case name + associated value (e.g. `sessionMetrics(42)`)
            // so we can grep for the new case and decide whether to
            // handle it.
            AppLogger.log("transport event UNHANDLED: \(event)", category: .nativeChat, level: .warning)
        }
    }

    // MARK: - Assistant fragment helpers

    /// Finalize the accumulated assistant-text buffer (if any) as
    /// a complete `role=assistant, state=final` bubble, then clear
    /// the buffer so the next segment starts fresh. Called at every
    /// `item phase=start` so each inter-tool "thinking aloud" text
    /// becomes its own bubble rather than being stitched onto the
    /// next response fragment via the LCP partial-overlap rewrite.
    ///
    /// Idempotent: called even when the buffer is empty (e.g. two
    /// item phase=start events in quick succession for the same
    /// toolCall — the second call finds an empty buffer and bails).
    /// The state stamp is `state="final"` because this fragment's
    /// text is logically complete at the tool boundary; the next
    /// fragment opens with a fresh accumulator.
    private func finalizeAssistantFragmentIfAny(_ runId: String) async {
        guard let buf = accumulatedAssistantTextByRun[runId], !buf.isEmpty else { return }
        let idx = assistantFragmentIdxByRun[runId, default: 0]
        let fragId = "\(runId):assistant:\(idx)"
        let resolvedStartedAt = assistantStartedAtByRun[runId]
        let resolvedEndedAt = Date()
        // Use the seq of the LAST streaming delta in this fragment
        // (recorded by `lastAssistantSeqByRun`) so the
        // streaming-metadata overlay carries the same seq the
        // streaming ChatMessage had. Without this, the finalize
        // would record `seq: nil`, which the per-run sort in
        // `sortForDisplay` interprets as `Int.max`, and the
        // finalized fragment would sort AFTER the response —
        // the reverse of the user's "earlier fragment first"
        // expectation.
        let fragmentLastSeq = lastAssistantSeqByRun[runId]
        let finalMessage = ChatMessage(
            id: fragId,
            text: buf,
            timestamp: resolvedEndedAt,
            role: "assistant",
            state: "final",
            runId: runId,
            seq: fragmentLastSeq,
            startedAt: resolvedStartedAt,
            endedAt: resolvedEndedAt,
            livenessState: nil,
            toolCallId: nil,
            toolName: nil,
            stopReason: nil,
            isFresh: false
        )
        AppLogger.log(
            "agent assistant fragment finalize: id=\(fragId.suffix(20)) runId-prefix=\(String(runId.prefix(8))) textLen=\(buf.count) textPreview=\"\(String(buf.prefix(60)))\(buf.count > 60 ? "…(\(buf.count))" : "")\"",
            category: .nativeChat)
        await viewModel?.receiveMessage(finalMessage)
        // Increment the fragment counter so the next segment writes
        // to a different id slot (the streaming upsert path also
        // reads `assistantFragmentIdxByRun[runId]`, so both paths
        // see the same N value here).
        assistantFragmentIdxByRun[runId] = idx + 1
        // Clear the accumulator so the next fragment starts from
        // an empty prev (so the LCP=0 plain-concat branch can't
        // accidentally Frankenstein the prior fragment's tail
        // onto the new fragment's head).
        accumulatedAssistantTextByRun[runId] = ""
    }

    // MARK: - Static helpers (kept here because they're only used in `.log(...)` paths)

    /// Length of the longest common prefix of two strings, in
    /// Unicode scalars (NOT grapheme clusters — emoji ZWJ
    /// sequences span multiple scalars and should not split
    /// mid-codepoint; using `Characters` would combine the ZWJ
    /// into a single grapheme and miss mid-sequence divergence).
    /// O(min(len(a), len(b))); for typical delta sizes (a few
    /// hundred to a few thousand chars) this is sub-millisecond
    /// on modern iPhones.
    private static func longestCommonPrefix(_ a: String, _ b: String) -> Int {
        let aChars = a.unicodeScalars
        let bChars = b.unicodeScalars
        let n = min(aChars.count, bChars.count)
        var i = 0
        while i < n {
            let aIdx = aChars.index(aChars.startIndex, offsetBy: i)
            let bIdx = bChars.index(bChars.startIndex, offsetBy: i)
            if aChars[aIdx] != bChars[bIdx] { break }
            i += 1
        }
        return i
    }

    /// Largest `l` such that `a.suffix(l) == b.prefix(l)` — the
    /// number of chars to skip on the leading edge of `b` when
    /// appending it after `a` to avoid duplicating the trailing
    /// portion of `a`. Returns 0 when there's no overlap (e.g.,
    /// `a` ends with "怎么用。" and `b` starts with "让我查" — the
    /// boundary is real, no trim needed). Returns `b.count` when
    /// `b` is fully contained in `a`'s tail — caller treats that as
    /// "already accumulated", drops the redundant delta. O(|a| +
    /// |b|) — uses KMP's failure function on `b` to walk `a` in
    /// one pass, tracking the trailing-match length.
    ///
    /// Sister function to `longestCommonPrefix`, which handles the
    /// LLM-rewrite shape (issue #21). This handles the incremental
    /// delta shape: when the server emits short, fragmentary deltas
    /// ("E", "°", "看看这个功能") rather than full cumulative
    /// re-sends, each new chunk starts with chars already at the end
    /// of the accumulator. Plain concat would duplicate that tail —
    /// this trims it before appending.
    ///
    /// Implementation note: a naive two-pointer walk (one from
    /// `a`'s tail, one from `b`'s head, moving inward) is WRONG for
    /// cases like `a = "X让我们查"`, `b = "让我们查一下"`. There
    /// `a.suffix(4) == b.prefix(4) == "让我们查"` (overlap = 4) but
    /// `a[end] != b[0]` ('查' != '让'), so the naive walk returns
    /// 0 — exactly the duplication we're trying to fix. KMP lets us
    /// find the correct trailing alignment in a single pass.
    private static func longestSuffixPrefixOverlap(_ a: String, _ b: String) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        let aChars = a.unicodeScalars
        let bChars = b.unicodeScalars
        let m = bChars.count
        guard m > 0, aChars.count > 0 else { return 0 }

        // KMP failure function for `b`: pi[i] = length of longest
        // proper prefix of b[0..i] that is also a suffix of b[0..i].
        var pi = [Int](repeating: 0, count: m)
        var i = 1
        while i < m {
            var j = pi[i - 1]
            while j > 0 && bChars[bChars.index(bChars.startIndex, offsetBy: i)] != bChars[bChars.index(bChars.startIndex, offsetBy: j)] {
                j = pi[j - 1]
            }
            if bChars[bChars.index(bChars.startIndex, offsetBy: i)] == bChars[bChars.index(bChars.startIndex, offsetBy: j)] {
                j += 1
            }
            pi[i] = j
            i += 1
        }

        // Walk through `a`. `k` tracks the current match length
        // against `b`. After processing the last char of `a`, `k`
        // equals the length of the longest prefix of `b` that
        // matches a SUFFIX of `a` (i.e., the trailing alignment).
        var k = 0
        for aIdx in 0..<aChars.count {
            let aChar = aChars[aChars.index(aChars.startIndex, offsetBy: aIdx)]
            let bCharAtK = bChars[bChars.index(bChars.startIndex, offsetBy: k)]
            while k > 0 && aChar != bCharAtK {
                k = pi[k - 1]
            }
            if aChar == bChars[bChars.index(bChars.startIndex, offsetBy: k)] {
                k += 1
            }
            if k > m { k = pi[m - 1] }
        }
        // Cap at b's length — full match can't exceed b.count, and
        // also avoids false positives where `b`'s tail happens to
        // re-appear in `a`'s interior.
        return min(k, m)
    }

    /// Full JSON dump of a payload value for log diagnostics.
    /// Preserves the complete nested structure so a user can grep
    /// for any key or value substring. Used wherever the typical
    /// debug question is "what did the server actually send?" — the
    /// full payload is more useful than a compact summary even at
    /// the cost of a longer log line. Compact (not pretty-printed)
    /// output keeps the line to one Console.app row and stays
    /// grep-friendly; `[.sortedKeys]` makes the output deterministic
    /// so two events with the same content produce the same string
    /// (helps with diff-style log inspection). Three entry points
    /// cover the three shapes seen in `OpenClawChatTransportEvent`:
    ///
    /// - `[String: AnyCodable]` — agent event's `data` field
    ///   (untyped dict from the gateway).
    /// - `Any?` — chat event's `message: AnyCodable?` (the same
    ///   untyped dict shape, but exposed as `Any` because the
    ///   field itself is an `AnyCodable`).
    /// - `Encodable` — sessionMessage's `OpenClawChatMessage`
    ///   (strongly-typed `Codable` value; uses `JSONEncoder`
    ///   instead of `JSONSerialization` because there's no
    ///   `AnyCodable` to unwrap first).
    private static func serializeDataForLog(_ data: [String: AnyCodable]) -> String {
        serializeDataForLog(data as Any)
    }

    private static func serializeDataForLog(_ value: Any?) -> String {
        guard let value else { return "null" }
        let unwrapped = EventInterpreter.unwrapAnyCodable(value)
        guard JSONSerialization.isValidJSONObject(unwrapped),
              let jsonData = try? JSONSerialization.data(
                withJSONObject: unwrapped, options: [.fragmentsAllowed, .sortedKeys]),
              let s = String(data: jsonData, encoding: .utf8) else {
            return String(describing: value)
        }
        return s
    }

    private static func serializeDataForLog<T: Encodable>(_ value: T?) -> String {
        guard let value else { return "null" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let jsonData = try? encoder.encode(value),
              let s = String(data: jsonData, encoding: .utf8) else {
            return String(describing: value)
        }
        return s
    }

    private static func formatValue(_ v: Any) -> String {
        if let s = v as? String {
            let preview = s.prefix(120)
            return "\"\(preview)\(s.count > 120 ? "…(\(s.count))" : "")\""
        }
        if let b = v as? Bool { return "\(b)" }
        if let i = v as? Int { return "\(i)" }
        if let d = v as? Double { return "\(d)" }
        if let arr = v as? [Any] { return "[\(arr.count) items]" }
        if let dict = v as? [String: Any] { return "{\(dict.count) keys:\(dict.keys.sorted().prefix(8).joined(separator: ","))}" }
        if v is NSNull { return "null" }
        return "<\(type(of: v))>"
    }

    private static func unwrapAnyCodable(_ v: Any) -> Any {
        if let ac = v as? AnyCodable { return EventInterpreter.unwrapAnyCodable(ac.value) }
        if let arr = v as? [Any] { return arr.map { EventInterpreter.unwrapAnyCodable($0) } }
        if let arr = v as? [AnyCodable] { return arr.map { EventInterpreter.unwrapAnyCodable($0) } }
        if let dict = v as? [String: Any] { return dict.mapValues { EventInterpreter.unwrapAnyCodable($0) } }
        if let dict = v as? [String: AnyCodable] { return dict.mapValues { EventInterpreter.unwrapAnyCodable($0) } }
        return v
    }
}
