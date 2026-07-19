import SwiftUI

/// Top-right file browser placeholder.
/// Real FileManager tree + lazy loading is T6; preview flip is later.
struct FileBrowserPaneView: View {
    /// Active Project's working folder (nil when nothing selected).
    var projectFolderPath: String? = nil
    var isFocused: Bool = false

    private var headerTitle: String {
        if let projectFolderPath {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let display = projectFolderPath.hasPrefix(home)
                ? "~" + projectFolderPath.dropFirst(home.count)
                : projectFolderPath
            return "Files — \(display)"
        }
        return "Files"
    }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            fileList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.appBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.deepest)
                .frame(height: 1)
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(Theme.focusRing, lineWidth: 2)
            }
        }
    }

    private var panelHeader: some View {
        HStack {
            Text(headerTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .textCase(.uppercase)
                .tracking(0.6)
                .lineLimit(1)

            Spacer()

            Image(systemName: "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderHairline)
                .frame(height: 1)
        }
    }

    private var fileList: some View {
        Group {
            if projectFolderPath == nil {
                VStack {
                    Spacer()
                    Text("No project selected.\nFiles follow the active project's folder.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(16)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("File tree is a placeholder — lazy FileManager browser is T6.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

#Preview {
    FileBrowserPaneView()
        .frame(width: 320, height: 280)
        .preferredColorScheme(.dark)
}
