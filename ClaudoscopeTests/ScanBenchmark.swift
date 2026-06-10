import XCTest
@testable import Claudoscope

/// Cold-cache scan benchmark for the SessionParser single-pass refactor.
/// Disabled by default; enable with `CLAUDOSCOPE_BENCH=1`. Performs one timed
/// run of `ProjectScanner.scan()` against the real `~/.claude/projects` tree
/// and prints `BENCH_MS=<value>` to stdout. The driver script in
/// `scripts/bench-scan.sh` purges the page cache between invocations and
/// repeats N times per version.
final class ScanBenchmark: XCTestCase {
    func testColdScan() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDOSCOPE_BENCH"] == "1" else {
            throw XCTSkip("set CLAUDOSCOPE_BENCH=1 to enable")
        }
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        guard FileManager.default.fileExists(atPath: claudeDir.appendingPathComponent("projects").path) else {
            throw XCTSkip("no real ~/.claude/projects directory")
        }
        let parser = SessionParser()
        let pricing = PricingTables.anthropic
        let scanner = ProjectScanner(claudeDir: claudeDir, parser: parser, pricingTable: pricing)

        let t0 = CFAbsoluteTimeGetCurrent()
        let (projects, sessions) = await scanner.scan()
        let dt = CFAbsoluteTimeGetCurrent() - t0
        let totalSessions = sessions.values.reduce(0) { $0 + $1.count }
        print(String(format: "BENCH_MS=%.1f projects=%d sessions=%d",
                     dt * 1000, projects.count, totalSessions))
    }

    /// Micro-benchmark for the windowed `AnalyticsEngine.compute` projection added
    /// for per-day cost attribution. Gated like the scan benchmark. Builds a
    /// synthetic many-day, many-session dataset in memory and times one compute.
    func testComputeProjectionBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDOSCOPE_BENCH"] == "1" else {
            throw XCTSkip("set CLAUDOSCOPE_BENCH=1 to enable")
        }
        let parser = SessionParser()
        let pricing = PricingTables.anthropic

        // One 60-day session (60 daily contributions), then replicated.
        let base = ISO8601.parse("2026-01-01T12:00:00.000Z")!
        var lines: [String] = []
        for i in 0..<60 {
            let d = Calendar.current.date(byAdding: .day, value: i, to: base)!
            let ts = ISO8601.withFractional.string(from: d)
            lines.append("{\"type\":\"assistant\",\"uuid\":\"u\(i)\",\"sessionId\":\"sess-1\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"assistant\",\"id\":\"m\(i)\",\"stop_reason\":\"end_turn\",\"model\":\"claude-opus-4-5-20250120\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":2000,\"service_tier\":\"standard\"}}}")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let one = try await parser.parseMetadata(url: url, sessionId: "sess-1", pricingTable: pricing)

        let project = Project(id: "proj", name: "Proj", path: "/tmp", sessionCount: 1)
        let sessions = Array(repeating: (session: one, project: project), count: 2000)

        let t0 = CFAbsoluteTimeGetCurrent()
        let data = AnalyticsEngine.compute(sessions: sessions, pricingTable: pricing, from: nil, to: nil)
        let dt = CFAbsoluteTimeGetCurrent() - t0
        print(String(format: "COMPUTE_MS=%.2f sessions=%d days=%d totalCost=%.2f",
                     dt * 1000, sessions.count, one.dailyContributions.count, data.totalCost))
    }
}
