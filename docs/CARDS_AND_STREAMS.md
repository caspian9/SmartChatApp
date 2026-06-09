# Cards & Event Streams

## Card components

| Card | Location | Purpose |
|------|----------|---------|
| `MusicCardView` | `Cards/` | Music playback controls |
| `VideoCardView` | `Cards/` | Video playback controls |
| `ButtonCardView` | `Cards/` | Action buttons (open URL etc.) |
| `ImageCardView` | `Cards/` | Image display with fullscreen |
| `MarkdownCardView` | `Cards/` | Markdown rendering via MarkdownDisplayView (includes `StreamingMarkdownCardView` for incremental updates) |
| `ThinkingCardView` | `Cards/` | Thinking-block styling |

## Card dispatch

Cards are rendered based on tool call names:

- `music_search` → MusicCard (play/pause, progress, volume)
- `video_search` → VideoCard (play, fullscreen)
- `open_url` → ButtonCard (open links)
- `image` → ImageCard (view full size)
- `markdown` → MarkdownCardView (rendered via MarkdownDisplayView library)

## Message collapse behavior

- **Assistant + Markdown messages**: Display fully without collapse
  (`lineLimit` not supported for `UIViewRepresentable`)
- **Other message types** (toolResult, toolCall, thinking, plain
  text): Collapse with `Show more...` button
- Collapse state is cached in `CollapseStateCache` per message ID
- `lineLimit(8)` controls visible lines for collapsible messages
- `MessageBubbleView` shows a `TypingIndicatorView` (3 dots) for
  empty-text streaming bubbles, and trailing the streaming content
  of non-assistant roles (thinking, toolCall, etc.). Assistant
  markdown streaming skips the trailing dots because
  `StreamingMarkdownCardView` already signals activity via in-place
  updates.

## Theme configuration

App supports three appearance modes: `.system`, `.light`, `.dark`

- `Theme` struct provides colors via `@Environment(\.theme)`
- When set to `.system`, follows iOS device color scheme
- Theme colors: `background`, `cardBackground`, `primary`,
  `textPrimary`, `textSecondary`, `inputBackground`
