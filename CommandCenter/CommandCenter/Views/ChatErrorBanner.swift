import SwiftUI

/// One banner shape, dynamic text/CTA per `api_retry` category (T13 / PLAN.md D5).
///
/// Categories + copy:
/// - authentication_failed → Max/Pro sign-in prompt / "Sign in with Claude"
/// - billing_error → "Billing issue with your Claude subscription." / "Details"
/// - rate_limit → "Claude hit its usage window (resets {time})." / "Retry"
/// - overloaded → "Claude is temporarily overloaded." / "Retry"
/// - process_died → "Lost connection to Claude." / "Restart"
///
/// Partial replies are preserved on the message list and tagged separately
/// ("[partial — kept]") — the banner only names the failure + CTA.
struct ChatErrorBanner: View {
    let error: ProviderError
    var detailsExpanded: Bool = false
    let onCTA: () -> Void
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text("⚠︎")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.errorText)
                    .accessibilityHidden(true)

                Text(error.displayMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.errorText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if let cta = error.category.bannerCTA {
                    Button(action: onCTA) {
                        Text(cta)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.errorText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Theme.errorBorder.opacity(0.45))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(Theme.errorBorder, lineWidth: 1)
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(cta)
                }

                if onDismiss != nil {
                    Button {
                        onDismiss?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.errorText.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }

            if detailsExpanded, error.category == .billingError {
                Text(error.message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.errorText.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.errorBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.errorBorder, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(error.displayMessage)")
    }
}

#Preview("Rate limit") {
    ChatErrorBanner(
        error: ProviderError(
            category: .rateLimit,
            resetsAt: Date().addingTimeInterval(3600)
        ),
        onCTA: {}
    )
    .padding()
    .background(Theme.centerBackground)
    .preferredColorScheme(.dark)
}

#Preview("Auth failed") {
    ChatErrorBanner(
        error: ProviderError(category: .authenticationFailed),
        onCTA: {}
    )
    .padding()
    .background(Theme.centerBackground)
    .preferredColorScheme(.dark)
}
