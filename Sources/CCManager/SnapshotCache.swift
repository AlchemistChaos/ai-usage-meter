import Foundation

/// Codex's local logs only ever describe the account that was active when the
/// call was made. To show meaningful numbers for accounts you aren't currently
/// using, we persist the last snapshot we saw for each account and label it with
/// its age, so a stale figure is never mistaken for a live one.
struct CachedSnapshot: Codable {
    var accountID: String
    var capturedAt: Date
    var plan: String?
    var windows: [CachedWindow]

    struct CachedWindow: Codable {
        var label: String
        var usedPercent: Double
        var windowMinutes: Int
        var resetsAt: Date?
    }

    /// Windows with elapsed time applied: a 5h window that reset an hour ago is
    /// empty again, and reporting the old percentage would be actively wrong.
    func projectedWindows(now: Date = Date()) -> [UsageWindow] {
        windows.map { w in
            let expired = w.resetsAt.map { $0 <= now } ?? false
            return UsageWindow(
                label: w.label,
                usedPercent: expired ? 0 : w.usedPercent,
                windowMinutes: w.windowMinutes,
                resetsAt: expired ? nil : w.resetsAt)
        }
    }
}

enum SnapshotCache {
    private static var fileURL: URL {
        ProfileStore.root.appending(path: "snapshots.json")
    }

    private static func loadAll() -> [String: CachedSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: CachedSnapshot].self, from: data)
        else { return [:] }
        return map
    }

    static func get(accountID: String) -> CachedSnapshot? {
        loadAll()[accountID]
    }

    static func put(accountID: String, snapshot: CodexProvider.Snapshot) {
        var all = loadAll()
        // Never let an older reading overwrite a newer one.
        if let existing = all[accountID], existing.capturedAt >= snapshot.capturedAt { return }
        all[accountID] = CachedSnapshot(
            accountID: accountID,
            capturedAt: snapshot.capturedAt,
            plan: snapshot.plan,
            windows: snapshot.windows.map {
                .init(label: $0.label,
                      usedPercent: $0.usedPercent,
                      windowMinutes: $0.windowMinutes,
                      resetsAt: $0.resetsAt)
            })
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
