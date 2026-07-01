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

    // Keep-awake (caffeinate -s equivalent). Not persisted — resets on launch.
    private let stayAwake = StayAwake()
    private let clamshell = ClamshellMonitor()
    private(set) var shouldStayAwake = false

    // Accounts whose first usage fetch is still in flight (including auto-retries) and have
    // no data yet — drives the menu-bar "loading" pulse + 0% gauge. See `RetryPolicy`.
    private(set) var loadingEmails: Set<String> = []
    private var retryTasks: [String: Task<Void, Never>] = [:]

    private let store: Store
    private var timer: Timer?
    private let pollInterval: TimeInterval = 60
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
        self.startAtLoginEnabled = SMAppService.mainApp.status == .enabled
        self.accounts = store.listAccounts()
        self.activeEmail = store.getSetting("activeEmail")
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

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        // First load retries with backoff so a cold-start 429 recovers on its own instead of
        // stranding a "Fetch failed" the user has to click. The 60s poll below stays single-shot.
        for account in accounts { scheduleInitialLoad(account) }
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    /// First-load fetch for one account: retry on a fixed interval up to `RetryPolicy`'s cap,
    /// showing "… — Retrying…" between tries, then leave a bare (tappable) error if it never
    /// succeeds. `loadingEmails` marks it as loading throughout so the menu bar pulses.
    private func scheduleInitialLoad(_ account: Account) {
        let email = account.email
        retryTasks[email]?.cancel()
        retryTasks[email] = Task { @MainActor [weak self] in
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
            try? await Task.sleep(for: .seconds(RetryPolicy.interval))
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
        // Power assertion handles idle sleep instantly, no privileges needed.
        if target {
            stayAwake.start()
            // While awake, power the internal panel off whenever the lid shuts —
            // the system keeps running (disablesleep), only the display sleeps.
            clamshell.onLidClosed = { DisplayControl.sleepNow() }
            clamshell.start()
        } else {
            stayAwake.stop()
            clamshell.stop()
        }
        statusMessage = ""
        // The privileged helper adds lid-close-on-battery suppression via pmset.
        Task {
            do {
                try await HelperManager.shared.setDisableSleep(target)
            } catch HelperError.needsApproval {
                statusMessage = "Approve “CC Deck” in System Settings ▸ Login Items, then toggle again to stay awake with the lid closed."
            } catch {
                statusMessage = "Lid-close keep-awake unavailable (\(error.localizedDescription)). Idle sleep still blocked; keep the lid open."
            }
        }
    }

    /// Fully remove the privileged helper: clear sleep suppression, then
    /// unregister the daemon (drops it from System Settings ▸ Login Items).
    func removeStayAwakeHelper() {
        shouldStayAwake = false
        stayAwake.stop()
        clamshell.stop()
        Task {
            try? await HelperManager.shared.setDisableSleep(false)
            HelperManager.shared.unregister()
            statusMessage = "Keep-awake helper removed."
        }
    }

    // MARK: - Polling

    func refreshAll() async {
        for account in accounts {
            await refresh(account)
        }
        lastRefresh = Date()
        autoSwitchIfNeeded()
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

    private func refresh(_ account: Account) async {
        guard let blob = Keychain.storedBlob(email: account.email),
              var creds = OAuthCreds.parse(blob) else {
            errorByEmail[account.email] = "no stored credentials"
            return
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
                // Keep the live entry fresh too if this is the active account.
                if account.email == activeEmail { try? Keychain.activate(email: account.email) }
            }
        }

        do {
            let usage = try await OAuthClient.fetchUsage(accessToken: creds.accessToken)
            usageByEmail[account.email] = usage
            errorByEmail[account.email] = nil
        } catch OAuthError.unauthorized {
            errorByEmail[account.email] = "needs re-login"
        } catch let OAuthError.http(code) {
            errorByEmail[account.email] = "Fetch failed (\(code))"
        } catch let e as URLError where e.code == .notConnectedToInternet || e.code == .networkConnectionLost {
            errorByEmail[account.email] = "Offline"
        } catch let e as URLError where e.code == .timedOut {
            errorByEmail[account.email] = "Timed out"
        } catch {
            errorByEmail[account.email] = "Fetch failed"
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

    /// Opens the sign-in URL in the default browser (once) and surfaces it in the UI.
    private func presentLoginURL(_ url: URL) {
        guard loginURL == nil else { return }
        loginURL = url
        NSWorkspace.shared.open(url)
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
    /// the UI can show "… — Retrying…" and suppress the manual "Click to retry" affordance.
    func isAutoRetrying(email: String) -> Bool { retryTasks[email] != nil }

    /// True while the active account's first fetch is still in flight with no data yet —
    /// the menu bar shows an empty (0%) gauge and pulses it. See `AppDelegate` for the pulse.
    var menuBarIsLoading: Bool {
        guard let email = activeEmail else { return false }
        return loadingEmails.contains(email) && usageByEmail[email] == nil
    }

    /// The composed menu-bar presentation (title + gauge on the 5-hour burn, color on the
    /// worst window). Single wiring point — see `MenuBarStyle.presentation`.
    private var menuBarPresentation: MenuBarStyle.Presentation {
        let u = activeEmail.flatMap { usageByEmail[$0] }
        return MenuBarStyle.presentation(fiveHourPct: u?.fiveHourPct, sevenDayPct: u?.sevenDayPct,
                                         showUsage: showUsageInMenuBar, stayAwake: shouldStayAwake,
                                         isLoading: menuBarIsLoading)
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
    /// account — for the "Weekly reset in … (Name)" hint under combined capacity.
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
