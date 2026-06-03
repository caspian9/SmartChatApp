import SwiftUI
import WebKit

struct MessageBubbleView: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isOutgoing {
                Spacer()
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                // Show text or placeholder for streaming
                if message.text.isEmpty {
                    if message.state == "streaming" {
                        Text("...")
                            .font(.body)
                            .foregroundColor(.gray)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    } else {
                        Text("")
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                } else {
                    MarkdownWebView(text: message.text, isOutgoing: message.isOutgoing)
                }

                HStack(spacing: 8) {
                    if let startedAt = message.startedAt {
                        Text(formatTime(startedAt))
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    if let endedAt = message.endedAt {
                        Text("→ \(formatTime(endedAt))")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    if message.livenessState == "working" && message.state == "streaming" {
                        Text("●")
                            .font(.caption2)
                            .foregroundColor(.green)
                    } else if message.state == "streaming" && message.text.isEmpty {
                        Text("接收中...")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
            }

            if !message.isOutgoing {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func formatTime(_ timestamp: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

struct MarkdownWebView: View {
    let text: String
    let isOutgoing: Bool

    private var isLikelyMarkdown: Bool {
        let patterns = ["# ", "## ", "### ", "```", "**", "__", "* ", "- ", "| ", "```"]
        for pattern in patterns {
            if text.contains(pattern) {
                return true
            }
        }
        return false
    }

    var body: some View {
        if isLikelyMarkdown {
            MarkdownRendererView(text: text, backgroundColor: isOutgoing ? "#10A37F" : "#1E1E1E")
                .frame(maxWidth: 280)
        } else {
            Text(text)
                .font(.body)
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isOutgoing ? Color(hex: "10A37F") : Color(hex: "1E1E1E"))
                .cornerRadius(12)
        }
    }
}

struct MarkdownRendererView: UIViewRepresentable {
    let text: String
    let backgroundColor: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = markdownToHTML(text, backgroundColor: backgroundColor)
        webView.loadHTMLString(html, baseURL: nil)
    }

    private func markdownToHTML(_ md: String, backgroundColor: String) -> String {
        var html = md

        // Escape HTML first
        html = html.replacingOccurrences(of: "&", with: "&amp;")
        html = html.replacingOccurrences(of: "<", with: "&lt;")
        html = html.replacingOccurrences(of: ">", with: "&gt;")

        // Code blocks (must be before other processing)
        let codeBlockRegex = try? NSRegularExpression(pattern: "```([\\s\\S]*?)```", options: [])
        html = codeBlockRegex?.stringByReplacingMatches(
            in: html,
            options: [],
            range: NSRange(html.startIndex..., in: html),
            withTemplate: "<pre><code>$1</code></pre>"
        ) ?? html

        // Inline code
        html = html.replacingOccurrences(of: "`([^`]+)`", with: "<code>$1</code>", options: .regularExpression)

        // Headers
        html = html.replacingOccurrences(of: "^### (.+)$", with: "<h3>$1</h3>", options: .regularExpression)
        html = html.replacingOccurrences(of: "^## (.+)$", with: "<h2>$1</h2>", options: .regularExpression)
        html = html.replacingOccurrences(of: "^# (.+)$", with: "<h1>$1</h1>", options: .regularExpression)

        // Bold and italic
        html = html.replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>", options: .regularExpression)
        html = html.replacingOccurrences(of: "__(.+?)__", with: "<strong>$1</strong>", options: .regularExpression)
        html = html.replacingOccurrences(of: "\\*(.+?)\\*", with: "<em>$1</em>", options: .regularExpression)
        html = html.replacingOccurrences(of: "_(.+?)_", with: "<em>$1</em>", options: .regularExpression)

        // Strikethrough
        html = html.replacingOccurrences(of: "~~(.+?)~~", with: "<del>$1</del>", options: .regularExpression)

        // Horizontal rule
        html = html.replacingOccurrences(of: "^---$", with: "<hr>", options: .regularExpression)
        html = html.replacingOccurrences(of: "^\\*\\*\\*$", with: "<hr>", options: .regularExpression)

        // Blockquotes
        html = html.replacingOccurrences(of: "^> (.+)$", with: "<blockquote>$1</blockquote>", options: .regularExpression)

        // Unordered lists
        html = html.replacingOccurrences(of: "^[-*] (.+)$", with: "<li>$1</li>", options: .regularExpression)

        // Ordered lists
        html = html.replacingOccurrences(of: "^\\d+\\. (.+)$", with: "<li>$1</li>", options: .regularExpression)

        // Paragraphs - split by double newlines
        let paragraphs = html.components(separatedBy: "\n\n")
        html = paragraphs.map { "<p>\($0)</p>" }.joined(separator: "\n")

        // Single line breaks to <br>
        html = html.replacingOccurrences(of: "\n", with: "<br>")

        // Remove empty paragraphs
        html = html.replacingOccurrences(of: "<p></p>", with: "")
        html = html.replacingOccurrences(of: "<p><br></p>", with: "")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            background-color: \(backgroundColor);
            color: #FFFFFF;
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            font-size: 15px;
            line-height: 1.5;
            padding: 12px;
            border-radius: 12px;
            word-wrap: break-word;
        }
        h1, h2, h3 {
            font-weight: 600;
            margin: 8px 0;
        }
        h1 { font-size: 1.4em; }
        h2 { font-size: 1.2em; }
        h3 { font-size: 1.1em; }
        p {
            margin: 4px 0;
        }
        code {
            background-color: rgba(0,0,0,0.3);
            padding: 2px 6px;
            border-radius: 4px;
            font-family: 'SF Mono', Menlo, monospace;
            font-size: 0.9em;
        }
        pre {
            background-color: rgba(0,0,0,0.4);
            padding: 10px;
            border-radius: 8px;
            overflow-x: auto;
            margin: 8px 0;
        }
        pre code {
            background: none;
            padding: 0;
        }
        blockquote {
            border-left: 3px solid #10A37F;
            padding-left: 12px;
            margin: 8px 0;
            color: #A0A0A0;
        }
        ul, ol {
            margin: 8px 0;
            padding-left: 24px;
        }
        li {
            margin: 4px 0;
        }
        hr {
            border: none;
            border-top: 1px solid rgba(255,255,255,0.2);
            margin: 12px 0;
        }
        strong {
            font-weight: 600;
        }
        em {
            font-style: italic;
        }
        del {
            text-decoration: line-through;
            opacity: 0.7;
        }
        a {
            color: #10A37F;
            text-decoration: none;
        }
        </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id: String
    var text: String
    let timestamp: Date
    let role: String
    var state: String  // "streaming", "final"
    let runId: String?
    var seq: Int?
    var startedAt: Date?
    var endedAt: Date?
    var livenessState: String?
    let toolCallId: String?
    let toolName: String?
    let stopReason: String?

    var isOutgoing: Bool {
        role.lowercased() == "user"
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id &&
        lhs.text == rhs.text &&
        lhs.state == rhs.state &&
        lhs.startedAt == rhs.startedAt &&
        lhs.endedAt == rhs.endedAt &&
        lhs.livenessState == rhs.livenessState
    }
}