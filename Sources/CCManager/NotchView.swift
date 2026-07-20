import SwiftUI

/// The notch surface. Collapsed: a black shape that reads as part of the
/// hardware notch, with a live usage ring in each wing. Hovering springs it
/// open into the full dashboard.
struct NotchView: View {
    @ObservedObject var manager: AccountManager
    let notchWidth: CGFloat
    let onExpandChange: (Bool) -> Void

    @State private var expanded = false
    @State private var collapseTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            shell
            Spacer(minLength: 0)
        }
        .frame(width: NotchController.expandedSize.width,
               height: NotchController.expandedSize.height,
               alignment: .top)
    }

    private var shell: some View {
        Group {
            if expanded {
                ExpandedDashboard(manager: manager)
                    .frame(width: NotchController.expandedSize.width - 20)
                    .background(notchShape.fill(.black))
                    .overlay(notchShape.stroke(.white.opacity(0.08), lineWidth: 1))
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.86, anchor: .top).combined(with: .opacity),
                        removal: .opacity))
            } else {
                CollapsedWings(manager: manager, notchWidth: notchWidth)
                    .frame(width: notchWidth + NotchController.wingWidth * 2,
                           height: NotchController.collapsedHeight)
                    .background(notchShape.fill(.black))
            }
        }
        .onHover { hovering in
            collapseTask?.cancel()
            if hovering {
                setExpanded(true)
            } else {
                // Grace period so the pointer can travel within the panel
                // without the dashboard snapping shut.
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    setExpanded(false)
                }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: expanded)
    }

    private func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        if value {
            // Grow the window first so the animation has room.
            onExpandChange(true)
            expanded = true
        } else {
            expanded = false
            // Shrink the window after the collapse animation finishes.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 380_000_000)
                if !expanded { onExpandChange(false) }
            }
        }
    }

    /// Flat on top (merges into the bezel), rounded at the bottom.
    private var notchShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: 18,
            bottomTrailingRadius: 18, topTrailingRadius: 0,
            style: .continuous)
    }
}

// MARK: - Collapsed

/// One live ring per provider, sitting in the wings beside the notch.
private struct CollapsedWings: View {
    @ObservedObject var manager: AccountManager
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            wing(for: .claude)
                .frame(width: NotchController.wingWidth)
            Color.clear.frame(width: notchWidth)
            wing(for: .codex)
                .frame(width: NotchController.wingWidth)
        }
    }

    @ViewBuilder
    private func wing(for provider: ProviderKind) -> some View {
        let best = manager.accounts
            .filter { $0.provider == provider && $0.headroom != nil }
            .max { ($0.headroom ?? 0) < ($1.headroom ?? 0) }
        let window = best?.shortWindow ?? best?.longWindow

        HStack(spacing: 6) {
            UsageRing(usedPercent: window?.usedPercent, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                Text(provider == .claude ? "CLAUDE" : "CODEX")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .kerning(0.8)
                Text(window.map { "\(Int($0.remainingPercent))%" } ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Expanded

private struct ExpandedDashboard: View {
    @ObservedObject var manager: AccountManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Breathing room under the physical notch.
            Spacer().frame(height: 30)

            if let rec = manager.recommended {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.yellow)
                    Text(rec.isActive ? "Best account active — \(rec.label)"
                                      : "Switch to \(rec.label)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if let w = rec.shortWindow {
                        Text("\(Int(w.remainingPercent))% left")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(.white.opacity(0.6))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.06)))
            }

            ForEach(ProviderKind.allCases, id: \.self) { provider in
                let group = manager.accounts.filter {
                    $0.provider == provider && !($0.windows.isEmpty && !$0.isActive)
                }
                if !group.isEmpty {
                    Text(provider.displayName.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                        .kerning(1.2)
                    ForEach(group) { account in
                        NotchAccountRow(account: account)
                    }
                }
            }

            if !manager.todayTokens.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "number")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("today  \(TokenStats.formatCount(manager.todayTokens.inputTokens)) in"
                         + " · \(TokenStats.formatCount(manager.todayTokens.outputTokens)) out"
                         + " · \(TokenStats.formatCount(manager.todayTokens.cacheReadTokens)) cached")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }
}

private struct NotchAccountRow: View {
    let account: Account

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(account.isActive ? Color.green : .white.opacity(0.2))
                    .frame(width: 6, height: 6)
                Text(account.label)
                    .font(.system(size: 12, weight: account.isActive ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let plan = account.plan {
                    Text(plan.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
                Spacer()
                Text(account.status.description)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
            }
            ForEach(account.windows) { w in
                HStack(spacing: 8) {
                    Text(w.label)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 52, alignment: .leading)
                    GlowBar(usedPercent: w.usedPercent)
                    Text("\(Int(w.usedPercent))%")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 28, alignment: .trailing)
                    Text(w.resetsAt == nil ? "—"
                         : "\(w.resetsInDescription) · \(w.resetsAtDescription)")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.4))
                        .frame(width: 92, alignment: .trailing)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Shared pieces

/// Tint shared by rings and bars: green → orange → red as usage climbs.
private func usageColor(_ used: Double) -> Color {
    switch used {
    case ..<60: return Color(red: 0.3, green: 0.9, blue: 0.5)
    case ..<85: return .orange
    default: return Color(red: 1.0, green: 0.3, blue: 0.35)
    }
}

private struct UsageRing: View {
    let usedPercent: Double?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 3)
            if let used = usedPercent {
                // Arc = remaining budget, matching the % label beside it.
                Circle()
                    .trim(from: 0, to: max(0.03, (100 - used) / 100))
                    .stroke(usageColor(used),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: usageColor(used).opacity(0.6), radius: 3)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.6), value: usedPercent)
    }
}

private struct GlowBar: View {
    let usedPercent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(
                        colors: [usageColor(usedPercent).opacity(0.7),
                                 usageColor(usedPercent)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, geo.size.width * usedPercent / 100))
                    .shadow(color: usageColor(usedPercent).opacity(0.5), radius: 4)
            }
        }
        .frame(height: 4)
    }
}
