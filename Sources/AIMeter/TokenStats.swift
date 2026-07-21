import Foundation

/// Tokens consumed, summed from Claude Code's local session transcripts
/// (~/.claude/projects/*/*.jsonl — each assistant message carries a `usage`
/// block and the model that served it). Machine-wide: transcripts don't record
/// which account was active, so the numbers cover all Claude work on this Mac.
///
/// Codex intentionally has no equivalent — its local logs carry no token
/// counts, and inventing numbers would be worse than showing none.
struct TokenStats: Equatable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    /// What this usage would have cost on the pay-per-token API, in USD.
    /// The number that turns a subscription from a cap into a deal.
    var apiEquivalentDollars = 0.0

    var isEmpty: Bool { inputTokens == 0 && outputTokens == 0 && cacheReadTokens == 0 }

    static func formatCount(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    static func formatDollars(_ d: Double) -> String {
        if d >= 100 {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            return "$" + (f.string(from: NSNumber(value: d)) ?? String(format: "%.0f", d))
        }
        return String(format: "$%.2f", d)
    }

    // MARK: - Collection

    /// One pass over transcripts modified in the last 7 days, bucketing each
    /// entry into today and this-week totals. Runs off the main thread.
    static func collectWindows() -> (today: TokenStats, week: TokenStats) {
        var today = TokenStats()
        var week = TokenStats()
        let fm = FileManager.default
        let projects = fm.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
        let midnight = Calendar.current.startOfDay(for: Date())
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)

        guard let dirs = try? fm.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: nil) else { return (today, week) }

        for dir in dirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let mtime = try? file.resourceValues(
                        forKeys: [.contentModificationDateKey]).contentModificationDate,
                      mtime >= weekAgo,
                      let data = try? Data(contentsOf: file)
                else { continue }
                accumulate(from: data, weekCutoff: weekAgo, dayCutoff: midnight,
                           week: &week, today: &today)
            }
        }
        return (today, week)
    }

    private static func accumulate(
        from data: Data, weekCutoff: Date, dayCutoff: Date,
        week: inout TokenStats, today: inout TokenStats
    ) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Transcripts are JSONL; split on newlines and parse only lines that
        // plausibly contain a usage block, skipping the rest cheaply.
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.count > 40,
                  line.firstRange(of: Data("\"usage\"".utf8)) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }
            guard let ts = obj["timestamp"] as? String,
                  let date = iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts),
                  date >= weekCutoff
            else { continue }

            let input = (usage["input_tokens"] as? Int) ?? 0
            let cacheWrite = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let dollars = cost(
                model: message["model"] as? String ?? "",
                input: input, cacheWrite: cacheWrite,
                cacheRead: cacheRead, output: output)

            week.add(input: input + cacheWrite, output: output,
                     cacheRead: cacheRead, dollars: dollars)
            if date >= dayCutoff {
                today.add(input: input + cacheWrite, output: output,
                          cacheRead: cacheRead, dollars: dollars)
            }
        }
    }

    private mutating func add(input: Int, output: Int, cacheRead: Int, dollars: Double) {
        inputTokens += input
        outputTokens += output
        cacheReadTokens += cacheRead
        apiEquivalentDollars += dollars
    }

    // MARK: - Pricing

    /// Published API list prices per million tokens, matched by model family.
    /// Cache writes bill at 1.25× input, cache reads at 0.1× input.
    private static func rates(for model: String) -> (input: Double, output: Double) {
        let m = model.lowercased()
        if m.contains("haiku") { return (1, 5) }
        if m.contains("sonnet") { return (3, 15) }
        // Opus, Fable, and unknown flagship models get flagship rates.
        return (15, 75)
    }

    private static func cost(
        model: String, input: Int, cacheWrite: Int, cacheRead: Int, output: Int
    ) -> Double {
        let r = rates(for: model)
        return (Double(input) * r.input
                + Double(cacheWrite) * r.input * 1.25
                + Double(cacheRead) * r.input * 0.1
                + Double(output) * r.output) / 1_000_000
    }
}
