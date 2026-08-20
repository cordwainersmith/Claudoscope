import Foundation

/// Context-window sizes, used to show how close a session ran to its ceiling.
///
/// Kept out of `getModelFamily` on purpose: the family string is a UI label and an
/// analytics aggregation key, and splitting it to express a window would fork one
/// model's rows in every breakdown. Same reasoning as the pricing rate splits.
enum ContextWindow {
    static let standard = 200_000
    static let extended = 1_000_000

    /// Model generations that shipped with a 200K window. A closed list rather than
    /// a version comparison, and everything unrecognized gets the 1M window: every
    /// model from Claude 4.6 on has one, so an id nobody anticipated is far more
    /// likely to be 1M, and guessing low would flag healthy sessions as overflowing.
    private static let standardWindowMarkers = [
        "claude-3-opus", "claude-3-haiku", "claude-3-5-haiku",
        "opus-4-0", "opus-4-1", "opus-4-5",
        "sonnet-4-0", "sonnet-4-5",
        "haiku-4-5",
    ]

    static func tokens(for model: String?) -> Int {
        guard let model = model?.lowercased() else { return extended }
        return standardWindowMarkers.contains(where: model.contains) ? standard : extended
    }
}

/// Context occupancy at one assistant turn: everything the model had to read to
/// produce it (fresh input plus whatever came from cache), against its window.
struct ContextPressurePoint: Sendable, Equatable {
    let timestamp: String
    let contextTokens: Int
    let windowTokens: Int

    var utilization: Double {
        windowTokens > 0 ? Double(contextTokens) / Double(windowTokens) : 0
    }
}

extension ContextPressurePoint {
    /// Builds the per-turn series for a parsed session.
    ///
    /// Only billed assistant records count: streaming intermediates carry partial
    /// cumulative usage and would saw-tooth the curve. Context size is
    /// `input + cache_read + cache_creation`, which is the whole prompt the model
    /// saw — output tokens are what it wrote afterwards and are not in the window
    /// when the turn starts.
    static func series(for records: [ParsedRecordRaw]) -> [ContextPressurePoint] {
        var points: [ContextPressurePoint] = []
        var seenMessageIds: Set<String> = []

        for record in records {
            guard record.type == .assistant,
                  let message = record.message,
                  message.stopReason != nil,
                  let usage = message.usage,
                  let timestamp = record.timestamp
            else { continue }

            // One point per assistant message, not per record: a resumed or
            // continued file replays ids, and a duplicate would draw a flat spur.
            if let id = message.id {
                guard seenMessageIds.insert(id).inserted else { continue }
            }

            let context = (usage.inputTokens ?? 0)
                + (usage.cacheReadInputTokens ?? 0)
                + (usage.cacheCreationInputTokens ?? 0)
            guard context > 0 else { continue }

            points.append(ContextPressurePoint(
                timestamp: timestamp,
                contextTokens: context,
                windowTokens: ContextWindow.tokens(for: message.model)
            ))
        }

        return points
    }
}
