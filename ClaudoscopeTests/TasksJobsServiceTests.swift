import XCTest
@testable import Claudoscope

/// TasksJobsService reads ~/.claude/tasks/<uuid>/N.json and
/// ~/.claude/jobs/<shortHash>/. Fixtures are built as temp directory trees.
final class TasksJobsServiceTests: XCTestCase {

    private var claudeDir: URL!

    override func setUpWithError() throws {
        claudeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudoscope-tasksjobs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: claudeDir)
    }

    private func write(_ content: String, to relativePath: String) throws {
        let url = claudeDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Task lists

    func testMissingTasksDirReturnsEmpty() async {
        let service = TasksJobsService(claudeDir: claudeDir)
        let lists = await service.loadTaskLists()
        XCTAssertTrue(lists.isEmpty)
    }

    func testEmptyTaskDirIsSkipped() async throws {
        try write("", to: "tasks/aaaa-1111/.lock")
        try write("3", to: "tasks/aaaa-1111/.highwatermark")
        let service = TasksJobsService(claudeDir: claudeDir)
        let lists = await service.loadTaskLists()
        XCTAssertTrue(lists.isEmpty, "dirs with only bookkeeping files must not appear")
    }

    func testTaskListLoadsInNumberOrder() async throws {
        try write("{\"id\":\"2\",\"subject\":\"second\",\"status\":\"pending\",\"blocks\":[],\"blockedBy\":[\"1\"]}", to: "tasks/bbbb-2222/2.json")
        try write("{\"id\":\"1\",\"subject\":\"first\",\"status\":\"completed\",\"blocks\":[\"2\"],\"blockedBy\":[]}", to: "tasks/bbbb-2222/1.json")
        try write("{\"id\":\"10\",\"subject\":\"tenth\",\"status\":\"pending\"}", to: "tasks/bbbb-2222/10.json")
        try write("", to: "tasks/bbbb-2222/.lock")

        let service = TasksJobsService(claudeDir: claudeDir)
        let lists = await service.loadTaskLists()
        XCTAssertEqual(lists.count, 1)
        let list = try XCTUnwrap(lists.first)
        XCTAssertEqual(list.sessionId, "bbbb-2222")
        XCTAssertEqual(list.tasks.map(\.subject), ["first", "second", "tenth"])
        XCTAssertEqual(list.openCount, 2)
        XCTAssertEqual(list.completedCount, 1)
        XCTAssertEqual(list.tasks[1].blockedBy, ["1"])
    }

    func testMalformedTaskFileIsSkipped() async throws {
        try write("{\"id\":\"1\",\"subject\":\"good\",\"status\":\"pending\"}", to: "tasks/cccc-3333/1.json")
        try write("not json at all", to: "tasks/cccc-3333/2.json")
        try write("{\"id\":\"x\"}", to: "tasks/cccc-3333/notanumber.json")

        let service = TasksJobsService(claudeDir: claudeDir)
        let lists = await service.loadTaskLists()
        XCTAssertEqual(lists.first?.tasks.count, 1)
    }

    // MARK: - Jobs

    func testJobStateDecodesAndProviderEnvIsInvisible() async throws {
        let state = """
        {"state":"done","detail":"finished","tempo":"idle","inFlight":{"tasks":0,"queued":0,"kinds":[]},
         "tokens":52341,"output":{"result":"All tests passed"},"name":"nightly-check","nameSource":"auto",
         "sessionId":"sess-abc","resumeSessionId":"sess-def","cliVersion":"2.1.237","cwd":"/Users/x/proj",
         "template":"bg","backend":"daemon","providerEnv":{"ANTHROPIC_API_KEY":"sk-SECRET-VALUE"},
         "createdAt":"2026-08-19T10:00:00.000Z","updatedAt":"2026-08-19T11:00:00.000Z"}
        """
        try write(state, to: "jobs/abc123/state.json")
        try write("[]", to: "jobs/pins.json")

        let service = TasksJobsService(claudeDir: claudeDir)
        let jobs = await service.loadJobs()
        XCTAssertEqual(jobs.count, 1)
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(job.id, "abc123")
        XCTAssertEqual(job.name, "nightly-check")
        XCTAssertEqual(job.state, "done")
        XCTAssertEqual(job.tokens, 52341)
        XCTAssertEqual(job.sessionId, "sess-abc")
        XCTAssertEqual(job.output?.result, "All tests passed")

        // The secrets guarantee: nothing from providerEnv survives encoding of
        // what the app holds in memory for this job.
        let mirror = String(describing: job)
        XCTAssertFalse(mirror.contains("SECRET-VALUE"))
        XCTAssertFalse(mirror.contains("ANTHROPIC_API_KEY"))
    }

    func testJobsSortNewestFirst() async throws {
        try write("{\"state\":\"done\",\"updatedAt\":\"2026-08-01T00:00:00.000Z\"}", to: "jobs/old1/state.json")
        try write("{\"state\":\"running\",\"updatedAt\":\"2026-08-19T00:00:00.000Z\"}", to: "jobs/new1/state.json")

        let service = TasksJobsService(claudeDir: claudeDir)
        let jobs = await service.loadJobs()
        XCTAssertEqual(jobs.map(\.id), ["new1", "old1"])
    }

    func testJobTimelineParsesLines() async throws {
        try write("{\"state\":\"done\"}", to: "jobs/tj1/state.json")
        let timeline = """
        {"at":"2026-08-19T10:00:00.000Z","state":"started","detail":"","text":"kick off"}
        {"at":"2026-08-19T10:05:00.000Z","state":"stopped","detail":"","text":"done"}
        not json
        """
        try write(timeline, to: "jobs/tj1/timeline.jsonl")

        let service = TasksJobsService(claudeDir: claudeDir)
        let entries = await service.loadJobTimeline(jobId: "tj1")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].state, "started")
        XCTAssertEqual(entries[1].text, "done")
    }

    func testJobTimelineRejectsPathTraversal() async throws {
        try write("{\"at\":\"x\",\"state\":\"y\"}", to: "escape/timeline.jsonl")
        let service = TasksJobsService(claudeDir: claudeDir)
        let escaped = await service.loadJobTimeline(jobId: "../escape")
        XCTAssertTrue(escaped.isEmpty)
        let slashed = await service.loadJobTimeline(jobId: "a/b")
        XCTAssertTrue(slashed.isEmpty)
    }

    func testDaemonStatus() async throws {
        try write("{\"supervisorPid\":4242,\"supervisorProcStart\":\"x\",\"writtenAt\":1755600000000,\"workers\":{}}", to: "daemon.status.json")
        let service = TasksJobsService(claudeDir: claudeDir)
        let status = await service.loadDaemonStatus()
        XCTAssertEqual(status?.supervisorPid, 4242)
    }
}
