import Foundation

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
enum SnapshotCacheHarness {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_787_168_552)
        let snapshot = CachedSnapshot(
            accountID: "claude:active",
            capturedAt: now.addingTimeInterval(-4 * 60 * 60),
            plan: nil,
            windows: [
                .init(
                    label: "5h",
                    usedPercent: 24,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(-60)),
                .init(
                    label: "Weekly",
                    usedPercent: 39,
                    windowMinutes: 10_080,
                    resetsAt: now.addingTimeInterval(6 * 24 * 60 * 60)),
            ])

        let codexProjection = snapshot.projectedWindows(now: now)
        expect(
            codexProjection.first(where: { $0.label == "5h" })?.remainingPercent
                == 100,
            "default projection should preserve Codex's reset-to-empty behavior")

        let claudeProjection = snapshot.projectedWindows(
            now: now,
            dropsExpiredWindows: true)
        expect(
            claudeProjection.map(\.label) == ["Weekly"],
            "stale Claude cache should drop expired windows instead of reporting 100%")

        let olderWindow = CachedSnapshot.CachedWindow(
            label: "5h",
            usedPercent: 99,
            windowMinutes: 300,
            resetsAt: nil)
        let newerWindow = CachedSnapshot.CachedWindow(
            label: "5h",
            usedPercent: 22,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(60))
        let older = CachedSnapshot(
            accountID: "test",
            capturedAt: now.addingTimeInterval(1),
            plan: nil,
            windows: [olderWindow])
        let newerSameTimestamp = CachedSnapshot(
            accountID: "test",
            capturedAt: now,
            plan: nil,
            windows: [newerWindow])
        expect(
            !CachedSnapshot.shouldReplace(
                existing: older,
                with: newerSameTimestamp),
            "older cache writes should not replace newer snapshots")
        expect(
            CachedSnapshot.shouldReplace(
                existing: snapshot,
                with: CachedSnapshot(
                    accountID: snapshot.accountID,
                    capturedAt: snapshot.capturedAt,
                    plan: nil,
                    windows: [newerWindow])),
            "same-timestamp cache writes should replace reparsed snapshots")

        print("PASS: snapshot cache projection")
    }
}
