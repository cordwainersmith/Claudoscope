import SwiftUI

// MARK: - Main Panel

struct ConfigHealthMainPanelView: View {
    let lintResults: [LintResult]
    let lintSummary: LintSummary
    let isLoading: Bool
    var isSecretScanLoading: Bool = false
    @Binding var selectedResultId: String?
    @Binding var hiddenSeverities: Set<LintSeverity>
    var selectedItem: String? = nil
    var onRescan: (() -> Void)?
    var onNavigateToSession: ((String, String, String?) -> Void)?

    private var selectedResult: LintResult? {
        guard let id = selectedResultId else { return nil }
        return lintResults.first(where: { $0.id == id })
    }

    var body: some View {
        if isLoading {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                Text("Running config health checks...")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = selectedResult {
            HealthResultDetailView(result: result, onNavigateToSession: onNavigateToSession) {
                selectedResultId = nil
            }
        } else if lintResults.isEmpty {
            EmptyStateView(
                icon: "checkmark.shield",
                title: "No issues found",
                message: "Your configuration looks healthy. All checks passed."
            )
        } else {
            HealthOverviewView(
                lintResults: lintResults,
                lintSummary: lintSummary,
                isSecretScanLoading: isSecretScanLoading,
                selectedResultId: $selectedResultId,
                hiddenSeverities: $hiddenSeverities,
                selectedItem: selectedItem,
                onRescan: onRescan
            )
        }
    }
}

// MARK: - View Mode

enum ViewMode: String, CaseIterable {
    case byCategory = "By Category"
    case byRule = "By Rule"
    case byFile = "By File"
}
