import SwiftUI

// MARK: - Selection

enum TasksJobsSelection: Hashable {
    case job(String)
    case taskList(String)
}

// MARK: - Sidebar

struct TasksJobsSidebarContent: View {
    let filterText: String
    let jobs: [JobSummary]
    let taskLists: [TaskListSummary]
    let daemonStatus: DaemonStatus?
    @Binding var selection: TasksJobsSelection?

    private var filteredJobs: [JobSummary] {
        if filterText.isEmpty { return jobs }
        return jobs.filter {
            ($0.name ?? "").localizedCaseInsensitiveContains(filterText) ||
            $0.dirName.localizedCaseInsensitiveContains(filterText) ||
            ($0.state ?? "").localizedCaseInsensitiveContains(filterText)
        }
    }

    private var filteredTaskLists: [TaskListSummary] {
        if filterText.isEmpty { return taskLists }
        return taskLists.filter { list in
            list.sessionId.localizedCaseInsensitiveContains(filterText) ||
            list.tasks.contains { ($0.subject ?? "").localizedCaseInsensitiveContains(filterText) }
        }
    }

    private var openLists: [TaskListSummary] { filteredTaskLists.filter { $0.openCount > 0 } }
    private var completedLists: [TaskListSummary] { filteredTaskLists.filter { $0.openCount == 0 } }

    var body: some View {
        if filteredJobs.isEmpty && filteredTaskLists.isEmpty {
            SidebarEmptyStateView(icon: "rectangle.stack.badge.play", text: "No background jobs or task lists")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !filteredJobs.isEmpty {
                    sectionHeader("BACKGROUND JOBS")
                    ForEach(filteredJobs) { job in
                        JobRow(job: job, isSelected: selection == .job(job.id)) {
                            selection = .job(job.id)
                        }
                    }
                }

                if !openLists.isEmpty {
                    sectionHeader("TASK LISTS (OPEN)")
                    ForEach(openLists) { list in
                        TaskListRow(list: list, isSelected: selection == .taskList(list.id)) {
                            selection = .taskList(list.id)
                        }
                    }
                }

                if !completedLists.isEmpty {
                    DisclosureGroup {
                        ForEach(completedLists) { list in
                            TaskListRow(list: list, isSelected: selection == .taskList(list.id)) {
                                selection = .taskList(list.id)
                            }
                        }
                    } label: {
                        Text("Completed lists (\(completedLists.count))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

                if let status = daemonStatus, let pid = status.supervisorPid {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.okabeBluishGreen)
                            .frame(width: 6, height: 6)
                        Text("Daemon supervisor pid \(pid)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

private struct JobRow: View {
    let job: JobSummary
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(JobStateStyle.color(for: job.state))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name ?? job.dirName)
                        .font(Typography.body)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)
                    Text(job.state ?? "unknown")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }

                Spacer()

                if let updated = job.updatedAt, let date = ISO8601.parse(updated) {
                    Text(date, format: .relative(presentation: .named))
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TaskListRow: View {
    let list: TaskListSummary
    let isSelected: Bool
    let onSelect: () -> Void

    private var title: String {
        list.tasks.first?.subject ?? String(list.sessionId.prefix(8))
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: list.openCount > 0 ? "circle.dotted" : "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typography.body)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white : .primary)
                    Text("\(list.completedCount)/\(list.tasks.count) done")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// State-to-color mapping shared by the sidebar dot and the detail badge.
/// Fixed semantic assignments from the Okabe-Ito palette, not positional.
private enum JobStateStyle {
    static func color(for state: String?) -> Color {
        switch state {
        case "done": return .okabeBluishGreen
        case "running", "working": return .okabeBlue
        case "failed", "error": return .okabeVermillion
        case "stopped", "idle": return .okabeOrange
        default: return .okabeGray
        }
    }
}

// MARK: - Main Panel

struct TasksJobsMainPanelView: View {
    @Environment(SessionStore.self) private var store
    let selection: TasksJobsSelection?
    var onNavigateToSession: ((String, String, String?) -> Void)?

    var body: some View {
        switch selection {
        case .job(let jobId):
            if let job = store.jobs.first(where: { $0.id == jobId }) {
                JobDetailView(job: job, onNavigateToSession: onNavigateToSession)
                    .id(jobId)
            } else {
                selectPrompt
            }
        case .taskList(let listId):
            if let list = store.taskLists.first(where: { $0.id == listId }) {
                TaskListDetailView(list: list, onNavigateToSession: onNavigateToSession)
            } else {
                selectPrompt
            }
        case nil:
            if store.jobs.isEmpty && store.taskLists.isEmpty {
                EmptyStateView(
                    icon: "rectangle.stack.badge.play",
                    title: "No background jobs or task lists",
                    message: "Background jobs live in ~/.claude/jobs and task lists in ~/.claude/tasks. They appear here as Claude Code creates them."
                )
            } else {
                selectPrompt
            }
        }
    }

    private var selectPrompt: some View {
        EmptyStateView(
            icon: "rectangle.stack.badge.play",
            title: "Select a job or task list",
            message: "Choose an item from the sidebar to view its detail."
        )
    }
}

private struct JobDetailView: View {
    @Environment(SessionStore.self) private var store
    let job: JobSummary
    var onNavigateToSession: ((String, String, String?) -> Void)?

    /// (projectId, sessionId) when the job's session exists in the store.
    private var linkedSession: (projectId: String, sessionId: String)? {
        for candidate in [job.sessionId, job.resumeSessionId] {
            guard let id = candidate else { continue }
            if let match = store.allSessionsWithProjects.first(where: { $0.session.id == id }) {
                return (match.project.id, match.session.id)
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(JobStateStyle.color(for: job.state))
                    .frame(width: 10, height: 10)
                Text(job.name ?? job.dirName)
                    .font(.system(size: 14, weight: .medium))
                Text(job.state ?? "unknown")
                    .font(Typography.micro)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(AnyShapeStyle(.quaternary))
                    .clipShape(Capsule())
                    .foregroundStyle(.secondary)
                Spacer()
                if let linked = linkedSession {
                    Button("Open session") {
                        onNavigateToSession?(linked.projectId, linked.sessionId, nil)
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CardView {
                        VStack(alignment: .leading, spacing: 8) {
                            ConfigSectionHeader(title: "JOB")
                            detailRow("Detail", job.detail)
                            detailRow("Working directory", job.cwd)
                            detailRow("Template", job.template)
                            detailRow("Backend", job.backend)
                            detailRow("Tokens", job.tokens.map { formatTokens($0) })
                            if let inFlight = job.inFlight {
                                detailRow("In flight", "\(inFlight.tasks ?? 0) tasks, \(inFlight.queued ?? 0) queued")
                            }
                            detailRow("Created", job.createdAt)
                            detailRow("Updated", job.updatedAt)
                            if linkedSession == nil, let sessionId = job.sessionId {
                                detailRow("Session", sessionId)
                            }
                        }
                    }

                    if let result = job.output?.result, !result.isEmpty {
                        CardView {
                            VStack(alignment: .leading, spacing: 8) {
                                ConfigSectionHeader(title: "RESULT")
                                Text(result)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    if !store.selectedJobTimeline.isEmpty {
                        CardView {
                            VStack(alignment: .leading, spacing: 8) {
                                ConfigSectionHeader(title: "TIMELINE")
                                ForEach(store.selectedJobTimeline) { entry in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(entry.at.flatMap { ISO8601.parse($0) }.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "")
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 130, alignment: .leading)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.state ?? "")
                                                .font(.system(size: 12, weight: .medium))
                                            if let text = entry.text, !text.isEmpty {
                                                Text(text)
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: job.id) {
            await store.loadJobTimeline(jobId: job.id)
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}

private struct TaskListDetailView: View {
    @Environment(SessionStore.self) private var store
    let list: TaskListSummary
    var onNavigateToSession: ((String, String, String?) -> Void)?

    private var linkedSession: (projectId: String, sessionId: String)? {
        guard let match = store.allSessionsWithProjects.first(where: { $0.session.id == list.sessionId }) else {
            return nil
        }
        return (match.project.id, match.session.id)
    }

    private func subject(forTaskId id: String) -> String {
        list.tasks.first { $0.id == id }?.subject ?? "#\(id)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Task list")
                    .font(.system(size: 14, weight: .medium))
                Text("\(list.completedCount)/\(list.tasks.count) done")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if let linked = linkedSession {
                    Button("Open session") {
                        onNavigateToSession?(linked.projectId, linked.sessionId, nil)
                    }
                    .font(.system(size: 11))
                } else {
                    Text(String(list.sessionId.prefix(8)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(list.tasks) { task in
                        CardView {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: iconForStatus(task.status))
                                    .font(.system(size: 13))
                                    .foregroundStyle(task.isCompleted ? Color.okabeBluishGreen : Color.secondary)
                                    .padding(.top, 1)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(task.subject ?? task.activeForm ?? "Task \(task.id)")
                                        .font(.system(size: 13, weight: .medium))
                                        .strikethrough(task.isCompleted)
                                    if let description = task.description, !description.isEmpty {
                                        Text(description)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(4)
                                    }
                                    if let blockedBy = task.blockedBy, !blockedBy.isEmpty {
                                        HStack(spacing: 4) {
                                            ForEach(blockedBy, id: \.self) { blockerId in
                                                Text("blocked by \(subject(forTaskId: blockerId))")
                                                    .font(Typography.micro)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.okabeOrange.opacity(0.15))
                                                    .clipShape(Capsule())
                                                    .foregroundStyle(Color.okabeOrange)
                                                    .lineLimit(1)
                                            }
                                        }
                                    }
                                }

                                Spacer()

                                if let status = task.status, !task.isCompleted {
                                    Text(status.replacingOccurrences(of: "_", with: " "))
                                        .font(Typography.micro)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconForStatus(_ status: String?) -> String {
        switch status {
        case "completed": return "checkmark.circle.fill"
        case "in_progress": return "circle.lefthalf.filled"
        default: return "circle"
        }
    }
}
