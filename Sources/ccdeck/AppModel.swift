import Foundation
import Observation
import AppKit
import ServiceManagement

/// Central state + orchestration: account roster, live usage, polling, and the
/// auto-switch policy. Everything runs on the main actor.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    // Persisted/derived state surfaced to the UI.
    private(set) var accounts: [Account] = []
    private(set) var usageByEmail: [String: Usage] = [:]
    private(set) var errorByEmail: [String: String] = [:]
    // Tokens consumed since local midnight, summed across all Claude Code sessions
    // (not per-account — see TokenUsageScanner). Scanned lazily when the popover opens,
    // stale-while-revalidate: the last value is persisted and shown immediately while a
    // fresh scan runs in the background.
    private(set) var tokensToday: TokenUsageToday?
    // Activity insights (prompts, tool calls, rate-limits, top tools/skills/MCP) for the
    // selected period, shown in place of the chart. Toggled by tapping the summary numbers;
    // recomputed (a transcript walk) whenever it's shown and the period changes. Not
    // persisted, so a cold open starts on the chart.
    var insightsShown = false
    private(set) var periodInsights: TodayInsights?
    /// True while the insights panel should be on screen (toggled on and its data has landed).
    var showingInsights: Bool { insightsShown && periodInsights != nil }
    private(set) var isScanningTokens = false
    private var lastTokenScan: Date?
    // Which span the tokens row + chart show. Cycles today → 7-day → 30-day on click.
    // Persisted so it survives popover reopens.
    var usageWindow: UsageWindow {
        didSet {
            store.setSetting("usageWindow", usageWindow.rawValue)
            recomputeUsage()
        }
    }
    // When set, the chart drills into this single day's hourly bars, overriding the
    // multi-day window. Set by tapping a day's bar in the 7/30-day chart; cleared by
    // cycling the window or an empty-area tap. Not persisted — drill-in is transient.
    private(set) var selectedDay: Date?
    /// Header label for the tokens block: the drilled day, else the window's own title.
    /// Unchanged by the insights toggle — the title always names the period.
    var usageTitle: String { selectedDay.map { Self.dayTitle($0) } ?? usageWindow.title }
    /// Chart x-axis granularity: hourly while drilled into a day, else the window's unit.
    var usageBarUnit: Calendar.Component { selectedDay != nil ? .hour : usageWindow.barUnit }
    // Derived from the hourly_usage history for `usageWindow`, recomputed after each scan
    // and on window change. `usageBars` drives the chart; `usageSummary` the tokens/cost/
    // delta line. Both nil until history has been read at least once.
    private(set) var usageBars: [UsageBar] = []
    private(set) var usageSummary: UsageSummary?
    // Fixed x-axis span for the chart so empty leading/trailing buckets don't shrink it.
    private(set) var usageDomain: ClosedRange<Date>?
    // Anthropic model prices (per MTok) from models.dev, keyed by model id. Cached in the
    // Store and revalidated on launch (stale-while-revalidate). Empty until first fetch;
    // costTodayUSD stays nil while empty so the UI just omits the "~$" suffix.
    private(set) var modelPrices: [String: ModelCost] = [:]
    private(set) var activeEmail: String?
    private(set) var lastRefresh: Date?
    var statusMessage: String = ""

    // Settings.
    var autoSwitchEnabled: Bool {
        didSet { store.setSetting("autoSwitch", autoSwitchEnabled ? "1" : "0") }
    }
    var showUsageInMenuBar: Bool {
        didSet { store.setSetting("showUsageInMenuBar", showUsageInMenuBar ? "1" : "0") }
    }
    // Dock icon visibility. `.regular` shows it, `.accessory` hides it (menu-bar item stays).
    var showDockIcon: Bool {
        didSet {
            store.setSetting("showDockIcon", showDockIcon ? "1" : "0")
            applyDockIconVisibility()
        }
    }
    // Whether the SETTINGS section is expanded. Persisted so it survives menu-bar
    // window reopens (the view's @State would reset on each recreation).
    var settingsExpanded: Bool {
        didSet { store.setSetting("settingsExpanded", settingsExpanded ? "1" : "0") }
    }
    // Launch-at-login via SMAppService. Truth lives in the registration status, not our
    // store — so we mirror the real state on init and toggle the app's login item on change.
    var startAtLoginEnabled: Bool {
        didSet {
            guard !suppressLoginItemUpdate else { return }
            applyStartAtLogin()
        }
    }
    private var suppressLoginItemUpdate = false
    let threshold: Double = 90

    // Keep-awake (caffeinate -s equivalent). Persisted so an app relaunch —
    // e.g. `brew upgrade ccdeck` — re-establishes it instead of silently
    // dropping the assertion (see restoreStayAwake, called from start()).
    private let stayAwake = StayAwake()
    private let clamshell = ClamshellMonitor()
    private(set) var shouldStayAwake = false
    // True while we're polling for the user to approve the helper in Login Items —
    // drives the menu-bar loading pulse and the spinner beside the Stay-awake button.
    private(set) var awaitingHelperApproval = false
    private var approvalPollTask: Task<Void, Never>?

    // Accounts whose first usage fetch is still in flight (including auto-retries) and have
    // no data yet — drives the menu-bar "loading" pulse + 0% gauge. See `RetryPolicy`.
    private(set) var loadingEmails: Set<String> = []
    private var retryTasks: [String: Task<Void, Never>] = [:]

    private let store: Store
    private var timer: Timer?
    private let pollInterval: TimeInterval = 30
    private var loginWatch: Task<Void, Never>?
    private(set) var isAwaitingLogin = false

    // Live `claude auth login` subprocess (Terminal-free flow). We keep the process
    // and its stdin so we can feed the pasted auth code, and surface the sign-in URL.
    private var loginProcess: Process?
    private var loginStdin: FileHandle?
    private(set) var loginURL: URL?

    init() {
        let store = Store()
        self.store = store
        self.autoSwitchEnabled = store.getSetting("autoSwitch") == "1"
        self.showUsageInMenuBar = store.getSetting("showUsageInMenuBar") == "1"  // default off
        self.showDockIcon = store.getSetting("showDockIcon") != "0"  // default on
        self.settingsExpanded = store.getSetting("settingsExpanded") == "1"  // default off
        self.usageWindow = store.getSetting("usageWindow").flatMap(UsageWindow.init) ?? .today
        self.startAtLoginEnabled = SMAppService.mainApp.status == .enabled
        self.accounts = store.listAccounts()
        self.activeEmail = store.getSetting("activeEmail")
        // Restore the last usage readings so combined capacity + per-account gauges render
        // instantly on open — stale-while-revalidate. The 30s poll (and cold-start loads)
        // overwrite each with fresh data. If a fetch fails or is still in flight, the cached
        // value stays on screen instead of collapsing to "Data not available".
        if let json = store.getSetting("usageByEmail")?.data(using: .utf8),
           let cached = try? JSONDecoder().decode([String: Usage].self, from: json) {
            self.usageByEmail = cached
        }
        self.shouldStayAwake = store.getSetting("stayAwake") == "1"  // default off
        // Restore the last token total — but only if it's from today; a value stamped
        // on an earlier day would show yesterday's number until the rescan lands.
        if let json = store.getSetting("tokensToday")?.data(using: .utf8),
           let cached = try? JSONDecoder().decode(TokenUsageToday.self, from: json),
           cached.day == Calendar.current.startOfDay(for: Date()) {
            self.tokensToday = cached
        }
        // Restore the last price table so cost renders instantly on open; start() kicks a
        // fresh fetch to revalidate.
        if let json = store.getSetting("modelPrices")?.data(using: .utf8),
           let cached = try? JSONDecoder().decode([String: ModelCost].self, from: json) {
            self.modelPrices = cached
        }
        detectActiveFromKeychain()
    }

    /// Register/unregister the app as a login item. On failure we surface the reason and
    /// snap the toggle back to reality (suppressing the observer so it doesn't re-fire).
    private func applyStartAtLogin() {
        do {
            if startAtLoginEnabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            statusMessage = "Start at login failed: \(error.localizedDescription)"
            suppressLoginItemUpdate = true
            startAtLoginEnabled.toggle()
            suppressLoginItemUpdate = false
        }
    }

    /// Show/hide the Dock icon by switching the activation policy. `.accessory` keeps the
    /// menu-bar item and popover working while dropping the Dock tile; re-activate when
    /// switching back so the newly shown icon takes focus.
    func applyDockIconVisibility() {
        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
        if showDockIcon { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        restoreStayAwake()
        Task { @MainActor in await refreshPrices() }
        // Seed the usage history once from existing transcripts, then render the chart from
        // whatever's stored. Backfill is a full-tree walk so it runs off the main actor and
        // only the first launch after this feature ships pays for it.
        Task { @MainActor in
            // Seed tokens + insights together. Gated on the insight flag so an existing
            // install (tokens already backfilled) still walks once to seed insight history;
            // the token re-insert is an idempotent upsert.
            if store.getSetting("insightsBackfilled") != "1" {
                let bf = await TokenUsageScanner.shared.backfillHistory()
                store.insertHours(bf.hourly)
                store.insertInsights(bf.insights)
                store.setSetting("historyBackfilled", "1")
                store.setSetting("insightsBackfilled", "1")
            }
            recomputeUsage()
        }
        // First load retries with backoff so a cold-start 429 recovers on its own instead of
        // stranding a "Fetch failed" the user has to click. The 30s poll below stays single-shot.
        // Stagger cold-start fetches: firing every account at once bursts the usage endpoint
        // and trips per-IP 429s. While running, refreshAll() is already sequential so it's fine.
        for (i, account) in accounts.enumerated() {
            scheduleInitialLoad(account, delay: Double(i) * 2)
        }
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// First-load fetch for one account: retry on a fixed interval up to `RetryPolicy`'s cap,
    /// showing "…. Retrying…" between tries, then leave a bare (tappable) error if it never
    /// succeeds. `loadingEmails` marks it as loading throughout so the menu bar pulses.
    private func scheduleInitialLoad(_ account: Account, delay: TimeInterval = 0) {
        let email = account.email
        retryTasks[email]?.cancel()
        retryTasks[email] = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            if Task.isCancelled { return }
            await self?.loadWithRetry(account)
            self?.retryTasks[email] = nil
        }
    }

    private func loadWithRetry(_ account: Account) async {
        let email = account.email
        loadingEmails.insert(email)
        defer { loadingEmails.remove(email) }

        for attempt in 1...RetryPolicy.maxAttempts {
            if Task.isCancelled { return }
            await refresh(account)
            if errorByEmail[email] == nil {           // fetched — done
                autoSwitchIfNeeded()
                lastRefresh = Date()
                return
            }
            guard RetryPolicy.shouldRetry(afterAttempt: attempt) else { break }
            errorByEmail[email] = RetryPolicy.retryingMessage(base: errorByEmail[email] ?? "Fetch failed")
            try? await Task.sleep(for: .seconds(RetryPolicy.delay()))
        }
        lastRefresh = Date()                          // gave up — bare error stays for tap-to-retry
    }

    private func tick() async {
        await refreshAll()
    }

    // MARK: - Keep-awake

    func toggleStayAwake() {
        let target = !shouldStayAwake
        shouldStayAwake = target
        store.setSetting("stayAwake", target ? "1" : "0")
        statusMessage = ""
        // Power assertion handles idle sleep instantly, no privileges needed.
        if target {
            stayAwake.start()
            // While awake, power the internal panel off whenever the lid shuts —
            // the system keeps running (disablesleep), only the display sleeps.
            clamshell.onLidClosed = { DisplayControl.sleepNow() }
            clamshell.start()
            // The privileged helper adds lid-close-on-battery suppression via pmset.
            // First time (or after removal) it needs a one-time install + approval.
            enableLidCloseHelper()
        } else {
            stayAwake.stop()
            clamshell.stop()
            cancelApprovalWait()
            Task { try? await HelperManager.shared.setDisableSleep(false) }
        }
    }

    /// Re-establish keep-awake on launch if it was on when we last quit — the
    /// in-process assertion and pmset suppression die with the old process (e.g.
    /// on `brew upgrade`), so we rebuild them. Never prompts: the helper was set
    /// up when the user first enabled it, so we only re-apply if it's ready.
    private func restoreStayAwake() {
        guard shouldStayAwake else { return }
        stayAwake.start()
        clamshell.onLidClosed = { DisplayControl.sleepNow() }
        clamshell.start()
        if HelperManager.shared.state == .ready {
            Task { await applyDisableSleep(true) }
        }
    }

    /// Turn on privileged lid-close suppression, walking the user through the
    /// one-time helper install + Login Items approval when it isn't ready yet.
    private func enableLidCloseHelper() {
        switch HelperManager.shared.state {
        case .ready:
            Task { await applyDisableSleep(true) }
        case .notInstalled:
            promptInstallHelper()
        case .awaitingApproval:
            HelperManager.shared.openLoginItems()
            beginApprovalWait()
        }
    }

    /// One-time consent alert before we register the privileged daemon. Explains
    /// what the helper is for and that macOS will ask them to approve it.
    private func promptInstallHelper() {
        let alert = NSAlert()
        alert.messageText = "Keep the Mac awake with the lid closed?"
        alert.informativeText = """
        ccdeck installs a small background helper so it can stay awake on battery \
        with the lid shut. There's no approval popup, macOS just adds ccdeck to \
        System Settings ▸ Login Items ▸ Allow in the Background. We'll open it for \
        you, switch ccdeck on there.

        Idle sleep is already blocked without it; this only adds lid-closed.
        """
        alert.addButton(withTitle: "Install Helper")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try HelperManager.shared.register()
        } catch {
            statusMessage = "Couldn't install the helper: \(error.localizedDescription)"
            return
        }
        // A prior approval may still be remembered → straight to ready, no trip
        // to Settings needed. Otherwise open Login Items so the user can flip it on.
        if HelperManager.shared.state == .ready {
            Task { await applyDisableSleep(true) }
        } else {
            HelperManager.shared.openLoginItems()
            beginApprovalWait()
        }
    }

    /// Poll the daemon status until the user approves it in Login Items (or we
    /// time out / they toggle back off). `awaitingHelperApproval` pulses the UI.
    private func beginApprovalWait() {
        awaitingHelperApproval = true
        statusMessage = "Waiting for approval, click Allow for ccdeck in System Settings ▸ Login Items."
        approvalPollTask?.cancel()
        approvalPollTask = Task { @MainActor [weak self] in
            for _ in 0..<120 {                       // ~60s at 500ms
                if Task.isCancelled { return }
                if HelperManager.shared.state == .ready {
                    self?.awaitingHelperApproval = false
                    await self?.applyDisableSleep(true)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard let self, self.awaitingHelperApproval else { return }
            self.awaitingHelperApproval = false
            if self.shouldStayAwake {
                self.statusMessage = "Still not approved. Approve ccdeck in System Settings ▸ Login Items, then toggle Stay awake again."
            }
        }
    }

    private func cancelApprovalWait() {
        approvalPollTask?.cancel()
        approvalPollTask = nil
        awaitingHelperApproval = false
    }

    /// Apply the privileged lid-close toggle, surfacing any XPC failure.
    private func applyDisableSleep(_ on: Bool) async {
        do {
            try await HelperManager.shared.setDisableSleep(on)
            if on { statusMessage = "" }
        } catch {
            statusMessage = "Lid-close keep-awake unavailable (\(error.localizedDescription)). Idle sleep still blocked; keep the lid open."
        }
    }

    /// Fully remove the privileged helper: clear sleep suppression, then
    /// unregister the daemon (drops it from System Settings ▸ Login Items).
    func removeStayAwakeHelper() {
        shouldStayAwake = false
        store.setSetting("stayAwake", "0")
        stayAwake.stop()
        clamshell.stop()
        cancelApprovalWait()
        Task {
            try? await HelperManager.shared.setDisableSleep(false)
            HelperManager.shared.unregister()
            statusMessage = "Keep-awake helper removed."
        }
    }

    // MARK: - Polling

    func refreshAll() async {
        for (i, account) in accounts.enumerated() {
            // Space accounts out so the poll doesn't burst the per-IP usage limit (the
            // same failure the cold-start stagger avoids), then give a rate-limited
            // account a couple of quick retries — honoring Retry-After — so a transient
            // 429 clears on its own instead of showing "Fetch failed" for the full 30s.
            if i > 0 { try? await Task.sleep(for: .seconds(RetryPolicy.pollStagger)) }
            var result = await refresh(account)
            var attempt = 1
            while case let .retriable(after) = result, attempt <= RetryPolicy.pollMaxRetries {
                try? await Task.sleep(for: .seconds(RetryPolicy.pollDelay(retryAfter: after, attempt: attempt)))
                result = await refresh(account)
                attempt += 1
            }
        }
        lastRefresh = Date()
        autoSwitchIfNeeded()
    }

    /// Re-scan Claude Code transcripts for today's token total, stale-while-revalidate:
    /// the existing `tokensToday` stays on screen while this runs, then swaps to the fresh
    /// value. Triggered when the popover opens — not on the 30s poll — so idle sessions do
    /// no disk work. Incremental + off the main actor, so a scan is cheap.
    func refreshTokenUsage() async {
        // Throttle: at most one scan per poll interval. Reopening the popover moments
        // after a scan just reuses the value already on screen.
        if let last = lastTokenScan, Date().timeIntervalSince(last) < pollInterval { return }
        lastTokenScan = Date()
        isScanningTokens = true
        defer { isScanningTokens = false }
        let scan = await TokenUsageScanner.shared.scanToday()
        tokensToday = scan.today
        if let json = try? JSONEncoder().encode(scan.today), let s = String(data: json, encoding: .utf8) {
            store.setSetting("tokensToday", s)
        }
        // Mirror today's hour buckets into history, replacing today's rows so a restart
        // (which re-scans today from scratch) can't double-count. Prune past the 60-day cap.
        let dayStart = Calendar.current.startOfDay(for: Date())
        let fromEpoch = Int(dayStart.timeIntervalSince1970) / 3600 * 3600
        let rows = scan.hourly.flatMap { hour, models in
            models.map { HourlyRow(hourEpoch: hour, model: $0.key, tokens: $0.value) }
        }
        let pruneEpoch = Int(Date().addingTimeInterval(-61 * 86_400).timeIntervalSince1970)
        store.replaceHours(fromEpoch: fromEpoch, rows: rows)
        store.replaceInsights(fromEpoch: fromEpoch, rows: scan.insights)
        store.pruneHours(beforeEpoch: pruneEpoch)
        store.pruneInsights(beforeEpoch: pruneEpoch)
        recomputeUsage()
        if insightsShown { recomputeInsights() }
    }

    /// Toggle the activity-insights panel (tapping the summary numbers). Turning it on
    /// aggregates the stored hourly history for the current period; off drops the data.
    func toggleInsights() {
        insightsShown.toggle()
        if insightsShown { recomputeInsights() }
        else { periodInsights = nil }
    }

    /// Aggregate the persisted insight history for the selected period into `periodInsights`.
    /// Reads the store (no transcript walk), so it survives the transcripts being cleared.
    func recomputeInsights(now: Date = Date()) {
        let cal = Calendar.current
        let start: Date, end: Date
        if let day = selectedDay {
            start = cal.startOfDay(for: day)
            end = min(cal.date(byAdding: .day, value: 1, to: start) ?? now, now)
        } else {
            start = usageWindow.range(now: now, cal: cal).start
            end = now
        }
        periodInsights = store.insights(fromEpoch: epoch(start), toEpoch: epoch(end))
    }

    // MARK: - Usage history (chart + delta)

    /// Rebuild `usageBars` and `usageSummary` for the selected window from the history
    /// store: the chart series (bucket-filled), the window token/cost totals, and the
    /// percent delta against the equal-length window immediately before it.
    private func recomputeUsage(now: Date = Date()) {
        let cal = Calendar.current
        // Effective span: a drilled single day (hourly) overrides the multi-day window.
        let start: Date, unit: Calendar.Component, shift: Int, lastDay: Date
        if let day = selectedDay {
            start = cal.startOfDay(for: day)
            unit = .hour
            shift = 1                       // baseline = the day before
            lastDay = start
        } else {
            start = usageWindow.range(now: now, cal: cal).start
            unit = usageWindow.barUnit
            shift = usageWindow.shiftDays
            lastDay = cal.startOfDay(for: now)
        }
        // The axis spans through the end of the last covered day (start of the day after) so
        // the trailing bar sits fully in-plot. Token sums stop at `now`, so a still-running
        // day (today, or today drilled in) compares fairly against the equally partial
        // baseline below; a fully-elapsed past day sums the whole day.
        let dayAfterLast = cal.date(byAdding: .day, value: 1, to: lastDay) ?? now
        let queryEnd = min(dayAfterLast, now)

        // hourlyRows is half-open [from, to); querying to epoch(queryEnd) excludes the next
        // bucket exactly (e.g. tomorrow's 00:00 hour for a drilled past day).
        let curRows = store.hourlyRows(fromEpoch: epoch(start), toEpoch: epoch(queryEnd))
        usageBars = bars(curRows, from: start, to: queryEnd, unit: unit, cal: cal)
        usageDomain = bucketStart(start, unit: unit, cal: cal)...dayAfterLast

        let curTokens = curRows.reduce(0) { $0 + $1.tokens.total }
        let curCost = cost(curRows)

        // Previous equal-length window, shifted back by the window's span.
        let pStart = cal.date(byAdding: .day, value: -shift, to: start) ?? start
        let pEnd = cal.date(byAdding: .day, value: -shift, to: queryEnd) ?? queryEnd
        let prevRows = store.hourlyRows(fromEpoch: epoch(pStart), toEpoch: epoch(pEnd))
        let prevTokens = prevRows.reduce(0) { $0 + $1.tokens.total }
        let baselineCovered = (store.earliestHourEpoch() ?? .max) <= epoch(pStart)
        let delta = Self.deltaPct(cur: curTokens, prev: prevTokens, baselineCovered: baselineCovered)

        usageSummary = UsageSummary(tokens: curTokens, cost: curCost, deltaPct: delta)
    }

    /// "Tokens today" / "Tokens yesterday" / "Tokens 6 Jul" for a drilled day.
    static func dayTitle(_ day: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(day, inSameDayAs: now) { return "Tokens today" }
        if let yst = cal.date(byAdding: .day, value: -1, to: now),
           cal.isDate(day, inSameDayAs: yst) { return "Tokens yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return "Tokens \(f.string(from: day))"
    }

    /// Fractional change of the current window vs. the previous equal-length one, or nil to
    /// hide the delta. We suppress it unless the baseline window is fully covered by recorded
    /// history — otherwise (e.g. a 30-day delta on a fresh install with <60 days of data) the
    /// prior period is truncated and the percentage is meaningless, often thousands of %. Also
    /// nil when the baseline is zero (division would blow up / read as ∞%).
    nonisolated static func deltaPct(cur: Int, prev: Int, baselineCovered: Bool) -> Double? {
        guard baselineCovered, prev > 0 else { return nil }
        return Double(cur - prev) / Double(prev)
    }

    /// Drill the chart into one day's hourly breakdown (from tapping its bar in the 7/30-day
    /// view). An empty-area tap or a window cycle clears it.
    func selectUsageDay(_ day: Date) {
        selectedDay = Calendar.current.startOfDay(for: day)
        recomputeUsage()
        if insightsShown { recomputeInsights() }
    }

    /// Empty-area / header tap. Clears a drill-in first; otherwise advances the window.
    func cycleUsageWindow() {
        if selectedDay != nil {
            selectedDay = nil
            recomputeUsage()
        } else {
            usageWindow = usageWindow.next   // didSet recomputes
        }
        if insightsShown { recomputeInsights() }
    }

    private func epoch(_ d: Date) -> Int { Int(d.timeIntervalSince1970) }

    /// Fold rows into (local bucket, model) segments for a stacked bar chart. Empty buckets
    /// emit nothing — the pinned x-domain (`usageDomain`) keeps the axis contiguous.
    private func bars(
        _ rows: [HourlyRow], from start: Date, to end: Date,
        unit: Calendar.Component, cal: Calendar
    ) -> [UsageBar] {
        var sums: [Date: [String: Int]] = [:]
        for r in rows {
            let d = Date(timeIntervalSince1970: TimeInterval(r.hourEpoch))
            let key = bucketStart(d, unit: unit, cal: cal)
            sums[key, default: [:]][r.model, default: 0] += r.tokens.total
        }
        return sums.flatMap { date, models in
            models.compactMap { $0.value > 0 ? UsageBar(date: date, model: $0.key, tokens: $0.value) : nil }
        }
    }

    private func bucketStart(_ d: Date, unit: Calendar.Component, cal: Calendar) -> Date {
        if unit == .day { return cal.startOfDay(for: d) }
        return cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: d)) ?? d
    }

    /// Equivalent pay-as-you-go API cost of a set of rows, priced per model. `nil` when
    /// prices haven't loaded yet — the UI then omits the cost segment.
    private func cost(_ rows: [HourlyRow]) -> Double? {
        guard !modelPrices.isEmpty else { return nil }
        var sum = 0.0
        for r in rows {
            guard let c = modelPrices[r.model] else { continue }
            sum += (Double(r.tokens.input) * c.input
                  + Double(r.tokens.output) * c.output
                  + Double(r.tokens.cacheCreate) * c.cacheWrite
                  + Double(r.tokens.cacheRead) * c.cacheRead) / 1_000_000
        }
        return sum
    }

    /// Refresh the models.dev price table. Best-effort: on any failure the cached table
    /// (loaded in init) stays in use. Called once per launch from start().
    func refreshPrices() async {
        guard let fresh = try? await PricingClient.fetch(), !fresh.isEmpty else { return }
        modelPrices = fresh
        if let json = try? JSONEncoder().encode(fresh), let s = String(data: json, encoding: .utf8) {
            store.setSetting("modelPrices", s)
        }
        recomputeUsage()   // cost segment can now be priced
    }

    /// Equivalent pay-as-you-go API cost of today's tokens, priced per model from the
    /// models.dev table. `nil` when prices haven't loaded or no per-model breakdown exists
    /// (e.g. a total restored from a pre-pricing build) — the UI then omits the "~$" suffix.
    var costTodayUSD: Double? {
        guard !modelPrices.isEmpty, let byModel = tokensToday?.byModel, !byModel.isEmpty
        else { return nil }
        var sum = 0.0
        for (model, mt) in byModel {
            guard let c = modelPrices[model] else { continue }  // unknown model → skip
            sum += (Double(mt.input) * c.input
                  + Double(mt.output) * c.output
                  + Double(mt.cacheCreate) * c.cacheWrite
                  + Double(mt.cacheRead) * c.cacheRead) / 1_000_000
        }
        return sum
    }

    /// Manual single-account retry — backs the tappable error label so a transient
    /// "fetch failed" can be cleared without refetching every account.
    func retry(email: String) async {
        guard let account = accounts.first(where: { $0.email == email }) else { return }
        retryTasks[email]?.cancel(); retryTasks[email] = nil   // supersede any auto-retry loop
        errorByEmail[email] = nil            // clear so the UI shows "loading…" mid-retry
        await refresh(account)
        autoSwitchIfNeeded()
    }

    /// Snapshot the current usage readings to the Store so they survive a quit/relaunch
    /// (stale-while-revalidate — see the restore in init). Cheap: a handful of accounts.
    private func persistUsage() {
        if let json = try? JSONEncoder().encode(usageByEmail),
           let s = String(data: json, encoding: .utf8) {
            store.setSetting("usageByEmail", s)
        }
    }

    /// Outcome of one usage fetch, so the poll can decide whether to retry the account.
    /// `.retriable` carries the server's suggested wait (nil → caller backs off itself).
    private enum FetchResult { case ok, fatal, retriable(after: TimeInterval?) }

    @discardableResult
    private func refresh(_ account: Account) async -> FetchResult {
        guard let blob = Keychain.storedBlob(email: account.email),
              var creds = OAuthCreds.parse(blob) else {
            errorByEmail[account.email] = "no stored credentials"
            return .fatal
        }

        // Refresh if the token has expired (best-effort; see OAuthClient.refresh).
        if creds.isExpired, let rt = creds.refreshToken {
            if let refreshed = try? await OAuthClient.refresh(refreshToken: rt),
               let newBlob = Self.applyRefresh(to: creds.raw,
                                                accessToken: refreshed.accessToken,
                                                refreshToken: refreshed.refreshToken,
                                                expiresAt: refreshed.expiresAt) {
                try? Keychain.storeBlob(email: account.email, blob: newBlob)
                creds = OAuthCreds.parse(newBlob) ?? creds
                // Deliberately do NOT push this into the live `Claude Code-credentials`
                // entry. That refreshed token is only for our own usage fetch (stored
                // above). Writing the official entry here (a) resets its Keychain ACL,
                // re-prompting `security`/`claude` on every subsequent read, and
                // (b) burns the rotating refresh token out from under Claude Code,
                // which can force a re-login. The live entry is Claude Code's to manage;
                // we only touch it on an explicit user switch (see `switch`/`activate`).
            }
        }

        do {
            let usage = try await OAuthClient.fetchUsage(accessToken: creds.accessToken)
            usageByEmail[account.email] = usage
            errorByEmail[account.email] = nil
            persistUsage()
            return .ok
        } catch OAuthError.unauthorized {
            errorByEmail[account.email] = "needs re-login"
            return .fatal
        } catch let OAuthError.rateLimited(retryAfter) {
            // The one worth retrying quickly — a per-IP burst limit that clears in seconds.
            errorByEmail[account.email] = "Fetch failed (429)"
            return .retriable(after: retryAfter)
        } catch let OAuthError.http(code) {
            errorByEmail[account.email] = "Fetch failed (\(code))"
            return code >= 500 ? .retriable(after: nil) : .fatal   // 5xx is transient; 4xx isn't
        } catch let e as URLError where e.code == .notConnectedToInternet || e.code == .networkConnectionLost {
            errorByEmail[account.email] = "Offline"
            return .fatal                                           // next poll retries once back online
        } catch let e as URLError where e.code == .timedOut {
            errorByEmail[account.email] = "Timed out"
            return .retriable(after: nil)
        } catch {
            errorByEmail[account.email] = "Fetch failed"
            return .fatal
        }
    }

    // MARK: - Switch policy

    /// Auto-switch when the active account is exhausted.
    /// Candidate = a non-exhausted account whose 5h window resets soonest
    /// (use-it-or-lose-it). If every other account is also exhausted, stay put —
    /// switching to an account with no usage left buys nothing.
    func autoSwitchIfNeeded() {
        guard autoSwitchEnabled, let active = activeEmail,
              let activeUsage = usageByEmail[active],
              activeUsage.isExhausted(threshold: threshold) else { return }

        if let target = bestCandidate(excluding: active) {
            switchTo(email: target, reason: "auto: \(active) hit \(Int(threshold))%")
        }
    }

    private func bestCandidate(excluding active: String) -> String? {
        let usable = accounts.filter { acct in
            acct.email != active &&
            !(usageByEmail[acct.email]?.isExhausted(threshold: threshold) ?? true) &&
            errorByEmail[acct.email] == nil
        }
        // Soonest 5h reset first; accounts without a known reset sort last.
        return usable.min { lhs, rhs in
            let l = usageByEmail[lhs.email]?.fiveHourResets ?? .distantFuture
            let r = usageByEmail[rhs.email]?.fiveHourResets ?? .distantFuture
            return l < r
        }?.email
    }

    func switchTo(email: String, reason: String = "manual") {
        do {
            try Keychain.activate(email: email)
            // Token alone leaves `~/.claude.json` pointing at the previous account,
            // so `claude auth status` would still show the old identity. Restore the
            // captured identity block too. Accounts captured before this feature have
            // no stored identity — they just skip the patch until re-captured.
            if let identity = Keychain.storedIdentity(email: email) {
                try? ClaudeConfig.applyIdentityJSON(identity)
            }
            activeEmail = email
            store.setSetting("activeEmail", email)
            statusMessage = "Switched to \(label(for: email)). Applies to new sessions."
        } catch {
            statusMessage = "Switch failed: \(error)"
        }
    }

    // MARK: - Add / capture accounts

    /// Starts the add-account flow: runs `claude auth login` as a subprocess (no
    /// Terminal window), scrapes the sign-in URL it prints, opens that in the default
    /// browser, and then watches the Keychain to auto-capture the new account once
    /// Claude writes it.
    ///
    /// Running the subprocess ourselves — against a *known-good* binary — avoids the
    /// spawned-Terminal shell resolving `claude` to a broken install
    /// ("native binary not installed"). The pasted auth code is fed back via
    /// `submitLoginCode(_:)` → the process's stdin.
    ///
    /// We deliberately let `claude` perform the Keychain write so the credential blob
    /// is in exactly the format Claude Code expects — we never reconstruct it.
    func startAddAccount() {
        guard !isAwaitingLogin else { return }
        guard let binary = ClaudeBinary.resolve() else {
            statusMessage = "Couldn't find a working `claude` binary. Is Claude Code installed?"
            return
        }

        let preToken = OAuthCreds.parse(Keychain.currentOfficialBlob() ?? "")?.accessToken
        let knownTokens = Set(accounts.compactMap { acct in
            Keychain.storedBlob(email: acct.email).flatMap { OAuthCreds.parse($0)?.accessToken }
        })

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["auth", "login"]
        let stdout = Pipe()
        let stdin = Pipe()
        p.standardOutput = stdout
        p.standardError = stdout   // claude may print the URL on either stream
        p.standardInput = stdin

        // Scan the merged output for the "visit: <url>" line and open it once.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            guard let url = Self.extractLoginURL(from: text) else { return }
            Task { @MainActor in self?.presentLoginURL(url) }
        }

        do { try p.run() } catch {
            statusMessage = "Couldn't start `claude auth login`: \(error)"
            return
        }

        loginProcess = p
        loginStdin = stdin.fileHandleForWriting
        loginURL = nil
        isAwaitingLogin = true
        statusMessage = "Opening the sign-in page…"
        watchForNewLogin(preToken: preToken, knownTokens: knownTokens)
    }

    /// Surfaces the sign-in URL in the UI (once). We deliberately do *not* open the
    /// browser here: `claude auth login` opens it itself, so opening again would
    /// spawn a second, duplicate tab. The URL is shown so the user can open it
    /// manually if Claude's auto-open ever fails.
    private func presentLoginURL(_ url: URL) {
        guard loginURL == nil else { return }
        loginURL = url
        statusMessage = "Authorize in your browser — capturing automatically."
    }

    /// Feeds the pasted auth code to the running `claude auth login` process. Claude
    /// then completes the login and writes the credential to the Keychain, which
    /// `watchForNewLogin` picks up and captures.
    func submitLoginCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let stdin = loginStdin else { return }
        stdin.write(Data((trimmed + "\n").utf8))
        statusMessage = "Submitting code…"
    }

    /// Aborts an in-progress `claude auth login`: kills the subprocess, stops the
    /// Keychain watcher, and clears the awaiting state so the UI returns to normal.
    func cancelAddAccount() {
        guard isAwaitingLogin else { return }
        loginWatch?.cancel()
        loginWatch = nil
        isAwaitingLogin = false
        endLoginSession()
        statusMessage = "Sign-in cancelled."
    }

    /// Pulls the sign-in URL out of Claude's "If the browser didn't open, visit: …" line.
    nonisolated static func extractLoginURL(from text: String) -> URL? {
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            if token.hasPrefix("https://"), let url = URL(string: String(token)) { return url }
        }
        return nil
    }

    /// Tears down a login subprocess (on success, timeout, or cancel).
    private func endLoginSession() {
        loginProcess?.standardOutput.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        try? loginStdin?.close()
        if let p = loginProcess, p.isRunning { p.terminate() }
        loginProcess = nil
        loginStdin = nil
        loginURL = nil
    }

    /// Polls the live Keychain entry until it changes to a token we haven't seen,
    /// then auto-captures it. Gives up after a few minutes.
    private func watchForNewLogin(preToken: String?, knownTokens: Set<String>) {
        loginWatch?.cancel()
        loginWatch = Task { [weak self] in
            let deadline = Date().addingTimeInterval(300) // 5 min
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard let blob = Keychain.currentOfficialBlob(),
                      let token = OAuthCreds.parse(blob)?.accessToken else { continue }
                let isNew = token != preToken && !knownTokens.contains(token)
                if isNew {
                    await self.captureCurrentLogin()
                    self.isAwaitingLogin = false
                    self.endLoginSession()
                    return
                }
            }
            self?.finishAwaitingLoginTimeout()
        }
    }

    private func finishAwaitingLoginTimeout() {
        guard isAwaitingLogin else { return }
        isAwaitingLogin = false
        endLoginSession()
        statusMessage = "Didn't detect a new login. If you finished signing in, click Capture current login."
    }

    /// Reads whatever Claude Code is currently logged into and saves it as a managed
    /// account (keyed by its email). Also makes it the active account.
    func captureCurrentLogin() async {
        guard let blob = Keychain.currentOfficialBlob(),
              let creds = OAuthCreds.parse(blob) else {
            statusMessage = "No Claude Code login found in Keychain."
            return
        }
        do {
            let profile = try await OAuthClient.fetchProfile(accessToken: creds.accessToken)
            try Keychain.storeBlob(email: profile.email, blob: blob)
            // Snapshot the identity Claude Code just wrote to `~/.claude.json` so we
            // can restore it on switch (the token blob carries no identity itself).
            if let identity = ClaudeConfig.currentIdentityJSON() {
                try? Keychain.storeIdentity(email: profile.email, json: identity)
            }

            let order = accounts.first(where: { $0.email == profile.email })?.order ?? store.nextOrder()
            let account = Account(email: profile.email, label: profile.displayName,
                                  plan: profile.plan, order: order)
            store.upsertAccount(account)
            accounts = store.listAccounts()
            activeEmail = profile.email
            store.setSetting("activeEmail", profile.email)
            statusMessage = "Login captured: \(profile.email)"
            await refresh(account)
        } catch {
            statusMessage = "Capture failed (couldn't read profile): \(error)"
        }
    }

    func removeAccount(email: String) {
        retryTasks[email]?.cancel(); retryTasks[email] = nil
        loadingEmails.remove(email)
        Keychain.removeStored(email: email)
        store.deleteAccount(email: email)
        accounts = store.listAccounts()
        usageByEmail[email] = nil
        errorByEmail[email] = nil
        persistUsage()   // drop the removed account from the cached snapshot too
        if activeEmail == email { activeEmail = nil }
    }

    /// Aggregate quota across all accounts that currently have usage data.
    var combined: CombinedCapacity {
        let data = accounts.compactMap { usageByEmail[$0.email] }
        return CombinedCapacity(
            usedFiveHour: data.reduce(0) { $0 + $1.fiveHourPct },
            usedSevenDay: data.reduce(0) { $0 + $1.sevenDayPct },
            total: Double(data.count) * 100,
            accountsWithData: data.count
        )
    }

    /// True while an auto-retry loop is still live for this account (see `RetryPolicy`), so
    /// the UI can show "…. Retrying…" and suppress the manual "Click to retry" affordance.
    func isAutoRetrying(email: String) -> Bool { retryTasks[email] != nil }

    /// True while the active account's first fetch is still in flight with no data yet —
    /// the menu bar shows an empty (0%) gauge and pulses it. See `AppDelegate` for the pulse.
    var menuBarIsLoading: Bool {
        if awaitingHelperApproval { return true }
        guard let email = activeEmail else { return false }
        return loadingEmails.contains(email) && usageByEmail[email] == nil
    }

    /// The composed menu-bar presentation (title + gauge on the 5-hour burn, color on the
    /// worst window). Single wiring point — see `MenuBarStyle.presentation`.
    private var menuBarPresentation: MenuBarStyle.Presentation {
        let u = activeEmail.flatMap { usageByEmail[$0] }
        var fiveHour = u?.fiveHourPct
        var sevenDay = u?.sevenDayPct
        var loading = menuBarIsLoading
        // Screenshot stubs: force a fixed usage state regardless of live data. Applied in
        // ascending severity so listing both leaves the icon in the rate-limited state.
        if Mock.menubar70Pct { fiveHour = 70; sevenDay = max(sevenDay ?? 0, 70); loading = false }
        if Mock.menubarRateLimited { fiveHour = 100; sevenDay = 100; loading = false }
        return MenuBarStyle.presentation(fiveHourPct: fiveHour, sevenDayPct: sevenDay,
                                         showUsage: showUsageInMenuBar, stayAwake: shouldStayAwake,
                                         isLoading: loading)
    }

    /// Compact menu-bar label: active account's 5-hour %, or a dash if unknown.
    var menuTitle: String { menuBarPresentation.title }

    /// SF Symbol gauge for the menu-bar icon, keyed on the 5-hour window.
    var usageGaugeSymbol: String { menuBarPresentation.gaugeSymbol }

    /// Minutes until the soonest upcoming reset (either window, any account), but only
    /// when that's within 5 minutes — used as a transient menu-bar hint. nil otherwise.
    /// Uses the same source as `nextReset` so the menu-bar and window agree.
    var soonestResetMinutes: Int? {
        guard let next = nextReset else { return nil }
        return MenuBarStyle.resetCountdownMinutes(secondsUntilReset: next.date.timeIntervalSince(Date()))
    }

    /// Soonest upcoming reset across every account (either window), tagged with the
    /// owning account — for the "Next reset in … (Name)" line under combined capacity.
    var nextReset: (date: Date, account: String)? {
        let now = Date()
        var best: (date: Date, account: String)?
        for acct in accounts {
            guard let u = usageByEmail[acct.email] else { continue }
            for d in [u.fiveHourResets, u.sevenDayResets].compactMap({ $0 }) where d > now {
                if best == nil || d < best!.date { best = (d, acct.label) }
            }
        }
        return best
    }

    /// Soonest upcoming 7-day (weekly) reset across every account, tagged with the owning
    /// account — for the "Weekly reset in … (Name)" tail on the combined footnote.
    var nextWeeklyReset: (date: Date, account: String)? {
        let now = Date()
        var best: (date: Date, account: String)?
        for acct in accounts {
            guard let u = usageByEmail[acct.email], let d = u.sevenDayResets, d > now else { continue }
            if best == nil || d < best!.date { best = (d, acct.label) }
        }
        return best
    }

    /// Menu-bar icon + text color, keyed on the *worst* window so it warns on whichever
    /// limit binds first: orange from 70%, red at 100% (a hard stop from either the 5-hour
    /// or 7-day window), purple while stay-awake is on (overrides usage), nil otherwise.
    /// The title/gauge stay on the 5-hour burn — only the color reflects the 7-day cap.
    var menuIconColor: NSColor? { menuBarPresentation.color }

    func label(for email: String) -> String {
        accounts.first(where: { $0.email == email })?.label ?? email
    }

    // MARK: - Helpers

    /// On launch, figure out which managed account the live entry currently points at,
    /// by matching access tokens.
    ///
    /// We only do this when we have no persisted active account — reading the official
    /// `Claude Code-credentials` item triggers a Keychain access prompt, so on normal
    /// launches (where `activeEmail` was restored from settings) we skip it entirely.
    private func detectActiveFromKeychain() {
        guard activeEmail == nil, !accounts.isEmpty else { return }
        guard let live = Keychain.currentOfficialBlob(),
              let liveCreds = OAuthCreds.parse(live) else { return }
        for account in accounts {
            if let blob = Keychain.storedBlob(email: account.email),
               let c = OAuthCreds.parse(blob),
               c.accessToken == liveCreds.accessToken {
                activeEmail = account.email
                return
            }
        }
    }

    /// Splice refreshed tokens back into the original blob JSON, preserving its shape.
    nonisolated static func applyRefresh(to raw: String, accessToken: String,
                                         refreshToken: String, expiresAt: Date) -> String? {
        guard let data = raw.data(using: .utf8),
              var top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        func patch(_ o: inout [String: Any]) {
            o["accessToken"] = accessToken
            o["refreshToken"] = refreshToken
            o["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000
        }
        if var nested = top["claudeAiOauth"] as? [String: Any] {
            patch(&nested)
            top["claudeAiOauth"] = nested
        } else {
            patch(&top)
        }
        guard let out = try? JSONSerialization.data(withJSONObject: top) else { return nil }
        return String(data: out, encoding: .utf8)
    }
}
