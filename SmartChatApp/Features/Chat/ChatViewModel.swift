import Foundation
import OpenClawKit
import OpenClawChatUI

/// Custom ChatViewModel that extends OpenClawChatViewModel.
/// The base class handles tool events, this subclass adds delta-based incremental streaming for assistant text.
public class ChatViewModel: OpenClawChatViewModel {

    /// Override to handle delta-based incremental streaming for assistant output.
    open override func handleAgentEvent(_ evt: OpenClawAgentEventPayload) {
        if evt.stream == "assistant" {
            // Use delta for incremental streaming
            if let delta = evt.data["delta"]?.value as? String {
                self.streamingAssistantText = (self.streamingAssistantText ?? "") + delta
            } else if let text = evt.data["text"]?.value as? String {
                self.streamingAssistantText = text
            }
        } else {
            // Delegate all other events to base class for tool handling
            super.handleAgentEvent(evt)
        }
    }
}