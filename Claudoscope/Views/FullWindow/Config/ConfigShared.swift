import SwiftUI

// MARK: - Shared Helpers

/// Mask an environment variable value, showing only first 2 and last 2 characters.
func maskEnvValue(_ value: String) -> String {
    guard value.count > 6 else { return "***" }
    let prefix = value.prefix(2)
    let suffix = value.suffix(2)
    return "\(prefix)***\(suffix)"
}

/// Section header styled consistently.
struct ConfigSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)
    }
}
