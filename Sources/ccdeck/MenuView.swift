import SwiftUI
import AppKit

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

/// "Next reset in … (Name)" plus a "Weekly reset in … (Name)." tail when a distinct
/// 7-day reset exists (skipped when the soonest reset is already the weekly one).
func resetLine(next: (date: Date, account: String), weekly: (date: Date, account: String)?) -> String {
    var line = "Next reset in \(relativeReset(next.date)) (\(next.account))"
    if let weekly, weekly.date != next.date {
        // Only tag the weekly account when it differs from the next-reset account.
        let tag = weekly.account == next.account ? "" : " (\(weekly.account))"
        line += ". Weekly reset in \(relativeReset(weekly.date))\(tag)."
    }
    return line
}

struct MenuView: View {
    @Bindable var model: AppModel
    @ObservedObject private var updater = AppUpdater.shared
    @State private var hoveredEmail: String?
    @State private var pendingDelete: Account?
    @State private var copiedEmail: String?
    @State private var statusCopied = false
    @State private var loginCode = ""
    @State private var showInfo = false

    /// App version from the bundle (e.g. "v0.1.0"), normalized to a leading "v".
    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        return v.hasPrefix("v") ? v : "v\(v)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()

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
            Text("\(acct.label) (\(acct.email)) will be removed from CC Deck.")
        }
    }

    // MARK: - Header

    /// Title bar: info button (left), "ccdeck" (center), version (right). A ZStack keeps
    /// the title truly centered regardless of the side items' widths.
    private var header: some View {
        ZStack {
            Text("ccdeck").font(.headline)
            HStack {
                Button { showInfo = true } label: {
                    Image(systemName: "info.circle").font(.callout)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("About CC Deck")
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { infoPopover }
                Spacer()
                Text(appVersion).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var infoPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CC Deck").font(.title3.bold())
            Text("A menu-bar dashboard for your Claude accounts. Tracks 5-hour and 7-day usage across multiple accounts. Auto-switch to another account before you hit a limit, and keep your Mac awake with one click.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Made with ♥️ by Wildan Zulfikar (@wzulfikar)")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Text("Github:").font(.callout).foregroundStyle(.secondary)
                Link("github.com/wzulfikar/ccdeck",
                     destination: URL(string: "https://github.com/wzulfikar/ccdeck")!)
                    .font(.callout)
            }
            if updater.isBrewManaged {
                Text("Updates via Homebrew. Run `brew upgrade ccdeck`")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 300)
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
            loginPrompt
        }
    }

    /// Shown while a `claude auth login` subprocess is running: paste the code from
    /// the browser here to finish sign-in.
    @ViewBuilder
    private var loginPrompt: some View {
        if model.isAwaitingLogin {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.loginURL == nil ? "Opening sign-in page…" : "Authorize in your browser…")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelAddAccount() }
                        .buttonStyle(.borderless).font(.caption2)
                }
                if model.loginURL != nil {
                    // Only needed if the browser shows a code to copy back; many logins
                    // finish on their own once you press Authorize.
                    HStack(spacing: 6) {
                        TextField("Code (only if shown)", text: $loginCode)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .onSubmit(submitLoginCode)
                        Button("Submit", action: submitLoginCode)
                            .font(.caption)
                            .disabled(loginCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func submitLoginCode() {
        model.submitLoginCode(loginCode)
        loginCode = ""
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

            // Inactive accounts show their reset here (always muted); the active
            // account shows it inline on each meter instead. Normally this is the
            // 5h reset (hidden when the idle window has no resets_at), but a weekly-
            // exhausted account shows its 7-day reset instead — that's what gates it.
            if !isActive, let u = model.usageByEmail[acct.email],
               let reset = u.sevenDayPct >= 100 ? u.sevenDayResets : u.fiveHourResets {
                Text("reset in \(relativeReset(reset))")
                    .font(.caption2)
                    .foregroundStyle(isResetUrgent(reset) ? .orange : .secondary)
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
                // Click to copy — flashes "email copied ✓" for 2s.
                Text(copiedEmail == acct.email ? "email copied ✓" : acct.email)
                    .font(.caption2)
                    .foregroundStyle(copiedEmail == acct.email ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { copyEmail(acct.email) }
            } else if let u = model.usageByEmail[acct.email] {
                // Weekly-exhausted accounts read 100% (orange); otherwise 5h usage,
                // which an idle window reads as 0%. Pairs with the reset above.
                let weeklyExceeded = u.sevenDayPct >= 100
                Text("\(weeklyExceeded ? 100 : Int(u.fiveHourPct))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(weeklyExceeded || u.fiveHourPct >= model.threshold ? .orange : .secondary)
            } else if let err = model.errorByEmail[acct.email] {
                // Passive error text (e.g. "…. Retrying…"). Unlike the active account,
                // more-accounts rows don't swap in "Click to retry now." on hover — the
                // hover slot here belongs to the Switch button. Tap still retries.
                let retrying = model.isAutoRetrying(email: acct.email)
                Text(err)
                    .font(.caption2).foregroundStyle(.orange)
                    .contentShape(Rectangle())
                    .help(retrying ? "Click to retry now" : "Click to retry")
                    .onTapGesture { Task { await model.retry(email: acct.email) } }
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

    /// Copy the email to the clipboard and flash "email copied ✓" for 2s.
    private func copyEmail(_ email: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(email, forType: .string)
        copiedEmail = email
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedEmail == email { copiedEmail = nil }
        }
    }

    /// Copy the status message to the clipboard and flash "Message copied ✓" for 2s.
    private func copyStatus() {
        let msg = model.statusMessage
        guard !msg.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(msg, forType: .string)
        statusCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            statusCopied = false
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
            // While auto-retrying, show the "…. Retrying…" text as-is (no manual affordance);
            // on hover, swap the tail for "Click to retry now." Once it's given up, fall back
            // to the plain tappable "… Click to retry." error.
            let retrying = model.isAutoRetrying(email: acct.email)
            let hovered = hoveredEmail == acct.email
            Text(retrying ? (hovered ? RetryPolicy.hoverMessage(err) : err) : "\(err). Click to retry.")
                .font(.caption).foregroundStyle(.orange)
                .contentShape(Rectangle())
                .help(retrying ? "Click to retry now" : "Click to retry")
                .onHover { hoveredEmail = $0 ? acct.email : (hoveredEmail == acct.email ? nil : hoveredEmail) }
                .onTapGesture { Task { await model.retry(email: acct.email) } }
        } else {
            Text("fetching usage…").font(.caption).foregroundStyle(.secondary)
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
                    Text(resetLine(next: next, weekly: model.nextWeeklyReset))
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
            settingToggle("Start at login", isOn: $model.startAtLoginEnabled)
            settingToggle("Show usage % in menu bar", isOn: $model.showUsageInMenuBar)

            updatesRow

            // Informational status sits on its own line above the buttons
            // (e.g. "Switched to …"). Space is reserved even when empty so the
            // label appearing/disappearing causes no layout shift.
            Text(statusCopied ? "Message copied ✓" : model.statusMessage)
                .font(.caption2)
                .foregroundStyle(statusCopied ? Color.green : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: 12, alignment: .leading)
                .padding(.top, 4)
                .contentShape(Rectangle())
                .help(model.statusMessage.isEmpty ? "" : "Click to copy")
                .onTapGesture { copyStatus() }

            HStack(spacing: 8) {
                Button("Get current login") {
                    Task { await model.captureCurrentLogin() }
                }
            }
            .font(.caption)

            loginPrompt

            HStack {
                Button { Task { await model.refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh now")
                Button { model.toggleStayAwake() } label: {
                    Text(model.shouldStayAwake ? "Stay awake ✓" : "Stay awake")
                        .foregroundStyle(model.shouldStayAwake ? Color.purple : Color.primary)
                }
                .help(model.shouldStayAwake ? "Stay awake ON. Click to allow sleep." : "Stay awake OFF. Click to prevent sleep.")
                .contextMenu {
                    Button("Remove keep-awake helper…") { model.removeStayAwakeHelper() }
                }
                if model.awaitingHelperApproval {
                    ProgressView()
                        .controlSize(.small)
                        .help("Waiting for helper approval in System Settings ▸ Login Items")
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
            .font(.caption)
        }
    }

    /// Update control: a "Check for Updates…" button when Sparkle is driving updates.
    /// Brew-managed installs show the `brew upgrade` hint in the info popover instead.
    /// Hidden entirely when no feed is configured yet (nothing actionable to show).
    @ViewBuilder
    private var updatesRow: some View {
        if updater.isActive {
            HStack {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .buttonStyle(.borderless).font(.callout)
                    .disabled(!updater.canCheckForUpdates)
                Spacer()
            }
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

    // Bar: red only when fully depleted, orange from 70% on, accent below. Text never
    // goes red (distracting) — just orange once it crosses 70%. Thresholds use
    // `fraction` so combined capacity (total > 100) bands by share-of-capacity, not raw %.
    private var barColor: Color { fraction >= 1.0 ? .red : (fraction >= 0.7 ? .orange : .accentColor) }
    private var textColor: Color { fraction >= 0.7 ? .orange : .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                if let reset, resetLeading {
                    Text("reset in \(relativeReset(reset))")
                        .font(.caption2)
                        .foregroundStyle(isResetUrgent(reset) ? .orange : .secondary)
                }
                Text(valueText).font(.caption.monospacedDigit()).foregroundStyle(textColor)
                if let reset, !resetLeading {
                    Text("· resets \(relativeReset(reset))")
                        .font(.caption2)
                        .foregroundStyle(isResetUrgent(reset) ? .orange : .secondary)
                }
            }
            ProgressView(value: min(value, total), total: max(total, 1))
                .tint(barColor)
        }
    }
}
