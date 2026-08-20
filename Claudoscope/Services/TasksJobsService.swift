import Foundation

/// Reads Claude Code's local task lists (~/.claude/tasks/<uuid>/N.json) and
/// background jobs (~/.claude/jobs/<shortHash>/). Read-only; refresh happens
/// on rail visit, like Plans and Timeline.
actor TasksJobsService {
    private let tasksDir: URL
    private let jobsDir: URL
    private let daemonStatusURL: URL

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.tasksDir = claudeDir.appendingPathComponent("tasks")
        self.jobsDir = claudeDir.appendingPathComponent("jobs")
        self.daemonStatusURL = claudeDir.appendingPathComponent("daemon.status.json")
    }

    /// Load all non-empty task lists, sorted by directory mtime descending.
    func loadTaskLists() async -> [TaskListSummary] {
        let fm = FileManager.default
        guard let dirNames = try? fm.contentsOfDirectory(atPath: tasksDir.path) else {
            return []
        }

        let decoder = JSONDecoder()
        var lists: [TaskListSummary] = []

        for dirName in dirNames where !dirName.hasPrefix(".") {
            let dirURL = tasksDir.appendingPathComponent(dirName)
            guard let fileNames = try? fm.contentsOfDirectory(atPath: dirURL.path) else { continue }

            // Task files are numbered N.json; everything else (.lock,
            // .highwatermark, dotfiles) is bookkeeping.
            var tasks: [(number: Int, task: AgentTaskItem)] = []
            for fileName in fileNames where fileName.hasSuffix(".json") {
                guard let number = Int(fileName.dropLast(5)) else { continue }
                let fileURL = dirURL.appendingPathComponent(fileName)
                guard let data = try? Data(contentsOf: fileURL),
                      let task = try? decoder.decode(AgentTaskItem.self, from: data) else { continue }
                tasks.append((number, task))
            }
            guard !tasks.isEmpty else { continue }

            let attrs = try? fm.attributesOfItem(atPath: dirURL.path)
            lists.append(TaskListSummary(
                sessionId: dirName,
                tasks: tasks.sorted { $0.number < $1.number }.map(\.task),
                modifiedAt: attrs?[.modificationDate] as? Date
            ))
        }

        lists.sort { a, b in
            switch (a.modifiedAt, b.modifiedAt) {
            case let (dateA?, dateB?): return dateA > dateB
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.sessionId < b.sessionId
            }
        }
        return lists
    }

    /// Load all background jobs from their state.json files, newest first.
    func loadJobs() async -> [JobSummary] {
        let fm = FileManager.default
        guard let dirNames = try? fm.contentsOfDirectory(atPath: jobsDir.path) else {
            return []
        }

        let decoder = JSONDecoder()
        var jobs: [JobSummary] = []

        for dirName in dirNames where !dirName.hasPrefix(".") {
            let stateURL = jobsDir.appendingPathComponent(dirName).appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: stateURL),
                  var job = try? decoder.decode(JobSummary.self, from: data) else { continue }
            job.dirName = dirName
            jobs.append(job)
        }

        jobs.sort { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
        return jobs
    }

    /// Load one job's timeline.jsonl, in file order.
    func loadJobTimeline(jobId: String) async -> [JobTimelineEntry] {
        guard !jobId.contains("/"), !jobId.contains("..") else { return [] }
        let url = jobsDir.appendingPathComponent(jobId).appendingPathComponent("timeline.jsonl")
        guard let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .utf8) else { return [] }

        let decoder = JSONDecoder()
        return content.components(separatedBy: .newlines).compactMap { line in
            guard !line.isEmpty else { return nil }
            return try? decoder.decode(JobTimelineEntry.self, from: Data(line.utf8))
        }
    }

    func loadDaemonStatus() async -> DaemonStatus? {
        guard let data = try? Data(contentsOf: daemonStatusURL) else { return nil }
        return try? JSONDecoder().decode(DaemonStatus.self, from: data)
    }
}
