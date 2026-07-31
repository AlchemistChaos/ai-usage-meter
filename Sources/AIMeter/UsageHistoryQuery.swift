import Foundation

struct UsageHistoryQuery {
    enum RangePreset: CaseIterable {
        case today
        case last24Hours
        case last7Days
        case last30Days
        case thisMonth
        case thisYear
    }

    struct SeriesPoint: Equatable {
        let bucketStart: Date
        let inputTokens: Int
        let outputTokens: Int
        let cacheWriteTokens: Int
        let cacheReadTokens: Int
        let totalTokens: Int
    }

    struct Series: Equatable {
        let preset: RangePreset
        let points: [SeriesPoint]
    }

    struct HistorySnapshot: Equatable {
        let today: AttributedTokenStats
        let last24Hours: AttributedTokenStats
        let last7Days: AttributedTokenStats
        let last30Days: AttributedTokenStats
        let thisMonth: AttributedTokenStats
        let thisYear: AttributedTokenStats
    }

    private enum BucketKind {
        case hour
        case day
        case month
    }

    let ledger: UsageLedger.SQLiteStore

    func snapshot(
        provider: ProviderKind,
        accountID: String?,
        now: Date = Date()
    ) throws -> HistorySnapshot {
        HistorySnapshot(
            today: try totals(provider: provider, accountID: accountID, preset: .today, now: now),
            last24Hours: try totals(provider: provider, accountID: accountID, preset: .last24Hours, now: now),
            last7Days: try totals(provider: provider, accountID: accountID, preset: .last7Days, now: now),
            last30Days: try totals(provider: provider, accountID: accountID, preset: .last30Days, now: now),
            thisMonth: try totals(provider: provider, accountID: accountID, preset: .thisMonth, now: now),
            thisYear: try totals(provider: provider, accountID: accountID, preset: .thisYear, now: now))
    }

    func series(
        provider: ProviderKind,
        accountID: String?,
        preset: RangePreset,
        now: Date = Date()
    ) throws -> Series {
        let bounds = dateBounds(for: preset, now: now)
        let rows = try ledger.events(
            provider: provider,
            accountID: accountID,
            start: bounds.start,
            end: bounds.end)
        let points = bucketedPoints(rows: rows, bounds: bounds, now: now)
        return Series(preset: preset, points: points)
    }

    private func totals(
        provider: ProviderKind,
        accountID: String?,
        preset: RangePreset,
        now: Date
    ) throws -> AttributedTokenStats {
        let bounds = dateBounds(for: preset, now: now)
        let total = try ledger.totals(
            provider: provider,
            accountID: accountID,
            start: bounds.start,
            end: bounds.end)
        return AttributedTokenStats(
            inputTokens: total.inputTokens,
            outputTokens: total.outputTokens,
            cacheWriteTokens: total.cacheWriteTokens,
            cacheReadTokens: total.cacheReadTokens,
            totalTokens: total.totalTokens,
            attribution: accountID == nil ? .unattributed : .observedActiveSpan)
    }

    private func bucketedPoints(
        rows: [UsageLedger.EventRow],
        bounds: (start: Date, end: Date, bucket: BucketKind),
        now: Date
    ) -> [SeriesPoint] {
        let buckets = bucketStarts(bounds: bounds, now: now)
        var sums: [Date: SeriesPoint] = [:]
        for bucket in buckets {
            sums[bucket] = SeriesPoint(
                bucketStart: bucket,
                inputTokens: 0,
                outputTokens: 0,
                cacheWriteTokens: 0,
                cacheReadTokens: 0,
                totalTokens: 0)
        }

        for row in rows {
            let bucket = bucketStart(for: row.timestamp, kind: bounds.bucket)
            guard var current = sums[bucket] else { continue }
            current = SeriesPoint(
                bucketStart: current.bucketStart,
                inputTokens: current.inputTokens + row.inputTokens,
                outputTokens: current.outputTokens + row.outputTokens,
                cacheWriteTokens: current.cacheWriteTokens + row.cacheWriteTokens,
                cacheReadTokens: current.cacheReadTokens + row.cacheReadTokens,
                totalTokens: current.totalTokens + row.totalTokens)
            sums[bucket] = current
        }

        return buckets.compactMap { sums[$0] }
    }

    private func bucketStarts(
        bounds: (start: Date, end: Date, bucket: BucketKind),
        now: Date
    ) -> [Date] {
        let cal = Calendar(identifier: .gregorian)
        switch bounds.bucket {
        case .hour:
            let endHour = bucketStart(for: now, kind: .hour)
            return (0..<24).map { cal.date(byAdding: .hour, value: $0 - 23, to: endHour)! }
        case .day:
            var dates: [Date] = []
            var current = bucketStart(for: bounds.start, kind: .day)
            let end = bucketStart(for: bounds.end, kind: .day)
            while current <= end {
                dates.append(current)
                current = cal.date(byAdding: .day, value: 1, to: current)!
            }
            return dates
        case .month:
            var dates: [Date] = []
            var current = bucketStart(for: bounds.start, kind: .month)
            let end = bucketStart(for: bounds.end, kind: .month)
            while current <= end {
                dates.append(current)
                current = cal.date(byAdding: .month, value: 1, to: current)!
            }
            return dates
        }
    }

    private func bucketStart(for date: Date, kind: BucketKind) -> Date {
        let cal = Calendar(identifier: .gregorian)
        switch kind {
        case .hour:
            let parts = cal.dateComponents([.year, .month, .day, .hour], from: date)
            return cal.date(from: parts)!
        case .day:
            return cal.startOfDay(for: date)
        case .month:
            let parts = cal.dateComponents([.year, .month], from: date)
            return cal.date(from: parts)!
        }
    }

    private func dateBounds(
        for preset: RangePreset,
        now: Date
    ) -> (start: Date, end: Date, bucket: BucketKind) {
        let cal = Calendar(identifier: .gregorian)
        switch preset {
        case .today:
            return (cal.startOfDay(for: now), now, .hour)
        case .last24Hours:
            return (now.addingTimeInterval(-24 * 3600), now, .hour)
        case .last7Days:
            return (now.addingTimeInterval(-7 * 86_400), now, .day)
        case .last30Days:
            return (now.addingTimeInterval(-30 * 86_400), now, .day)
        case .thisMonth:
            let start = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            return (start, now, .day)
        case .thisYear:
            let start = cal.date(from: cal.dateComponents([.year], from: now))!
            return (start, now, .month)
        }
    }
}
