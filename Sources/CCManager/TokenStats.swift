import Foundation

/// Tokens consumed today, summed from Claude Code's local session transcripts
/// (~/.claude/projects/*/*.jsonl — each assistant message carries a `usage`
/// block). This is machine-wide: transcripts don't record which account was
/// active, so the numbers cover all Claude work on this Mac today.
///
/// Codex intentionally has no equivalent — its local logs carry no token
/// counts, and inventing numbers would be worse than showing none.
struct TokenStats: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0

    var isEmpty: Bool { inputTokens == 0 && outputTokens == 0 && cacheReadTokens == 0 }

    static func formatCount(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    /// Sum today's usage. Reads only transcripts modified since local midnight,
    /// so cost stays proportional to today's activity. Runs off the main
    /// thread — call from a background task.
    static func collectToday() -> TokenStats {
        var stats = TokenStats()
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
        let midnight = Calendar.current.startOfDay(for: Date())

        guard let dirs = try? fm.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil) else { return stats }

        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let mtime = try? file.resourceValues(
                        forKeys: [.contentModificationDateKey]).contentModificationDate,
                      mtime >= midnight,
                      let data = try? Data(contentsOf: file)
                else { continue }
                accumulate(from: data, since: midnight, into: &stats)
            }
        }
        return stats
    }

    private static func accumulate(from data: Data, since cutoff: Date, into stats: inout TokenStats) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Transcripts are JSONL; split on newlines and parse only lines that
        // plausibly contain a usage block, skipping the rest cheaply.
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.count > 40,
                  line.firstRange(of: Data("\"usage\"".utf8)) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let usage = (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
            else { continue }
            // Old lines can live in a today-modified file; filter by timestamp.
            if let ts = obj["timestamp"] as? String,
               let date = iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts),
               date < cutoff { continue }
            stats.inputTokens += (usage["input_tokens"] as? Int) ?? 0
                + ((usage["cache_creation_input_tokens"] as? Int) ?? 0)
            stats.outputTokens += (usage["output_tokens"] as? Int) ?? 0
            stats.cacheReadTokens += (usage["cache_read_input_tokens"] as? Int) ?? 0
        }
    }
}
