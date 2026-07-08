import SwiftUI

/// In-hierarchy confirmation dialog used by `SettingsView` to
/// confirm destructive Settings actions (issue #40).
///
/// **Why this exists instead of `.alert(item:)`.** SwiftUI's
/// system alert is presented in a separate UIWindow above the
/// app's view hierarchy. On iOS 17/18, when the user taps a
/// button, the hit-test handoff between the alert window and
/// the underlying view is not instantaneous — there is a
/// short window during which touches on the underlying view
/// (here, the Settings form) are dropped or ignored. The most
/// noticeable symptom is a scroll/pan lock right after
/// dismissal; after ~0.3–0.5 s (and a brief lift of the
/// finger) hit-testing returns to normal.
///
/// By living inside the same SwiftUI hierarchy as the form,
/// this dialog dismisses into the same hit-test tree: the
/// form is ready to receive gestures immediately on
/// Cancel/Clear. The visual layout — scrim + centered card
/// with title, message, Cancel button, destructive button —
/// mirrors the system alert so the destructive-action UX
/// feels familiar.
///
/// **Driving presentation.** The parent owns the `Bool`-ish
/// trigger (`pendingClear != nil`); the dialog itself takes
/// only its title/message strings and two callbacks. The
/// parent attaches `.animation(_:value:)` to the trigger so
/// the appear/disappear transitions fire — we do not own the
/// animation here, so the parent can tune timing/length
/// independently.
///
/// **Accessibility.** Default SwiftUI button labels ("Cancel",
/// the destructive title) are read by VoiceOver with the
/// `.cancel` and `.destructive` traits; default element
/// combining on the card surfaces title + message as a single
/// accessibility element, matching the system alert's
/// read-out order (title, message, Cancel, Clear).
struct ConfirmationDialog: View {
    let title: String
    let message: String
    let destructiveTitle: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            // Scrim — strictly modal: visual dim + tap absorber.
            //
            // **No `.transition` and no tap handler.** Two
            // reasons:
            //
            // 1. **No tap handler** (issue #40 follow-up). The
            //    dialog is strictly modal: the *only* clickable
            //    area while it is showing is the Cancel and
            //    Clear buttons on the card. Tapping the scrim
            //    is a no-op (the scrim absorbs the tap; it does
            //    not fall through to the form underneath, nor
            //    does it dismiss the dialog). The user must tap
            //    Cancel or Clear explicitly. This departs from
            //    the system alert's "tap outside to dismiss"
            //    convention — by design, per issue #40.
            //
            // 2. **No `.transition`.** The scrim is hit-testable
            //    (`.contentShape(Rectangle())` makes the whole
            //    rectangle absorb taps even though it has no
            //    `.onTapGesture`), and SwiftUI keeps transitioning
            //    views in the hierarchy for the duration of the
            //    transition. A `.transition(.opacity)` would leave
            //    the scrim absorbing touches for ~0.18 s after
            //    `pendingClear` flips to `nil` — long enough to
            //    swallow the first scroll/pan gesture the user
            //    fires after Cancel/Clear. Removing the
            //    transition makes the scrim disappear on the very
            //    next frame after state flip, so the form
            //    receives scrolls immediately. The card below
            //    retains its `.scale.combined(with: .opacity)`
            //    transition — it does not need to be hit-tested
            //    (the buttons cover it), so the 0.18 s animation
            //    window is harmless.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                // intentionally no `.onTapGesture` — scrim is a hit
                // absorber, not a tap-to-dismiss target.

            // Card.
            VStack(spacing: Theme.spacing) {
                Text(title)
                    .font(Typography.headline)
                    .foregroundColor(theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(Typography.body)
                    .foregroundColor(theme.textSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: Theme.spacing) {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    Button(destructiveTitle, role: .destructive, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(Theme.padding)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(theme.cardBackground)
            )
            .transition(.scale(scale: 0.92).combined(with: .opacity))
        }
        .zIndex(9_999)
    }
}
