import SwiftUI
import ServiceManagement

struct MenuView: View {
    @ObservedObject var manager: AccountManager
    @State private var importName = ""
    @State private var showImport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let rec = manager.recommended {
                RecommendationBanner(account: rec, isCurrent: rec.isActive) {
                    manager.switchTo(rec)
                }
            }

            Divider()

            ForEach(ProviderKind.allCases, id: \.self) { provider in
                let group = manager.accounts.filter { $0.provider == provider }
                if !group.isEmpty {
                    Text(provider.displayName.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group) { account in
                        AccountRow(account: account) { manager.switchTo(account) }
                    }
                }
            }

            if let err = manager.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Account Manager").font(.headline)
            Spacer()
            Button {
                manager.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showImport {
                HStack(spacing: 6) {
                    TextField("profile name", text: $importName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Button("Save") {
                        let name = importName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty else { return }
                        manager.importCurrent(.codex, as: name)
                        importName = ""
                        showImport = false
                    }
                    .font(.caption)
                }
                Text("Saves the Codex account you're logged into right now.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Button("Import current Codex login…") { showImport = true }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
            }

            Toggle("Launch at login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { on in
                    // Registration only sticks for a signed app installed at a
                    // stable path (/Applications), hence the installed build.
                    do {
                        if on { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        manager.lastError = "Launch at login: \(error.localizedDescription)"
                    }
                }))
                .font(.caption)
                .toggleStyle(.checkbox)

            HStack {
                if let r = manager.lastRefresh {
                    Text("Updated \(r.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RecommendationBanner: View {
    let account: Account
    let isCurrent: Bool
    let onSwitch: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isCurrent ? "checkmark.seal.fill" : "arrow.right.circle.fill")
                .foregroundStyle(isCurrent ? .green : .blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(isCurrent ? "Best account already active" : "Use \(account.label)")
                    .font(.system(size: 12, weight: .semibold))
                if let w = account.shortWindow {
                    Text("\(Int(w.remainingPercent))% left in \(w.label) window")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isCurrent {
                Button("Switch", action: onSwitch)
                    .font(.caption)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.blue.opacity(0.08)))
    }
}

private struct AccountRow: View {
    let account: Account
    let onSwitch: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle()
                    .fill(account.isActive ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
                Text(account.label)
                    .font(.system(size: 12, weight: account.isActive ? .semibold : .regular))
                    .lineLimit(1)
                if let plan = account.plan {
                    Text(plan.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.15)))
                }
                Spacer()
                if !account.isActive && account.status != .noData(reason: "") {
                    Button("Switch", action: onSwitch)
                        .font(.system(size: 10))
                        .opacity(hovering ? 1 : 0.35)
                }
            }

            if account.windows.isEmpty {
                Text(account.status.description)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(account.windows) { w in
                    UsageBar(window: w)
                }
                Text("data \(account.status.description)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }
}

private struct UsageBar: View {
    let window: UsageWindow

    private var tint: Color {
        switch window.usedPercent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(window.label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(tint)
                        .frame(width: max(2, geo.size.width * window.usedPercent / 100))
                }
            }
            .frame(height: 5)

            Text("\(Int(window.usedPercent))%")
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 32, alignment: .trailing)

            Text(window.resetsInDescription)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
