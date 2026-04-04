import SwiftUI

// MARK: - Settings Main Panel View

struct SettingsMainPanelView: View {
    @Environment(SessionStore.self) var store
    @Environment(ProfileManager.self) var profileManager
    @Binding var selectedSection: String?
    @State var settings: [String: Any]?
    @State var loadError: String?
    @State var expandedSections: Set<String> = [
        "appearance", "model", "permissions", "security", "attribution", "plugins", "account", "general", "profiles", "environment", "pricing", "updates"
    ]

    var settingsPath: String {
        store.claudeDir.appendingPathComponent("settings.json").path
    }

    func shouldShow(_ sectionId: String) -> Bool {
        guard let sel = selectedSection else { return true }
        return sel == sectionId
    }

    var body: some View {
        Group {
            if let error = loadError {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "Could not load settings",
                    message: error
                )
            } else if let settings = settings {
                settingsContent(settings)
            } else {
                // No settings file, but still show always-visible sections
                alwaysVisibleContent()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: store.claudeDir) {
            loadSettings()
        }
    }

    @ViewBuilder
    func alwaysVisibleContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("No settings.json found. Showing app preferences only.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if shouldShow("appearance") { appearanceSection() }
                    if shouldShow("security") { securitySection() }
                    if shouldShow("account") { accountSection() }
                    if shouldShow("general") { generalSection([:]) }
                    if shouldShow("profiles") { profilesSection() }
                    if shouldShow("pricing") { pricingSection() }
                    if shouldShow("updates") { updatesSection() }
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .padding(.horizontal, 24)
            }
        }
    }

    func loadSettings() {
        let url = URL(fileURLWithPath: settingsPath)
        guard FileManager.default.fileExists(atPath: settingsPath) else {
            settings = nil
            return
        }
        do {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                loadError = "Settings file is not a valid JSON object."
                return
            }
            settings = json
        } catch {
            loadError = error.localizedDescription
        }
    }

    @ViewBuilder
    func settingsContent(_ dict: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Banner
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Settings from \(store.claudeDir.appendingPathComponent("settings.json").path)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if shouldShow("appearance") { appearanceSection() }
                    if shouldShow("model") { modelSection(dict) }
                    if shouldShow("permissions") { permissionsSection(dict) }
                    if shouldShow("security") { securitySection() }
                    if shouldShow("attribution") { attributionSection() }
                    if shouldShow("plugins") { pluginsSection() }
                    if shouldShow("account") { accountSection() }
                    if shouldShow("general") { generalSection(dict) }
                    if shouldShow("profiles") { profilesSection() }
                    if shouldShow("environment") { environmentSection(dict) }
                    if shouldShow("pricing") { pricingSection() }
                    if shouldShow("updates") { updatesSection() }
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Helpers

    func stringValue(_ value: Any?) -> String {
        guard let value = value else { return "null" }
        if let str = value as? String { return str }
        if let num = value as? NSNumber {
            // Check if boolean
            if CFBooleanGetTypeID() == CFGetTypeID(num) {
                return num.boolValue ? "true" : "false"
            }
            return num.stringValue
        }
        return String(describing: value)
    }

    func previewFill(for appearance: AppAppearance) -> some ShapeStyle {
        switch appearance {
        case .light: return AnyShapeStyle(Color.white)
        case .dark: return AnyShapeStyle(Color(white: 0.15))
        case .system: return AnyShapeStyle(LinearGradient(
            colors: [Color.white, Color(white: 0.15)],
            startPoint: .leading,
            endPoint: .trailing
        ))
        }
    }
}
