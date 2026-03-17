import SwiftUI

/// The popover content that can open the full window via NSWindow
struct MenuBarPopoverContent: View {
    @Environment(SessionStore.self) private var store
    @Environment(UpdateService.self) private var updateService
    @State private var showAbout = false
    @State private var showUpToDate = false
    @AppStorage("hasSeenRepositionTip") private var hasSeenTip = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("CLAUDOSCOPE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                Spacer()
                if let url = Bundle.main.url(forResource: "logo-c-t", withExtension: "png"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if store.isLoading {
                // Loading skeleton
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        ForEach(0..<4) { _ in
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.quaternary)
                                .frame(height: 40)
                        }
                    }
                    .padding(.horizontal, 16)

                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .frame(height: 50)
                        .padding(.horizontal, 16)

                    ForEach(0..<3) { _ in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(.quaternary)
                                .frame(width: 24, height: 24)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary)
                                .frame(height: 14)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 12)
                .redacted(reason: .placeholder)

                Divider()
            } else {
                // Today's stats
                StatsStrip(
                    sessionCount: store.todaySessions.count,
                    tokenCount: store.todayTokens,
                    cost: store.todayCost,
                    projectCount: Set(store.todaySessions.map(\.projectId)).count
                )

                // Sparkline
                SparklineChart(dailyUsage: store.analyticsData.dailyUsage)
                    .padding(.bottom, 12)

                Divider()

                // Active sessions (if any)
                if !activeSessions.isEmpty {
                    ActiveSessionsCard(sessions: activeSessions)
                        .padding(.vertical, 8)
                    Divider()
                }

                // Recent sessions
                if !store.recentSessions.isEmpty {
                    RecentSessionsList(sessions: store.recentSessions) { _ in
                        MainWindowController.shared.open(store: store, updateService: updateService)
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }

            // Reposition tip (shown once)
            if !hasSeenTip {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Hold **Cmd** and drag the menu bar icon to reposition it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        hasSeenTip = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(Typography.micro)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
            }

            // Actions
            VStack(spacing: 0) {
                PopoverMenuButton(label: "Dashboard", systemImage: "macwindow", shortcut: "\u{2318}O") {
                    MainWindowController.shared.open(store: store, updateService: updateService)
                }

                Divider()

                Button {
                    Task {
                        showUpToDate = false
                        // Clear any skipped version for manual checks so the popup always shows
                        updateService.clearSkippedVersion()
                        await updateService.checkForUpdates()
                        // onUpdateFound already shows the popup if an update is found,
                        // so only handle the "up to date" feedback path here
                        if updateService.updateAvailable == nil, updateService.error == nil {
                            showUpToDate = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                showUpToDate = false
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(Typography.body)
                            .frame(width: 16)
                        Text(showUpToDate ? "You're up to date!" : "Check for Updates...")
                            .font(Typography.body)
                            .foregroundStyle(showUpToDate ? .green : .primary)
                        Spacer()
                        if updateService.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        } else if showUpToDate {
                            Image(systemName: "checkmark.circle.fill")
                                .font(Typography.body)
                                .foregroundStyle(.green)
                        } else if updateService.updateAvailable != nil {
                            Text("New")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.orange))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider()

                PopoverMenuButton(label: "About Claudoscope", systemImage: "info.circle") {
                    showAbout = true
                }

                PopoverMenuButton(label: "Quit Claudoscope", systemImage: "power", shortcut: "\u{2318}Q") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .frame(width: 280)
        .overlay {
            if showAbout {
                AboutOverlay {
                    showAbout = false
                }
            }
        }
    }

    private var activeSessions: [SessionSummary] {
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return store.allSessionsWithProjects
            .map(\.session)
            .filter { session in
                guard let date = isoFormatter.date(from: session.lastTimestamp) else { return false }
                return now.timeIntervalSince(date) < 60
            }
    }
}

// MARK: - Popover Menu Button

struct PopoverMenuButton: View {
    let label: String
    var systemImage: String? = nil
    var shortcut: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(Typography.body)
                        .frame(width: 16)
                }
                Text(label)
                    .font(Typography.body)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
