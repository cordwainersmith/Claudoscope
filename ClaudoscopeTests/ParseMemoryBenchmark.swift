import XCTest
@testable import Claudoscope

/// Memory and time of one `parseMetadata` over a real transcript. Disabled by
/// default; enable with `CLAUDOSCOPE_BENCH=1` and point `CLAUDOSCOPE_BENCH_FILE`
/// at a `.jsonl`. Prints footprint before, after and peak so the per-append
/// transient of the watcher path can be measured in isolation.
final class ParseMemoryBenchmark: XCTestCase {
    func testParseMetadataFootprint() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDOSCOPE_BENCH"] == "1",
              let path = ProcessInfo.processInfo.environment["CLAUDOSCOPE_BENCH_FILE"] else {
            throw XCTSkip("set CLAUDOSCOPE_BENCH=1 and CLAUDOSCOPE_BENCH_FILE")
        }
        let url = URL(fileURLWithPath: path)
        let parser = SessionParser()
        let pricing = PricingTables.anthropic
        let sessionId = url.deletingPathExtension().lastPathComponent
        let runs = Int(ProcessInfo.processInfo.environment["CLAUDOSCOPE_BENCH_RUNS"] ?? "3") ?? 3

        for run in 1...runs {
            let before = Self.footprintMB()
            let t0 = CFAbsoluteTimeGetCurrent()
            let summary = try await parser.parseMetadata(url: url, sessionId: sessionId, pricingTable: pricing)
            let dt = CFAbsoluteTimeGetCurrent() - t0
            let after = Self.footprintMB()
            print(String(format: "BENCH run=%d ms=%.1f before=%.1fMB after=%.1fMB peak=%.1fMB cost=%.4f msgs=%d",
                         run, dt * 1000, before.now, after.now, after.peak, summary.estimatedCost, summary.messageCount))
        }
    }

    static func footprintMB() -> (now: Double, peak: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (Double(info.phys_footprint) / 1_048_576, Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }
}

/// Footprint of the per-append derived refresh (analytics, attribution, hook
/// aggregates, cost alerts) over the real hydrated corpus. Same gating.
@MainActor
final class DerivedRefreshMemoryBenchmark: XCTestCase {
    func testRecomputeAnalyticsFootprint() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDOSCOPE_BENCH"] == "1" else {
            throw XCTSkip("set CLAUDOSCOPE_BENCH=1")
        }
        let store = SessionStore()
        let deadline = Date().addingTimeInterval(90)
        while (store.isLoading || store.allSessionsWithProjects.count < 100) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        print("BENCH sessions=\(store.allSessionsWithProjects.count) loading=\(store.isLoading) reconciling=\(store.isReconciling)")
        for run in 1...3 {
            let before = ParseMemoryBenchmark.footprintMB()
            let t0 = CFAbsoluteTimeGetCurrent()
            store.recomputeAnalytics()
            let dt = CFAbsoluteTimeGetCurrent() - t0
            let after = ParseMemoryBenchmark.footprintMB()
            print(String(format: "BENCH recompute run=%d ms=%.1f before=%.1fMB after=%.1fMB peak=%.1fMB",
                         run, dt * 1000, before.now, after.now, after.peak))
        }
    }
}

/// Footprint of what `ChatView.body` recomputes per evaluation over a full
/// parse: the file-history summary and checkpoint set.
final class ChatBodyMemoryBenchmark: XCTestCase {
    func testChatBodyDerivedFootprint() async throws {
        guard ProcessInfo.processInfo.environment["CLAUDOSCOPE_BENCH"] == "1",
              let path = ProcessInfo.processInfo.environment["CLAUDOSCOPE_BENCH_FILE"] else {
            throw XCTSkip("set CLAUDOSCOPE_BENCH=1 and CLAUDOSCOPE_BENCH_FILE")
        }
        let url = URL(fileURLWithPath: path)
        let parser = SessionParser()
        let sessionId = url.deletingPathExtension().lastPathComponent
        let b0 = ParseMemoryBenchmark.footprintMB()
        let session = try await parser.parse(url: url, sessionId: sessionId)
        let b1 = ParseMemoryBenchmark.footprintMB()
        print(String(format: "BENCH fullparse records=%d before=%.1fMB after=%.1fMB peak=%.1fMB",
                     session.records.count, b0.now, b1.now, b1.peak))
        for run in 1...3 {
            let before = ParseMemoryBenchmark.footprintMB()
            let t0 = CFAbsoluteTimeGetCurrent()
            let changes = FileHistoryService.summarize(records: session.records)
            let checkpoints = FileHistoryService.checkpointMessageIds(records: session.records)
            let pairs = Array(session.records.enumerated())
            let dt = CFAbsoluteTimeGetCurrent() - t0
            let after = ParseMemoryBenchmark.footprintMB()
            print(String(format: "BENCH chatbody run=%d ms=%.1f before=%.1fMB after=%.1fMB peak=%.1fMB changes=%d checkpoints=%d pairs=%d",
                         run, dt * 1000, before.now, after.now, after.peak, changes.count, checkpoints.count, pairs.count))
        }
    }
}

