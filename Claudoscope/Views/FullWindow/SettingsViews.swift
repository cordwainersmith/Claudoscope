import SwiftUI

// MARK: - Settings Sidebar Content

struct SettingsSidebarContent: View {
    let filterText: String
    @Binding var selectedSection: String?

    private static let sections: [(id: String, icon: String, label: String)] = [
        ("appearance", "paintbrush", "Appearance"),
        ("model", "cpu", "Model"),
        ("permissions", "shield", "Permissions"),
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
        "appearance", "model", "permissions", "general", "environment", "pricing"
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
        if model != nil || smallModel != nil {
            settingsSection(id: "model", icon: "cpu", title: "Model") {
                VStack(spacing: 0) {
                    if let model = model {
                        SettingsKeyValueRow(key: "model", value: model, mono: true)
                    }
                    if let smallModel = smallModel {
                        if model != nil { Divider().padding(.horizontal, 12) }
                        SettingsKeyValueRow(key: "smallFastModel", value: smallModel, mono: true)
                    }
                }
            }
        }
    }

    // MARK: - Permissions Section

    @ViewBuilder
    private func permissionsSection(_ dict: [String: Any]) -> some View {
        if let permissions = dict["permissions"] as? [String: Any] {
            let allowList = permissions["allow"] as? [String] ?? []
            let denyList = permissions["deny"] as? [String] ?? []

            settingsSection(id: "permissions", icon: "shield", title: "Permissions") {
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
            "env", "hooks"
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
        if let env = dict["env"] as? [String: Any], !env.isEmpty {
            settingsSection(id: "environment", icon: "terminal", title: "Environment") {
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
