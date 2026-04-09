import SwiftUI

// MARK: - Settings Sections

extension SettingsMainPanelView {

    // MARK: - Section Builder

    @ViewBuilder
    func settingsSection<Content: View>(
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
                    .font(Typography.body)
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
    func settingsEmptyHint(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "minus.circle")
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 12))
        }
        .foregroundStyle(.tertiary)
        .padding(12)
    }

    // MARK: - Appearance Section

    @ViewBuilder
    func appearanceSection() -> some View {
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
                                .font(.system(size: 12, weight: store.appearance == option ? .medium : .regular))
                                .foregroundStyle(store.appearance == option ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Model Section

    @ViewBuilder
    func modelSection(_ dict: [String: Any]) -> some View {
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
    func permissionsSection(_ dict: [String: Any]) -> some View {
        let permissions = dict["permissions"] as? [String: Any]
        let allowList = permissions?["allow"] as? [String] ?? []
        let denyList = permissions?["deny"] as? [String] ?? []

        settingsSection(id: "permissions", icon: "shield", title: "Permissions") {
            if !allowList.isEmpty || !denyList.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if !allowList.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Allow")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            FlowLayout(spacing: 6) {
                                ForEach(allowList, id: \.self) { item in
                                    Text(item)
                                        .font(Typography.code)
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
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            FlowLayout(spacing: 6) {
                                ForEach(denyList, id: \.self) { item in
                                    Text(item)
                                        .font(Typography.code)
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

    // MARK: - Security Section

    @ViewBuilder
    func securitySection() -> some View {
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
                            .font(.system(size: 12))
                        Text("Auto-approve mode active: permission prompts for destructive operations are skipped")
                            .font(.system(size: 12, weight: .medium))
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
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)

                        FlowLayout(spacing: 6) {
                            ForEach(sandbox!.unsandboxedCommands, id: \.self) { cmd in
                                Text(cmd)
                                    .font(Typography.code)
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
                            .font(.system(size: 11))
                        Text("Weaker nested sandbox enabled")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 12)
                }

                if isDefault {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                        Text("Default security posture")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                }

                Divider()
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Real-time secret scanning", isOn: Binding(
                        get: { store.realtimeSecretScanEnabled },
                        set: { store.realtimeSecretScanEnabled = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(Typography.body)

                    Text("Scan active sessions for leaked secrets and show alerts.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - General Section

    func generalEntries(from dict: [String: Any]) -> [(key: String, value: String)] {
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
    func generalSection(_ dict: [String: Any]) -> some View {
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
    func environmentSection(_ dict: [String: Any]) -> some View {
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
    func pricingSection() -> some View {
        settingsSection(id: "pricing", icon: "dollarsign.circle", title: "Pricing") {
            VStack(alignment: .leading, spacing: 12) {
                // Provider toggle
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)

                    HStack(spacing: 0) {
                        ForEach(PricingProvider.allCases, id: \.self) { provider in
                            Button {
                                store.pricingProvider = provider
                                store.rescanAllSessions()
                            } label: {
                                Text(provider == .anthropic ? "Anthropic" : "Vertex AI")
                                    .font(Typography.bodyMedium)
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
                    Text("Rates (per 1M tokens)")
                        .font(.system(size: 12, weight: .medium))
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
                        .font(.system(size: 12, weight: .medium))
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
                            .font(Typography.code)
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

    struct PricingRow {
        let model: String
        let input: String
        let output: String
    }

    func pricingRows() -> [PricingRow] {
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

    // MARK: - Attribution Section

    @ViewBuilder
    func attributionSection() -> some View {
        settingsSection(id: "attribution", icon: "signature", title: "Attribution") {
            if let attr = store.extendedConfig?.attribution {
                VStack(alignment: .leading, spacing: 8) {
                    if let commit = attr.commitTemplate {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Commit Template")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            Text(commit)
                                .font(Typography.code)
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
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            Text(pr)
                                .font(Typography.code)
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
                                .font(.system(size: 11))
                            Text("Deprecated: includeCoAuthoredBy is set. Use attribution.commitMessage instead.")
                                .font(.system(size: 12))
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
    func pluginsSection() -> some View {
        let ext = store.extendedConfig
        let plugins = ext?.plugins ?? []
        let marketplaces = ext?.marketplaces ?? []

        settingsSection(id: "plugins", icon: "puzzlepiece", title: "Plugins") {
            if !plugins.isEmpty || !marketplaces.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if !plugins.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Installed")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            FlowLayout(spacing: 6) {
                                ForEach(plugins) { plugin in
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(plugin.enabled ? Color.green : Color.gray)
                                            .frame(width: 6, height: 6)
                                        Text(plugin.name)
                                            .font(Typography.code)
                                        if let mp = plugin.marketplace {
                                            Text("@\(mp)")
                                                .font(.system(size: 11))
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
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)

                            VStack(spacing: 0) {
                                ForEach(Array(marketplaces.enumerated()), id: \.element.id) { index, mp in
                                    HStack {
                                        Image(systemName: marketplaceIcon(mp.sourceType))
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(mp.name)
                                            .font(Typography.bodyMedium)
                                        Spacer()
                                        Text(mp.detail)
                                            .font(Typography.code)
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

    func marketplaceIcon(_ sourceType: String) -> String {
        switch sourceType {
        case "github": return "chevron.left.forwardslash.chevron.right"
        case "npm": return "shippingbox"
        case "directory": return "folder"
        default: return "globe"
        }
    }

    // MARK: - Account Section

    @ViewBuilder
    func accountSection() -> some View {
        settingsSection(id: "account", icon: "person.crop.circle", title: "Account") {
            if let profile = store.extendedConfig?.profile {
                VStack(spacing: 0) {
                    let rows = accountRows(profile)
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        if row.isBadge {
                            HStack {
                                Text(row.key)
                                    .font(Typography.body)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Text(row.value)
                                    .font(.system(size: 12, weight: .medium))
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

    struct AccountRow {
        let key: String
        let value: String
        var mono: Bool = false
        var isBadge: Bool = false
    }

    func accountRows(_ profile: ClaudeProfile) -> [AccountRow] {
        var rows: [AccountRow] = []
        if let email = profile.maskedEmail {
            rows.append(AccountRow(key: "Account", value: email))
        }
        if let role = profile.orgRole {
            rows.append(AccountRow(key: "Org Role", value: role))
        }
        if let n = profile.numStartups {
            rows.append(AccountRow(key: "App Launches", value: "\(n)"))
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

    // MARK: - Updates Section

    @ViewBuilder
    func updatesSection() -> some View {
        settingsSection(id: "updates", icon: "arrow.triangle.2.circlepath", title: "Updates") {
            UpdatesSectionContent()
        }
    }
}

// MARK: - Cleanup Period Row

struct CleanupPeriodRow: View {
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
                        .font(Typography.bodyMedium)
                    Text(isDefault ? "Default: 30 days" : "\(displayDays) days")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 0) {
                    ForEach(presets, id: \.days) { preset in
                        Button {
                            updateCleanupPeriod(days: preset.days)
                        } label: {
                            Text(preset.label)
                                .font(.system(size: 12, weight: .medium))
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
                        .font(.system(size: 11))
                    Text("Set to 1 year to keep session history longer. Claude Code defaults to 30 days.")
                        .font(.system(size: 11))
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

// MARK: - Updates Section Content

struct UpdatesSectionContent: View {
    @Environment(UpdateService.self) private var updateService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Current version
            HStack(spacing: 8) {
                Text("Current version")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(updateService.currentVersion)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
            }
            .padding(.horizontal, 12)

            Divider()

            // Auto-check toggle
            HStack {
                @Bindable var service = updateService
                Toggle("Check for updates automatically", isOn: $service.autoCheckEnabled)
                    .font(Typography.body)
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 12)

            Divider()

            // Check now / update available
            VStack(alignment: .leading, spacing: 8) {
                if let update = updateService.updateAvailable {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 8, height: 8)
                        Text("Version \(update.version) available")
                            .font(Typography.bodyMedium)

                        Spacer()

                        if updateService.isDownloading {
                            ProgressView(value: updateService.downloadProgress)
                                .frame(width: 80)
                            Text("\(Int(updateService.downloadProgress * 100))%")
                                .font(Typography.codeSmall)
                                .foregroundStyle(.secondary)
                            Button("Cancel") {
                                updateService.cancelDownload()
                            }
                            .font(.system(size: 12))
                        } else {
                            Button("Download and Install") {
                                updateService.downloadAndInstall()
                            }
                            .font(Typography.body)
                        }
                    }

                    if let notes = update.releaseNotes, !notes.isEmpty {
                        ScrollView {
                            MarkdownNotesView(markdown: notes)
                                .padding(10)
                        }
                        .frame(maxHeight: 160)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(AnyShapeStyle(.quaternary))
                        )
                    }
                } else {
                    HStack {
                        Text(updateService.isChecking ? "" : "You're up to date")
                            .font(Typography.body)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("What's New") {
                            updateService.whatsNewInfo = .init(
                                version: updateService.currentVersion,
                                releaseNotes: nil
                            )
                            updateService.onOpenWhatsNew?()
                        }
                        .font(Typography.body)

                        Button {
                            Task {
                                updateService.clearSkippedVersion()
                                await updateService.checkForUpdates()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if updateService.isChecking {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text("Check Now")
                            }
                        }
                        .font(Typography.body)
                        .disabled(updateService.isChecking)
                    }
                }
            }
            .padding(.horizontal, 12)

            // Error display
            if let error = updateService.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                    Text(error)
                        .font(.system(size: 12))
                    Spacer()
                    Button("Retry") {
                        Task { await updateService.checkForUpdates() }
                    }
                    .font(.system(size: 12))
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
    }
}
