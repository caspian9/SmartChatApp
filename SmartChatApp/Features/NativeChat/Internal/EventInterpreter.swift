import SwiftUI
import OpenClawChatUI
import OpenClawKit

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
    /// Per-run thinking text accumulator. Mirrors
    /// `accumulatedAssistantTextByRun` for the thinking stream —
    /// without an accumulator, incremental deltas ("thinking
    /// part 1" + " part 2" + " part 3") would each upsert over
    /// the previous entry and the final bubble would contain
    /// only the last fragment. The accumulator preserves the
    /// full thinking across the run, similar to the assistant
    /// text path. Cleared on `lifecycle=end`.
    private var accumulatedThinkingTextByRun: [String: String] = [:]

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
                    // placeholder (empty text) is short-circuited by the
                    // pre-filters inside `needsMarkdown` and the final-state
                    // message is computed on first view read. No need to
                    // pre-mark by runId.
                    await MainActor.run {
                        MarkdownStreamManager.shared.holder(for: runId)
                    }
                    // Remember the start time so subsequent `assistant`
                    // deltas can re-stamp it (the per-delta
                    // `ChatMessage` below has no other way to know it).
                    let startedAt = startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : timestamp
                    assistantStartedAtByRun[runId] = startedAt
                    let message = ChatMessage(
                        id: runId,
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
                    // TEMP DIAG: confirm the cache-anchor
                    // resolution picks `assistantStartedAtByRun[runId]`
                    // (the lifecycle=start wall clock), which is the
                    // same value the server's `chat.history` uses as
                    // the message's `timestamp` field. Earlier
                    // implementations of this logic got the priority
                    // order wrong; the current order is `start` →
                    // event-`startedAt` → event-`endedAt` → now().
                    // Log both candidates so future regressions show
                    // the split. The `timestamp: chosenAnchor` line
                    // below uses the same value — sharing
                    // `chosenAnchor` here so the log and the actual
                    // cache write are guaranteed to match.
                    let chosenAnchor = assistantStartedAtByRun[runId]
                        ?? (startedAtMs > 0
                            ? Date(timeIntervalSince1970: startedAtMs / 1000)
                            : (endedAtMs > 0
                                ? Date(timeIntervalSince1970: endedAtMs / 1000)
                                : Date()))
                    AppLogger.log("agent lifecycle end - cache anchor: startedAtRun=\(assistantStartedAtByRun[runId]?.timeIntervalSince1970 ?? -1) endedAtMs=\(endedAtMs) → chosen=\(chosenAnchor.timeIntervalSince1970)", category: .nativeChat)
                    // Flush the markdown stream buffer and read the full
                    // accumulated text so it can be persisted. The
                    // authoritative source is our local accumulator (server
                    // deltas turn out to be incremental on device, not
                    // cumulative as the prior comment assumed —
                    // `MarkdownStreamManager.currentText()` would return
                    // just the last delta's suffix). Fall back to the
                    // holder's tracked text if our accumulator is empty
                    // (e.g., agent produced no assistant text, only
                    // thinking/tools).
                    let fullText: String = await MainActor.run {
                        MarkdownStreamManager.shared.end(messageId: runId)
                        return MarkdownStreamManager.shared.currentText(for: runId) ?? ""
                    }
                    let effectiveFullText: String = {
                        if let acc = accumulatedAssistantTextByRun[runId], !acc.isEmpty {
                            return acc
                        }
                        return fullText
                    }()
                    AppLogger.log("agent lifecycle end - fullText len: \(fullText.count), accumulated len: \(accumulatedAssistantTextByRun[runId]?.count ?? -1), effective: \(effectiveFullText.count) for runId: \(runId)", category: .nativeChat)
                    // Pull startedAt from the lifecycle=start record
                    // when the server omits it on the end event (the
                    // end event's `startedAt` is sometimes 0). Falls
                    // back to whatever the event provided, then to
                    // the event timestamp as a last resort.
                    let resolvedStartedAt: Date? = {
                        if startedAtMs > 0 { return Date(timeIntervalSince1970: startedAtMs / 1000) }
                        return assistantStartedAtByRun[runId] ?? timestamp
                    }()
                    let message = ChatMessage(
                        id: runId,
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
                    // PERSIST GATE companion: the final message has
                    // been upserted into the cache, so any in-flight
                    // streaming deltas (now obsolete) must be cleared
                    // to avoid the view stacking them on top of the
                    // cached final. Awaiting the upsert above before
                    // clearing pending eliminates the
                    // "pending cleared before upsert landed" race.
                    viewModel?.clearPending(for: sessionKey)
                    // Cleanup: drop the per-run accumulators. Holder
                    // is released below — `MarkdownStreamManager.release`
                    // would have been the right place to also nil the
                    // accumulators, but they live on EventInterpreter
                    // not on the manager.
                    accumulatedAssistantTextByRun.removeValue(forKey: runId)
                    assistantStartedAtByRun.removeValue(forKey: runId)
                    accumulatedThinkingTextByRun.removeValue(forKey: runId)
                    // Holder no longer needed — SwiftUI flips to the static
                    // MarkdownCardView once state becomes "final", so the streaming
                    // view is dismantled. Release to bound memory across many turns.
                    await MainActor.run {
                        MarkdownStreamManager.shared.release(messageId: runId)
                    }
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
                let accText: String
                if !prev.isEmpty, text.hasPrefix(prev) {
                    // Cumulative: the new delta includes everything
                    // we already had plus more. Use it as-is so the
                    // bubble grows monotonically along the
                    // server's actual progression instead of
                    // producing a concatenation of past deltas.
                    accText = text
                } else if !prev.isEmpty, prev.hasPrefix(text) {
                    // Out-of-order / stale: the new delta is a
                    // state we already passed through. The
                    // accumulator is already ahead. Drop the
                    // delta so we don't regress the visible text.
                    AppLogger.log("agent assistant delta - ignored (stale): prev len: \(prev.count), delta len: \(text.count)", category: .nativeChat, level: .warning)
                    return
                } else {
                    // Incremental: delta is a fresh fragment that
                    // doesn't overlap with what we have. Append.
                    accText = prev + text
                }
                accumulatedAssistantTextByRun[runId] = accText
                await MainActor.run {
                    MarkdownStreamManager.shared.appendCumulative(messageId: runId, cumulative: text)
                }
                // Re-stamp startedAt from the lifecycle=start record
                // so the bubble's "HH:mm" prefix doesn't disappear
                // on each subsequent delta (the upsert-by-id path
                // would otherwise clobber the start time the first
                // delta put in).
                let startedAt = assistantStartedAtByRun[runId] ?? timestamp
                let message = ChatMessage(
                    id: runId,
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
                await viewModel?.receiveMessage(message)
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
                let accText: String
                if !prev.isEmpty, text.hasPrefix(prev) {
                    accText = text
                } else if !prev.isEmpty, prev.hasPrefix(text) {
                    AppLogger.log(
                        "agent thinking delta - ignored (stale): prev len: \(prev.count), delta len: \(text.count)",
                        category: .nativeChat, level: .warning)
                    return
                } else {
                    accText = prev + text
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
                let toolKey = "\(runId):\(toolCallId)"
                if phase == "start" {
                    let text = MessageFormatters.formatToolCallBubbleText(name: toolName, arguments: data["args"])
                    AppLogger.log("agent tool start - tool: \(toolName), callId: \(toolCallId)", category: .nativeChat)
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
                    let message = ChatMessage(
                        id: "\(runId):toolCall:\(toolCallId)",
                        text: text,
                        timestamp: toolReceivedAtByCall[toolKey] ?? Date(),
                        role: "toolCall",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: timestamp,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: toolCallId,
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
                        id: "\(runId):toolCall:\(toolCallId)",
                        text: text,
                        timestamp: toolReceivedAtByCall[toolKey] ?? Date(),
                        role: "toolCall",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: startedAt,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        stopReason: nil,
                        isFresh: true
                    )
                    await viewModel?.receiveMessage(message)
                } else if phase == "result" {
                    let resultValue = data["result"]?.value
                    let text = MessageFormatters.formatToolResultText(result: resultValue)
                    let isError = (data["isError"]?.value as? Bool) ?? false
                    AppLogger.log("agent tool result - tool: \(toolName), callId: \(toolCallId), isError: \(isError), text len: \(text.count)", category: .nativeChat)
                    let startedAt = toolStartedAtByCall[toolKey]
                        ?? (startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil)
                    // toolResult id also unified to the same namespace so
                    // `command_output` / `item` (end) for the same call
                    // upsert into the same entry instead of producing
                    // separate bubbles.
                    let message = ChatMessage(
                        id: "\(runId):toolResult:\(toolCallId)",
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
                    // Tool call is fully done — drop the start-timestamp
                    // entries so memory doesn't grow across many tool
                    // calls in one run.
                    toolStartedAtByCall.removeValue(forKey: toolKey)
                    toolReceivedAtByCall.removeValue(forKey: toolKey)
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
                    toolStartedAtByCall[toolKey] = timestamp
                    toolReceivedAtByCall[toolKey] = Date()
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
                if itemPhase == "end" {
                    toolStartedAtByCall.removeValue(forKey: toolKey)
                    toolReceivedAtByCall.removeValue(forKey: toolKey)
                }
            case "command_output":
                // Per-item command output stream. For exec/bash tools the
                // result body arrives here in `output` (incremental on
                // `phase: "delta"`, final on `phase: "end"`). Accumulate into
                // a toolResult bubble keyed by the unified
                // `<runId>:toolResult:<canonical>` namespace (canonical =
                // `toolCallId ?? itemId`) so it upserts into the same
                // entry created by `item` (end) / legacy `tool` (result).
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
                var resultText = output
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

    // MARK: - Static helpers (kept here because they're only used in `.log(...)` paths)

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
