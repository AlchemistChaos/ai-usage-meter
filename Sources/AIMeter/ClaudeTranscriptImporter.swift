import Foundation

struct ClaudeTranscriptImporter {
    let projectsRoot: URL
    let ledger: UsageLedger.SQLiteStore
    let timeline: AccountTimelineStore.SQLiteStore
    let knownProfileCount: () -> Int
    var singleKnownAccountID: () -> String? = { nil }

    func run(now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: projectsRoot.path()) else { return }
        for transcript in transcriptFiles() {
            try importTranscript(transcript)
        }
    }

    private func transcriptFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: projectsRoot,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }

    private func importTranscript(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            try importLine(Data(line))
        }
    }

    private func importLine(_ data: Data) throws {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = obj["uuid"] as? String,
              let timestamp = obj["timestamp"] as? String,
              let date = ISO8601DateFormatter().date(from: timestamp),
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return }

        let sessionID = (obj["sessionId"] as? String)
            ?? (obj["session_id"] as? String)
            ?? "unknown"
        let input = (usage["input_tokens"] as? Int) ?? 0
        let cacheWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
        let output = (usage["output_tokens"] as? Int) ?? 0
        let total = input + cacheWrite + cacheRead + output
        guard total > 0 else { return }

        let attributed = try attributedAccount(for: date)
        try ledger.upsert(event: .init(
            externalID: "claude:\(sessionID):\(uuid)",
            provider: .claude,
            accountID: attributed.accountID,
            timestamp: date,
            inputTokens: input,
            outputTokens: output,
            cacheWriteTokens: cacheWrite,
            cacheReadTokens: cacheRead,
            totalTokens: total,
            source: "claude-transcript",
            attribution: attributed.attribution))
    }

    private func attributedAccount(for timestamp: Date) throws -> (
        accountID: String?, attribution: TokenAttribution
    ) {
        if let accountID = try timeline.accountID(for: .claude, timestamp: timestamp) {
            return (accountID, .observedActiveSpan)
        }
        if knownProfileCount() == 1, let accountID = singleKnownAccountID() {
            return (accountID, .singleProfileFallback)
        }
        return (nil, .unattributed)
    }
}
