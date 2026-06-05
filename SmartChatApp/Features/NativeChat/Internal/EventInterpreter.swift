import SwiftUI
import OpenClawChatUI
import OpenClawKit

@MainActor
final class EventInterpreter {
    weak var viewModel: NativeChatViewModel?

    func handleTransportEvent(_ event: OpenClawChatTransportEvent, sessionKey: String) async {
        switch event {
        case .agent(let payload):
            AppLogger.log("agent event - stream=\(payload.stream) runId=\(payload.runId) seq=\(payload.seq ?? -1) ts=\(payload.ts ?? 0) data=\(EventInterpreter.summarizeData(payload.data))", category: .nativeChat)
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
                    await MainActor.run {
                        MarkdownStreamManager.shared.holder(for: runId)
                        MarkdownCache.shared.setNeedsMarkdown(runId, value: true)
                    }
                    let message = ChatMessage(
                        id: runId,
                        text: "",
                        timestamp: timestamp,
                        role: "assistant",
                        state: "streaming",
                        runId: runId,
                        seq: seq,
                        startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : timestamp,
                        endedAt: nil,
                        livenessState: livenessState,
                        toolCallId: nil,
                        toolName: nil,
                        stopReason: nil,
                        isFresh: true
                    )
                    viewModel?.receiveMessage(message)
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
                    // Flush the markdown stream buffer and read the full accumulated
                    // text so it can be persisted. Deltas carry the full cumulative
                    // string per chunk; MarkdownViewTextKit holds the real body until
                    // end() releases it. Without this flush, the cache write below
                    // captures an empty body and the assistant reply is lost.
                    let fullText: String = await MainActor.run {
                        MarkdownStreamManager.shared.end(messageId: runId)
                        return MarkdownStreamManager.shared.currentText(for: runId) ?? ""
                    }
                    AppLogger.log("agent lifecycle end - fullText len: \(fullText.count) for runId: \(runId)", category: .nativeChat)
                    let message = ChatMessage(
                        id: runId,
                        text: fullText,
                        timestamp: timestamp,
                        role: "assistant",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
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
                    viewModel?.receiveMessage(message)
                    // Holder no longer needed — SwiftUI flips to the static
                    // MarkdownCardView once state becomes "final", so the streaming
                    // view is dismantled. Release to bound memory across many turns.
                    await MainActor.run {
                        MarkdownStreamManager.shared.release(messageId: runId)
                    }
                    // Only the real terminal signal resets the sending flag.
                    viewModel?.isSending = false
                }
            case "assistant":
                // Server sends the FULL cumulative text on every chunk (see
                // OpenClawChatUI/ChatViewModel.handleAgentEvent for the reference
                // behavior). Hand the cumulative string to the holder; it computes
                // the actual incremental suffix and feeds only that to the stream.
                // Without this we render `ABC` + `ABCDE` + `ABCDEF` as
                // `ABCABCDEABCDEF`. The placeholder at id=runId absorbs this update.
                let text = data["text"]?.stringValue ?? ""
                AppLogger.log("agent assistant delta - text len: \(text.count)", category: .nativeChat)
                guard !text.isEmpty else { return }
                await MainActor.run {
                    MarkdownStreamManager.shared.appendCumulative(messageId: runId, cumulative: text)
                }
                let message = ChatMessage(
                    id: runId,
                    text: text,
                    timestamp: timestamp,
                    role: "assistant",
                    state: "streaming",
                    runId: runId,
                    seq: seq,
                    startedAt: nil,
                    endedAt: nil,
                    livenessState: livenessState,
                    toolCallId: nil,
                    toolName: nil,
                    stopReason: nil,
                    isFresh: true
                )
                viewModel?.receiveMessage(message)
            case "thinking":
                // Thinking deltas are emitted as a separate stream from the
                // assistant text — they don't share an id with the assistant
                // placeholder. Use a synthetic id so the message dedups against
                // itself across deltas and renders as a thinking bubble.
                let text = data["text"]?.stringValue ?? ""
                AppLogger.log("agent thinking delta - text len: \(text.count)", category: .nativeChat)
                guard !text.isEmpty else { return }
                let message = ChatMessage(
                    id: "\(runId):thinking",
                    text: text,
                    timestamp: timestamp,
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
                viewModel?.receiveMessage(message)
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
                // below).
                guard let toolCallId = data["toolCallId"]?.stringValue else {
                    AppLogger.log("agent tool event missing toolCallId, skipping. data keys: \(data.keys.map { $0 })", category: .nativeChat, level: .warning)
                    return
                }
                let toolName = data["name"]?.stringValue ?? ""
                if phase == "start" {
                    let text = MessageFormatters.formatToolCallBubbleText(name: toolName, arguments: data["args"])
                    AppLogger.log("agent tool start - tool: \(toolName), callId: \(toolCallId)", category: .nativeChat)
                    let message = ChatMessage(
                        id: "\(runId):tool:\(toolCallId)",
                        text: text,
                        timestamp: timestamp,
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
                    viewModel?.receiveMessage(message)
                } else if phase == "update" {
                    // Intermediate state. Refresh the toolCall bubble with the
                    // latest args/progress so the user sees the tool is alive.
                    let text = MessageFormatters.formatToolCallBubbleText(name: toolName, arguments: data["args"])
                    AppLogger.log("agent tool update - tool: \(toolName), callId: \(toolCallId), text len: \(text.count)", category: .nativeChat)
                    let message = ChatMessage(
                        id: "\(runId):tool:\(toolCallId)",
                        text: text,
                        timestamp: timestamp,
                        role: "toolCall",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: nil,
                        endedAt: nil,
                        livenessState: nil,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        stopReason: nil,
                        isFresh: true
                    )
                    viewModel?.receiveMessage(message)
                } else if phase == "result" {
                    let resultValue = data["result"]?.value
                    let text = MessageFormatters.formatToolResultText(result: resultValue)
                    let isError = (data["isError"]?.value as? Bool) ?? false
                    AppLogger.log("agent tool result - tool: \(toolName), callId: \(toolCallId), isError: \(isError), text len: \(text.count)", category: .nativeChat)
                    let message = ChatMessage(
                        id: "\(runId):toolResult:\(toolCallId)",
                        text: text,
                        timestamp: timestamp,
                        role: "toolResult",
                        state: "final",
                        runId: runId,
                        seq: seq,
                        startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                        endedAt: timestamp,
                        livenessState: nil,
                        toolCallId: toolCallId,
                        toolName: toolName,
                        stopReason: isError ? "error" : nil,
                        isFresh: true
                    )
                    viewModel?.receiveMessage(message)
                }
            case "item":
                // Modern tool/command/patch lifecycle events. Each toolCallId
                // emits one `item` event per kind: tool, command (bash/exec),
                // patch, search, analysis. We map them all to a toolCall
                // bubble keyed by itemId so concurrent tools don't collide.
                // For non-command kinds, the actual result content is in the
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
                let toolCallId = data["toolCallId"]?.stringValue
                let meta = data["meta"]?.stringValue
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
                if itemPhase == "end" {
                    // End phase. If there's a summary (e.g., command output
                    // captured at end), fold it into a toolResult bubble so
                    // the user can read what the tool produced. Otherwise just
                    // mark the toolCall as ended.
                    let resultText = summary ?? errorText ?? ""
                    if !resultText.isEmpty {
                        let message = ChatMessage(
                            id: "\(runId):itemResult:\(itemId)",
                            text: resultText,
                            timestamp: timestamp,
                            role: "toolResult",
                            state: "final",
                            runId: runId,
                            seq: seq,
                            startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                            endedAt: timestamp,
                            livenessState: nil,
                            toolCallId: toolCallId,
                            toolName: name,
                            stopReason: (errorText != nil) ? "error" : nil,
                            isFresh: true
                        )
                        viewModel?.receiveMessage(message)
                    }
                }
                // Always update the toolCall bubble so start/update/end phases
                // surface a running indicator. In-place update by id matches
                // the same item across phases.
                let message = ChatMessage(
                    id: "\(runId):item:\(itemId)",
                    text: callText,
                    timestamp: timestamp,
                    role: "toolCall",
                    state: itemPhase == "end" ? "final" : "streaming",
                    runId: runId,
                    seq: seq,
                    startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                    endedAt: itemPhase == "end" ? timestamp : nil,
                    livenessState: nil,
                    toolCallId: toolCallId,
                    toolName: name,
                    stopReason: nil,
                    isFresh: true
                )
                viewModel?.receiveMessage(message)
            case "command_output":
                // Per-item command output stream. For exec/bash tools the
                // result body arrives here in `output` (incremental on
                // `phase: "delta"`, final on `phase: "end"`). Accumulate into
                // a toolResult bubble keyed by itemId.
                guard let itemId = data["itemId"]?.stringValue else {
                    AppLogger.log("agent command_output missing itemId, skipping. keys: \(data.keys.map { $0 })", category: .nativeChat, level: .warning)
                    return
                }
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
                let message = ChatMessage(
                    id: "\(runId):itemResult:\(itemId)",
                    text: resultText,
                    timestamp: timestamp,
                    role: "toolResult",
                    state: outputPhase == "end" ? "final" : "streaming",
                    runId: runId,
                    seq: seq,
                    startedAt: startedAtMs > 0 ? Date(timeIntervalSince1970: startedAtMs / 1000) : nil,
                    endedAt: outputPhase == "end" ? timestamp : nil,
                    livenessState: nil,
                    toolCallId: nil,
                    toolName: toolName,
                    stopReason: exitCode.map { $0 != 0 ? "error" : nil } ?? nil,
                    isFresh: true
                )
                viewModel?.receiveMessage(message)
            default:
                // plan, approval, patch, compaction, error — not yet surfaced.
                AppLogger.log("agent UNHANDLED stream=\(payload.stream) runId=\(payload.runId) seq=\(payload.seq ?? -1) data=\(EventInterpreter.summarizeData(data))", category: .nativeChat)
            }

        case .chat(let chat):
            // Log full structure so we can see if server delivers thinking as
            // content blocks here (the 2026.5.28 model) vs as separate agent events.
            // Mirrors the sessionMessage log below so we can spot {type:"thinking", thinking:"..."} blocks.
            var role = "?"
            var blockSummaries: [String] = []
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

        case .sessionMessage(let sm):
            // History/event-stream messages are typed OpenClawChatMessage.
            var blockSummaries: [String] = []
            if let blocks = sm.message?.content {
                for (i, block) in blocks.enumerated() {
                    var parts: [String] = ["#\(i)", "type=\(block.type ?? "?")"]
                    if let t = block.text, !t.isEmpty { parts.append("text=\"\(t.prefix(80))\(t.count > 80 ? "…" : "")\"") }
                    if let th = block.thinking, !th.isEmpty { parts.append("thinking=\"\(th.prefix(80))\(th.count > 80 ? "…" : "")\"") }
                    if let n = block.name { parts.append("name=\(n)") }
                    if let id = block.id { parts.append("id=\(id)") }
                    blockSummaries.append(parts.joined(separator: " "))
                }
            }
            AppLogger.log("sessionMessage messageId=\(sm.messageId ?? "nil") messageSeq=\(sm.messageSeq ?? -1) role=\(sm.message?.role ?? "nil") blocks=[\(blockSummaries.joined(separator: " | "))]", category: .nativeChat)

        case .tick:
            AppLogger.log("transport tick", category: .nativeChat)
        case .seqGap:
            AppLogger.log("transport seqGap (out-of-order event detected)", category: .nativeChat)
        case .health(let ok):
            AppLogger.log("transport health ok=\(ok)", category: .nativeChat)
        }
    }

    // MARK: - Static helpers (kept here because they're only used in `.log(...)` paths)

    private static func summarizeData(_ data: [String: AnyCodable]) -> String {
        let parts = data.keys.sorted().map { key -> String in
            guard let v = data[key]?.value else { return "\(key)=null" }
            return "\(key)=\(EventInterpreter.formatValue(v))"
        }
        return "{" + parts.joined(separator: ", ") + "}"
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
