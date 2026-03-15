import SwiftUI

// MARK: - Settings Sidebar Content

struct SettingsSidebarContent: View {
    let filterText: String
    @Binding var selectedSection: String?

    private static let sections: [(id: String, icon: String, label: String)] = [
        ("appearance", "paintbrush", "Appearance"),
        ("model", "cpu", "Model"),
        ("permissions", "shield", "Permissions"),
        ("security", "lock.shield", "Security"),
        ("attribution", "signature", "Attribution"),
        ("plugins", "puzzlepiece", "Plugins"),
        ("account", "person.crop.circle", "Account"),
        ("general", "gear", "General"),
        ("environment", "terminal", "Environment"),
        ("pricing", "dollarsign.circle", "Pricing"),
    ]

    private var filteredSections: [(id: String, icon: String, label: String)] {
        if filterText.isEmpty { return Self.sections }
        return Self.sections.filter { $0.label.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(filteredSections, id: \.id) { section in
                Button {
                    selectedSection = section.id
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: section.icon)
                            .font(.system(size: 12))
                            .frame(width: 16)
                            .foregroundStyle(selectedSection == section.id ? .white : .secondary)

                        Text(section.label)
                            .font(.system(size: 12))
                            .foregroundStyle(selectedSection == section.id ? .white : .primary)

                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selectedSection == section.id ? Color.accentColor : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings Main Panel View

struct SettingsMainPanelView: View {
    @Environment(SessionStore.self) private var store
    @Binding var selectedSection: String?
    @State private var settings: [String: Any]?
    @State private var loadError: String?
    @State private var expandedSections: Set<String> = [
        "appearance", "model", "permissions", "security", "attribution", "plugins", "account", "general", "environment", "pricing"
    ]

    private var settingsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/settings.json"
    }

    private func shouldShow(_ sectionId: String) -> Bool {
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
        .task {
            loadSettings()
        }
    }

    @ViewBuilder
    private func alwaysVisibleContent() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("No settings.json found. Showing app preferences only.")
                    .font(.system(size: 11))
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
                    if shouldShow("pricing") { pricingSection() }
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .padding(.horizontal, 24)
            }
        }
    }

    private func loadSettings() {
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
    private func settingsContent(_ dict: [String: Any]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Banner
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Settings from ~/.claude/settings.json")
                    .font(.system(size: 11))
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
                    if shouldShow("environment") { environmentSection(dict) }
                    if shouldShow("pricing") { pricingSection() }
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Appearance Section

    @ViewBuilder
    private func appearanceSection() -> some View {
        settingsSection(id: "appearance", icon: "paintbrush", title: "Appearance") {
            HStack(spacing: 8) {
                ForEach(AppAppearance.allCases, id: \.rawValue) { option in
                    Button {
                        store.appearance = option
                        MainWindowController.shared.applyAppearance(option)
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(previewFill(for: option))
                                .frame(width: 64, height: 40)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(
                                            store.appearance == option ? Color.accentColor : Color.secondary.opacity(0.3),
                                            lineWidth: store.appearance == option ? 2 : 1
                                        )
                                )

                            Text(option.label)
                                .font(.system(size: 11, weight: store.appearance == option ? .medium : .regular))
                                .foregroundStyle(store.appearance == option ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }

    private func previewFill(for appearance: AppAppearance) -> some ShapeStyle {
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

    // MARK: - Model Section

    @ViewBuilder
    private func modelSection(_ dict: [String: Any]) -> some View {
        let model = dict["model"] as? String
        let smallModel = dict["smallFastModel"] as? String
        settingsSection(id: "model", icon: "cpu", title: "Model") {
            if model != nil || smallModel != nil {
                VStack(spacing: 0) {
                    if let model = model {
                        SettingsKeyValueRow(key: "model", value: model, mono: true)
                    }
                    if let smallModel = smallModel {
                        if model != nil { Divider().padding(.horizontal, 12) }
                        SettingsKeyValueRow(key: "smallFastModel", value: smallModel, mono: true)
                    }
                }
            } else {
                settingsEmptyHint("Using default model. Set \"model\" in settings.json to override.")
            }
        }
    }

    // MARK: - Permissions Section

    @ViewBuilder
    private func permissionsSection(_ dict: [String: Any]) -> some View {
        let permissions = dict["permissions"] as? [String: Any]
        let allowList = permissions?["allow"] as? [String] ?? []
        let denyList = permissions?["deny"] as? [String] ?? []

        settingsSection(id: "permissions", icon: "shield", title: "Permissions") {
            if !allowList.isEmpty || !denyList.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if !allowList.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Allow")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            FlowLayout(spacing: 6) {
                                ForEach(allowList, id: \.self) { item in
                                    Text(item)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.green)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.green.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                    }

                    if !denyList.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Deny")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            FlowLayout(spacing: 6) {
                                ForEach(denyList, id: \.self) { item in
                                    Text(item)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.red)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.red.opacity(0.1))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.vertical, 8)
            } else {
                settingsEmptyHint("No permission overrides configured. Claude Code will prompt for each tool.")
            }
        }
    }

    // MARK: - General Section

    private func generalEntries(from dict: [String: Any]) -> [(key: String, value: String)] {
        let generalKeys: Set<String> = [
            "cleanupPeriodDays", "autoMemoryEnabled"
        ]
        let knownTopLevel: Set<String> = [
            "model", "smallFastModel", "permissions",
            "env", "hooks",
            "sandbox", "skipDangerousModePermissionPrompt",
            "attribution", "includeCoAuthoredBy",
            "autoUpdatesChannel",
            "enabledPlugins", "extraKnownMarketplaces",
            "skippedPlugins", "skippedMarketplaces", "strictKnownMarketplaces"
        ]
        var entries: [(key: String, value: String)] = []
        for key in dict.keys.sorted() {
            if generalKeys.contains(key) || !knownTopLevel.contains(key) {
                let val = dict[key]
                if val is [String: Any] || val is [Any] { continue }
                entries.append((key: key, value: stringValue(val)))
            }
        }
        return entries
    }

    @ViewBuilder
    private func generalSection(_ dict: [String: Any]) -> some View {
        let entries = generalEntries(from: dict)
        let currentCleanup = dict["cleanupPeriodDays"] as? Int

        settingsSection(id: "general", icon: "gear", title: "General") {
            VStack(alignment: .leading, spacing: 0) {
                // Cleanup period highlight
                CleanupPeriodRow(
                    currentDays: currentCleanup,
                    settingsPath: settingsPath,
                    onUpdated: { loadSettings() }
                )

                if !entries.isEmpty {
                    // Filter out cleanupPeriodDays since we show it above
                    let otherEntries = entries.filter { $0.key != "cleanupPeriodDays" }
                    if !otherEntries.isEmpty {
                        Divider().padding(.horizontal, 12)
                        ForEach(Array(otherEntries.enumerated()), id: \.offset) { index, entry in
                            SettingsKeyValueRow(key: entry.key, value: entry.value)
                            if index < otherEntries.count - 1 {
                                Divider().padding(.horizontal, 12)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Environment Section

    @ViewBuilder
    private func environmentSection(_ dict: [String: Any]) -> some View {
        let env = dict["env"] as? [String: Any] ?? [:]
        settingsSection(id: "environment", icon: "terminal", title: "Environment") {
            if !env.isEmpty {
                VStack(spacing: 0) {
                    let sortedKeys = env.keys.sorted()
                    ForEach(Array(sortedKeys.enumerated()), id: \.offset) { index, key in
                        SettingsKeyValueRow(
                            key: key,
                            value: stringValue(env[key]),
                            mono: true
                        )
                        if index < sortedKeys.count - 1 {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            } else {
                settingsEmptyHint("No environment variables configured. Add an \"env\" key to settings.json to inject variables into Claude Code's shell.")
            }
        }
    }

    // MARK: - Pricing Section

    @ViewBuilder
    private func pricingSection() -> some View {
        settingsSection(id: "pricing", icon: "dollarsign.circle", title: "Pricing") {
            VStack(alignment: .leading, spacing: 12) {
                // Provider toggle
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)

                    HStack(spacing: 0) {
                        ForEach(PricingProvider.allCases, id: \.self) { provider in
                            Button {
                                store.pricingProvider = provider
                            } label: {
                                Text(provider == .anthropic ? "Anthropic" : "Vertex AI")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(store.pricingProvider == provider ? Color.accentColor : Color.clear)
                                    .foregroundStyle(store.pricingProvider == provider ? .white : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
                    .frame(width: 200)
                    .padding(.horizontal, 12)
                }

                // Rates table
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rates (per MTok)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)

                    VStack(spacing: 0) {
                        // Header
                        HStack {
                            Text("Model")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Input")
                                .frame(width: 70, alignment: .trailing)
                            Text("Output")
                                .frame(width: 70, alignment: .trailing)
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(AnyShapeStyle(.quaternary))

                        ForEach(pricingRows(), id: \.model) { row in
                            Divider().padding(.horizontal, 12)
                            HStack {
                                Text(row.model)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(row.input)
                                    .frame(width: 70, alignment: .trailing)
                                Text(row.output)
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                        }
                    }
                    .background(.bar)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private struct PricingRow {
        let model: String
        let input: String
        let output: String
    }

    private func pricingRows() -> [PricingRow] {
        let table = store.pricingTable
        let models = ["opus4", "opus", "sonnet", "haiku", "haiku3"]
        let labels = ["Opus 4", "Opus", "Sonnet", "Haiku", "Haiku 3"]
        var rows: [PricingRow] = []
        for (model, label) in zip(models, labels) {
            if let p = table[model] {
                rows.append(PricingRow(
                    model: label,
                    input: String(format: "$%.2f", p.input),
                    output: String(format: "$%.2f", p.output)
                ))
            }
        }
        return rows
    }

    // MARK: - Security Section

    @ViewBuilder
    private func securitySection() -> some View {
        let ext = store.extendedConfig
        let yolo = ext?.skipDangerousModePermissionPrompt ?? false
        let sandbox = ext?.sandbox
        let hasUnsandboxed = !(sandbox?.unsandboxedCommands ?? []).isEmpty
        let weakerSandbox = sandbox?.enableWeakerNestedSandbox ?? false
        let isDefault = !yolo && !hasUnsandboxed && !weakerSandbox

        settingsSection(id: "security", icon: "lock.shield", title: "Security") {
            VStack(alignment: .leading, spacing: 8) {
                if yolo {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text("YOLO mode enabled: dangerous permission prompts are skipped")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.horizontal, 12)
                }

                if hasUnsandboxed {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unsandboxed Commands")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)

                        FlowLayout(spacing: 6) {
                            ForEach(sandbox!.unsandboxedCommands, id: \.self) { cmd in
                                Text(cmd)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.orange.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }

                if weakerSandbox {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 10))
                        Text("Weaker nested sandbox enabled")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 12)
                }

                if isDefault {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                        Text("Default security posture")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - Attribution Section

    @ViewBuilder
    private func attributionSection() -> some View {
        settingsSection(id: "attribution", icon: "signature", title: "Attribution") {
            if let attr = store.extendedConfig?.attribution {
                VStack(alignment: .leading, spacing: 8) {
                    if let commit = attr.commitTemplate {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Commit Template")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            Text(commit)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AnyShapeStyle(.quaternary))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(.horizontal, 12)
                                .textSelection(.enabled)
                        }
                    }

                    if let pr = attr.prTemplate {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PR Template")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            Text(pr)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(AnyShapeStyle(.quaternary))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(.horizontal, 12)
                                .textSelection(.enabled)
                        }
                    }

                    if attr.hasDeprecatedCoAuthoredBy {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10))
                            Text("Deprecated: includeCoAuthoredBy is set. Use attribution.commitMessage instead.")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 8)
            } else {
                settingsEmptyHint("No attribution templates configured.")
            }
        }
    }

    // MARK: - Plugins Section

    @ViewBuilder
    private func pluginsSection() -> some View {
        let ext = store.extendedConfig
        let plugins = ext?.plugins ?? []
        let marketplaces = ext?.marketplaces ?? []

        settingsSection(id: "plugins", icon: "puzzlepiece", title: "Plugins") {
            if !plugins.isEmpty || !marketplaces.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if !plugins.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Installed")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            FlowLayout(spacing: 6) {
                                ForEach(plugins) { plugin in
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(plugin.enabled ? Color.green : Color.gray)
                                            .frame(width: 6, height: 6)
                                        Text(plugin.name)
                                            .font(.system(size: 11, design: .monospaced))
                                        if let mp = plugin.marketplace {
                                            Text("@\(mp)")
                                                .font(.system(size: 10))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .foregroundStyle(plugin.enabled ? .primary : .secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(plugin.enabled ? Color.green.opacity(0.08) : Color.gray.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                    }

                    if !marketplaces.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Extra Marketplaces")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            VStack(spacing: 0) {
                                ForEach(Array(marketplaces.enumerated()), id: \.element.id) { index, mp in
                                    HStack {
                                        Image(systemName: marketplaceIcon(mp.sourceType))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(mp.name)
                                            .font(.system(size: 12, weight: .medium))
                                        Spacer()
                                        Text(mp.detail)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)

                                    if index < marketplaces.count - 1 {
                                        Divider().padding(.horizontal, 12)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.vertical, 8)
            } else {
                settingsEmptyHint("No plugins installed.")
            }
        }
    }

    private func marketplaceIcon(_ sourceType: String) -> String {
        switch sourceType {
        case "github": return "chevron.left.forwardslash.chevron.right"
        case "npm": return "shippingbox"
        case "directory": return "folder"
        default: return "globe"
        }
    }

    // MARK: - Account Section

    @ViewBuilder
    private func accountSection() -> some View {
        settingsSection(id: "account", icon: "person.crop.circle", title: "Account") {
            if let profile = store.extendedConfig?.profile {
                VStack(spacing: 0) {
                    let rows = accountRows(profile)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if row.isBadge {
                            HStack {
                                Text(row.key)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text(row.value)
                                    .font(.system(size: 11, weight: .medium))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundStyle(Color.accentColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        } else {
                            SettingsKeyValueRow(key: row.key, value: row.value, mono: row.mono)
                        }
                        if index < rows.count - 1 {
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            } else {
                settingsEmptyHint("No account data found. ~/.claude.json may not exist yet.")
            }
        }
    }

    private struct AccountRow {
        let key: String
        let value: String
        var mono: Bool = false
        var isBadge: Bool = false
    }

    private func accountRows(_ profile: ClaudeProfile) -> [AccountRow] {
        var rows: [AccountRow] = []
        if let email = profile.maskedEmail {
            rows.append(AccountRow(key: "Account", value: email))
        }
        if let role = profile.orgRole {
            rows.append(AccountRow(key: "Org Role", value: role))
        }
        if let n = profile.numStartups {
            rows.append(AccountRow(key: "Startups", value: "\(n)"))
        }
        if let theme = profile.theme {
            rows.append(AccountRow(key: "Theme", value: theme))
        }
        if let channel = profile.autoUpdatesChannel {
            rows.append(AccountRow(key: "Updates Channel", value: channel, isBadge: true))
        }
        if let v = profile.lastReleaseNotesSeen {
            rows.append(AccountRow(key: "Last Release Notes", value: v, mono: true))
        }
        if let onboarded = profile.hasCompletedOnboarding {
            rows.append(AccountRow(key: "Onboarding Complete", value: onboarded ? "Yes" : "No"))
        }
        if let shift = profile.shiftEnterKeyBindingInstalled {
            rows.append(AccountRow(key: "Shift+Enter Binding", value: shift ? "Installed" : "Not installed"))
        }
        return rows
    }

    // MARK: - Section Builder

    @ViewBuilder
    private func settingsSection<Content: View>(
        id: String,
        icon: String,
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isExpanded = Binding<Bool>(
            get: { expandedSections.contains(id) },
            set: { newValue in
                if newValue {
                    expandedSections.insert(id)
                } else {
                    expandedSections.remove(id)
                }
            }
        )

        DisclosureGroup(isExpanded: isExpanded) {
            content()
                .padding(.top, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .padding(12)
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Empty Hint

    @ViewBuilder
    private func settingsEmptyHint(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.circle")
                .font(.system(size: 11))
            Text(message)
                .font(.system(size: 11))
        }
        .foregroundStyle(.tertiary)
        .padding(12)
    }

    // MARK: - Helpers

    private func stringValue(_ value: Any?) -> String {
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
}

// MARK: - Cleanup Period Row

private struct CleanupPeriodRow: View {
    let currentDays: Int?
    let settingsPath: String
    let onUpdated: () -> Void

    private var displayDays: Int { currentDays ?? 30 }
    private var isDefault: Bool { currentDays == nil }

    private let presets: [(label: String, days: Int)] = [
        ("30 days", 30),
        ("90 days", 90),
        ("1 year", 365),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcript Retention")
                        .font(.system(size: 12, weight: .medium))
                    Text(isDefault ? "Default: 30 days" : "\(displayDays) days")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 0) {
                    ForEach(presets, id: \.days) { preset in
                        Button {
                            updateCleanupPeriod(days: preset.days)
                        } label: {
                            Text(preset.label)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(displayDays == preset.days ? Color.accentColor.opacity(0.15) : .clear)
                                .foregroundStyle(displayDays == preset.days ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)

                        if preset.days != presets.last?.days {
                            Divider().frame(height: 16)
                        }
                    }
                }
                .background(.bar)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
            }

            if isDefault {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                    Text("Set to 1 year to keep session history longer. Claude Code defaults to 30 days.")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.orange)
            }
        }
        .padding(12)
    }

    private func updateCleanupPeriod(days: Int) {
        let url = URL(fileURLWithPath: settingsPath)
        var json: [String: Any] = [:]

        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        json["cleanupPeriodDays"] = days

        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
            onUpdated()
        }
    }
}

// MARK: - Key-Value Row

private struct SettingsKeyValueRow: View {
    let key: String
    let value: String
    var mono: Bool = false

    var body: some View {
        HStack {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            Spacer()

            if mono {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private struct LayoutResult {
        var positions: [CGPoint]
        var size: CGSize
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }

        return LayoutResult(
            positions: positions,
            size: CGSize(width: totalWidth, height: currentY + lineHeight)
        )
    }
}
