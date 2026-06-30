import SwiftUI

/// Coarse "time until reset" label. Shows only the largest unit: days (no hours),
/// hours (no minutes), or minutes (no seconds) — e.g. "4 days", "23 hrs", "26 min".
func relativeReset(_ date: Date, now: Date = Date()) -> String {
    let secs = date.timeIntervalSince(now)
    if secs <= 0 { return "now" }
    if secs >= 86400 {
        let d = Int(secs / 86400)
        return "\(d) day\(d == 1 ? "" : "s")"
    }
    if secs >= 3600 {
        let h = Int(secs / 3600)
        return "\(h) hr\(h == 1 ? "" : "s")"
    }
    return "\(max(1, Int(secs / 60))) min"
}

/// A reset is "urgent" (shown in orange) when it lands within the next hour.
func isResetUrgent(_ date: Date, now: Date = Date()) -> Bool {
    let secs = date.timeIntervalSince(now)
    return secs > 0 && secs < 3600
}

struct MenuView: View {
    @Bindable var model: AppModel
    @State private var hoveredEmail: String?
    @State private var pendingDelete: Account?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.accounts.isEmpty {
                emptyState
            } else {
                accountsSection
                Divider()
                combinedSection
            }

            Divider()
            controls
        }
        .padding(14)
        .frame(width: 320)
        .alert("Remove account?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { acct in
            Button("Remove", role: .destructive) {
                model.removeAccount(email: acct.email)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { acct in
            Text("\(acct.label) (\(acct.email)) will be removed from ccswitch.")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No accounts yet.").font(.subheadline)
            Text("Sign in to add your first account.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Add account…") { model.startAddAccount() }
                    .disabled(model.isAwaitingLogin)
                Button("Get current login") {
                    Task { await model.captureCurrentLogin() }
                }
            }
            if model.isAwaitingLogin {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Accounts (above the meters)

    private var accountsSection: some View {
        let active = model.accounts.first { $0.email == model.activeEmail }
        let others = model.accounts.filter { $0.email != model.activeEmail }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(active != nil ? "CURRENT ACCOUNT" : "ACCOUNTS")
                    .font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                Button("Add account…") { model.startAddAccount() }
                    .buttonStyle(.borderless).font(.caption2)
                    .disabled(model.isAwaitingLogin)
            }

            // The active account leads, with its meters inline right beneath it.
            if let active {
                accountRow(active)
                activeMeters(active)
            }

            // The remaining accounts sit under their own header (no divider needed).
            if !others.isEmpty {
                if active != nil {
                    Text("MORE ACCOUNTS")
                        .font(.caption2.bold()).foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                ForEach(others) { acct in
                    accountRow(acct)
                }
            }
        }
    }

    private func accountRow(_ acct: Account) -> some View {
        let isActive = acct.email == model.activeEmail
        let hovered = hoveredEmail == acct.email
        return HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(acct.label).font(.callout).lineLimit(1)

            // Inactive accounts show when their soonest window resets here (always
            // muted); the active account shows it inline on each meter instead.
            if !isActive, let reset = model.usageByEmail[acct.email]?.soonestReset() {
                Text("reset in \(relativeReset(reset))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Switch button reveals on hover, just before the usage %, no background.
            if hovered && !isActive {
                Button("Switch") { model.switchTo(email: acct.email) }
                    .buttonStyle(.borderless).font(.caption).foregroundStyle(.primary)
            }

            if isActive {
                // Active account shows its email here (where the % would be); the
                // per-window percentages live in the inline meters just below.
                Text(acct.email)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if let u = model.usageByEmail[acct.email] {
                Text("\(Int(max(u.fiveHourPct, u.sevenDayPct)))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(u.isExhausted(threshold: model.threshold) ? .orange : .secondary)
            } else if let err = model.errorByEmail[acct.email] {
                Text(err).font(.caption2).foregroundStyle(.orange)
            }

            // Trash sits next to the % (or email, for the active account).
            Button {
                pendingDelete = acct
            } label: { Image(systemName: "trash").font(.caption2) }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hoveredEmail = inside ? acct.email : (hoveredEmail == acct.email ? nil : hoveredEmail)
        }
    }

    // MARK: - Active account meters (inline, under the active row)

    @ViewBuilder
    private func activeMeters(_ acct: Account) -> some View {
        if let u = model.usageByEmail[acct.email] {
            GaugeRow(title: "5-hour", value: u.fiveHourPct, total: 100,
                     reset: u.fiveHourResets, resetLeading: true)
            GaugeRow(title: "7-day", value: u.sevenDayPct, total: 100,
                     reset: u.sevenDayResets, resetLeading: true)
        } else if let err = model.errorByEmail[acct.email] {
            Text(err).font(.caption).foregroundStyle(.orange)
        } else {
            Text("loading…").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Combined capacity across accounts

    @ViewBuilder
    private var combinedSection: some View {
        let c = model.combined
        if c.hasData {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("COMBINED CAPACITY").font(.caption2.bold()).foregroundStyle(.secondary)
                    Spacer()
                    // Total capacity up front, then the account count it spans.
                    Text("\(Int(c.total))% (\(c.accountsWithData) account\(c.accountsWithData == 1 ? "" : "s"))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                GaugeRow(title: "5-hour", value: c.usedFiveHour, total: c.total, reset: nil)
                GaugeRow(title: "7-day", value: c.usedSevenDay, total: c.total, reset: nil)
                if let next = model.nextReset {
                    Text("Next reset in \(relativeReset(next.date)) (\(next.account))")
                        .font(.caption2)
                        .foregroundStyle(isResetUrgent(next.date) ? .orange : .secondary)
                }
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SETTINGS").font(.caption2.bold()).foregroundStyle(.secondary)

            settingToggle("Auto-switch at \(Int(model.threshold))%", isOn: $model.autoSwitchEnabled)
            settingToggle("Show usage % in menu bar", isOn: $model.showUsageInMenuBar)

            HStack(spacing: 8) {
                Button("Get current login") {
                    Task { await model.captureCurrentLogin() }
                }
                if model.isAwaitingLogin {
                    ProgressView().controlSize(.small)
                }
                if !model.statusMessage.isEmpty {
                    Text(model.statusMessage)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.caption)

            HStack {
                Button { Task { await model.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh now")
                Button { model.toggleStayAwake() } label: {
                    Text(model.stayAwake ? "Stay awake ✓" : "Stay awake")
                        .foregroundStyle(model.stayAwake ? Color.orange : Color.primary)
                }
                .help(model.stayAwake ? "Stay awake: on — click to allow sleep" : "Stay awake: off — keep Mac awake")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .font(.caption)
        }
    }

    /// A label-left / switch-right settings row.
    private func settingToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A labeled progress bar for one quota window. `value`/`total` lets it show either a
/// single account (0–100) or combined capacity (0–N×100, e.g. 139 / 200).
private struct GaugeRow: View {
    let title: String
    let value: Double
    let total: Double
    let reset: Date?
    var resetLeading: Bool = false

    private var fraction: Double { total > 0 ? value / total : 0 }
    // Bar still scales against `total`; the label shows just the used %. Combined
    // capacity's total lives in the section header instead of every row.
    private var valueText: String { "\(Int(value))%" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                if let reset, resetLeading {
                    Text("reset in \(relativeReset(reset))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(valueText).font(.caption.monospacedDigit())
                if let reset, !resetLeading {
                    Text("· resets \(relativeReset(reset))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: min(value, total), total: max(total, 1))
                .tint(fraction >= 0.9 ? .red : (fraction >= 0.7 ? .orange : .accentColor))
        }
    }
}
