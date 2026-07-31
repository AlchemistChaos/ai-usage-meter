import SwiftUI

struct UsageHistoryView: View {
    let account: Account
    let hourlySeries: UsageHistoryQuery.Series
    let dailySeries: UsageHistoryQuery.Series
    let monthlySeries: UsageHistoryQuery.Series

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(account.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                HistorySection(title: "Last 24 hours", series: hourlySeries)
                HistorySection(title: "Last 30 days", series: dailySeries)
                HistorySection(title: "This year", series: monthlySeries)
            }
            .padding(14)
        }
        .frame(width: 520, height: 540)
        .preferredColorScheme(.dark)
    }
}

private struct HistorySection: View {
    let title: String
    let series: UsageHistoryQuery.Series

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(series.points.enumerated()), id: \.offset) { _, point in
                HStack(spacing: 8) {
                    Text(label(for: point.bucketStart))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text("in \(TokenStats.formatCount(point.inputTokens))")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("out \(TokenStats.formatCount(point.outputTokens))")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                }
            }
        }
        .padding(10)
        .background(.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func label(for date: Date) -> String {
        let formatter = DateFormatter()
        switch series.preset {
        case .last24Hours, .today:
            formatter.dateFormat = "HH:mm"
        case .thisYear:
            formatter.dateFormat = "MMM"
        default:
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }
}
