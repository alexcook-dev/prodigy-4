import SwiftUI

/// Floating bottom-left notification when a production update is available
/// (or when check failed due to private-repo auth).
struct AppUpdateToast: View {
    @ObservedObject var updates: AppUpdateService
    @State private var showNotes = false

    var body: some View {
        Group {
            if updates.shouldShowBanner, let update = updates.availableUpdate {
                toastCard(update: update)
                    .sheet(isPresented: $showNotes) {
                        notesSheet(update: update)
                    }
            } else if updates.shouldShowBanner, let message = updates.failureMessage {
                authFailureCard(message: message)
            }
        }
        .padding(.leading, 14)
        .padding(.bottom, 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: updates.shouldShowBanner)
    }

    private func authFailureCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Can’t check for updates")
                        .font(AppTypography.action)
                        .foregroundStyle(Theme.textPrimary)
                    Text(message)
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button {
                    updates.dismissFailureToast()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            HStack {
                Spacer(minLength: 0)
                Button {
                    Task { await updates.checkForUpdates(userInitiated: true) }
                } label: {
                    Text("Retry")
                        .font(AppTypography.action)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.elevatedSurface)
                .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.borderStructural.opacity(0.55), lineWidth: 1)
        }
    }

    private func toastCard(update: AppUpdateService.AvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .symbolRenderingMode(.hierarchical)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Update available")
                        .font(AppTypography.action)
                        .foregroundStyle(Theme.textPrimary)
                    Text("Prodigy \(update.version) is ready")
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textSecondary)
                    Text("You’re on \(updates.currentVersion)")
                        .font(AppTypography.caption2)
                        .foregroundStyle(Theme.textTertiary)
                }

                Spacer(minLength: 4)

                Button {
                    updates.dismissBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            statusOrActions(update: update)
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.elevatedSurface)
                .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.borderStructural.opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Update available, Prodigy \(update.version)")
    }

    @ViewBuilder
    private func statusOrActions(update: AppUpdateService.AvailableUpdate) -> some View {
        switch updates.phase {
        case .downloading(let fraction):
            HStack(spacing: 8) {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Downloading…")
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing…")
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        default:
            HStack(spacing: 8) {
                if !update.notes.isEmpty {
                    Button("Notes") { showNotes = true }
                        .font(AppTypography.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accentText)
                }

                Spacer(minLength: 0)

                Button("Later") {
                    updates.dismissBanner()
                }
                .font(AppTypography.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textSecondary)

                Button {
                    Task { await updates.installAvailableUpdate() }
                } label: {
                    Text("Update")
                        .font(AppTypography.action)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func notesSheet(update: AppUpdateService.AvailableUpdate) -> some View {
        NavigationStack {
            ScrollView {
                Text(update.notes)
                    .font(AppTypography.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("Prodigy \(update.version)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showNotes = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open on GitHub") {
                        updates.openReleasePage()
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}

/// Legacy name kept so existing call sites compile if any remain.
typealias AppUpdateBanner = AppUpdateToast
