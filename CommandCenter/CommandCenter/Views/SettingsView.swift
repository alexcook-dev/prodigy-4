import SwiftUI

/// Settings surface — native Form layout (HIG).
/// Appearance toggle lives here; more sections can stack below later.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppStorageKey.appearance) private var appearanceRaw = AppAppearance.system.rawValue

    private var appearance: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(rawValue: appearanceRaw) ?? .system },
            set: { appearanceRaw = $0.rawValue }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Appearance", selection: appearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("System matches the appearance in System Settings. Light and Dark lock the app independently.")
                        .font(AppTypography.caption)
                }
            }
            .formStyle(.grouped)
            .font(AppTypography.body)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(AppTypography.action)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
    }
}

#Preview {
    SettingsView()
}
