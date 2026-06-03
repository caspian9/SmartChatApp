import SwiftUI
import OpenClawChatUI

public struct ChatCardOverlay<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
    }
}
