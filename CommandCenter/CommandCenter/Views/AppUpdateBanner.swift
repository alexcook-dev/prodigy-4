import SwiftUI

/// Compact top-of-window banner when a production update is available.
struct AppUpdateBanner: View {
    @ObservedObject var updates: AppUpdateService
    @State private var showNotes = false

    var body: some View {
        if updates.shouldShowBanner, let update = updates.availableUpdate {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Theme.accent)
                    .imageScale(.large)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Update available — Prodigy \(update.version)")
                        .font(AppTypography.action)
                        .foregroundStyle(Theme.textPrimary)
                    Text("You’re on \(updates.currentVersion). Installs the DMG + app into Applications.")
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                if case .downloading(let fraction) = updates.phase {
                    if let fraction {
                        ProgressView(value: fraction)
                            .frame(width: 80)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Downloading…")
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else if case .installing = updates.phase {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing…")
                        .font(AppTypography.caption)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    if !update.notes.isEmpty {
                        Button("Notes") { showNotes = true }
                            .font(AppTypography.caption)
                    }
                    Button("Later") {
                        updates.dismissBanner()
                    }
                    .font(AppTypography.caption)

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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Theme.elevatedSurface)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.borderHairline)
                    .frame(height: 1)
            }
            .sheet(isPresented: $showNotes) {
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
    }
}
