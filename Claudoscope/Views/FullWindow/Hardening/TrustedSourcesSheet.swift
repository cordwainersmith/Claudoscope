import SwiftUI

// MARK: - Trusted Sources Sheet

/// Editor for `autoMode.environment` (trusted environment entries) and
/// `sandbox.network.allowedHosts` (allowed network hosts). Save persists both
/// arrays into ~/.claude/settings.json via JSONSerialization, atomically.
struct TrustedSourcesSheet: View {
    let claudeDirURL: URL
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var environmentEntries: [String] = []
    @State private var allowedHosts: [String] = []
    @State private var newEnvironmentEntry: String = ""
    @State private var newHost: String = ""
    @State private var loaded: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 540)
        .frame(minHeight: 460)
        .task { loadFromSettings() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
            Text("Trusted Sources")
                .font(Typography.panelTitle)
            Spacer()
        }
        .padding(Spacing.lg)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Both lists are merged with the bundled hardening baseline. Reinstalling the baseline preserves every entry you add here.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)

                section(title: "Trusted environment (autoMode.environment)") {
                    listEditor(
                        entries: $environmentEntries,
                        newEntry: $newEnvironmentEntry,
                        placeholder: "e.g. github.com/myorg/* or $defaults"
                    )
                }

                section(title: "Allowed network hosts (sandbox.network.allowedHosts)") {
                    listEditor(
                        entries: $allowedHosts,
                        newEntry: $newHost,
                        placeholder: "e.g. registry.npmjs.org or *.example.com"
                    )
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(Typography.body)
                        .foregroundStyle(.red)
                }
            }
            .padding(Spacing.lg)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!loaded)
        }
        .padding(Spacing.lg)
    }

    // MARK: List editor

    @ViewBuilder
    private func listEditor(
        entries: Binding<[String]>,
        newEntry: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if entries.wrappedValue.isEmpty {
                Text("No entries.")
                    .font(Typography.body)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(entries.wrappedValue.enumerated()), id: \.offset) { idx, item in
                        HStack(spacing: 6) {
                            Text(item)
                                .font(Typography.code)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                var copy = entries.wrappedValue
                                guard idx < copy.count else { return }
                                copy.remove(at: idx)
                                entries.wrappedValue = copy
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                    }
                }
            }

            HStack(spacing: 6) {
                TextField(placeholder, text: newEntry)
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.body)
                    .onSubmit {
                        appendEntry(into: entries, from: newEntry)
                    }
                Button("Add") {
                    appendEntry(into: entries, from: newEntry)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(newEntry.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func appendEntry(into entries: Binding<[String]>, from input: Binding<String>) {
        let value = input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var copy = entries.wrappedValue
        if !copy.contains(value) { copy.append(value) }
        entries.wrappedValue = copy
        input.wrappedValue = ""
    }

    // MARK: Load + save

    private func loadFromSettings() {
        let url = claudeDirURL.appendingPathComponent("settings.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            loaded = true
            return
        }

        if let autoMode = json["autoMode"] as? [String: Any],
           let env = autoMode["environment"] as? [String] {
            environmentEntries = env
        }

        if let sandbox = json["sandbox"] as? [String: Any],
           let network = sandbox["network"] as? [String: Any],
           let hosts = network["allowedHosts"] as? [String] {
            allowedHosts = hosts
        }
        loaded = true
    }

    private func save() {
        let url = claudeDirURL.appendingPathComponent("settings.json")
        let fm = FileManager.default

        var json: [String: Any] = [:]
        if fm.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var autoMode = (json["autoMode"] as? [String: Any]) ?? [:]
        autoMode["environment"] = environmentEntries
        json["autoMode"] = autoMode

        var sandbox = (json["sandbox"] as? [String: Any]) ?? [:]
        var network = (sandbox["network"] as? [String: Any]) ?? [:]
        network["allowedHosts"] = allowedHosts
        sandbox["network"] = network
        json["sandbox"] = sandbox

        guard let outputData = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            errorMessage = "Failed to serialize settings.json"
            return
        }

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        do {
            try outputData.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            errorMessage = "Failed to write settings.json: \(error.localizedDescription)"
            try? fm.removeItem(at: tmp)
            return
        }

        onSaved()
        dismiss()
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }
}
