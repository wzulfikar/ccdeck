import Foundation
import Observation
import AppKit

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
    let threshold: Double = 90

    // Keep-awake (caffeinate -i equivalent). Not persisted — resets on launch.
    private let caffeine = Caffeine()
    private(set) var stayAwake = false

    private let store: Store
    private var timer: Timer?
    private let pollInterval: TimeInterval = 60
    private var loginWatch: Task<Void, Never>?
    private(set) var isAwaitingLogin = false

    init() {
        let store = Store()
        self.store = store
        self.autoSwitchEnabled = store.getSetting("autoSwitch") == "1"
        self.showUsageInMenuBar = store.getSetting("showUsageInMenuBar") != "0"  // default on
        self.accounts = store.listAccounts()
        self.activeEmail = store.getSetting("activeEmail")
        detectActiveFromKeychain()
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        Task { await refreshAll() }
        let t = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func tick() async {
        await refreshAll()
        store.pruneSnapshots(olderThanDays: 35)
    }

    // MARK: - Keep-awake

    func toggleStayAwake() {
        stayAwake = caffeine.toggle()
    }

    // MARK: - Polling

    func refreshAll() async {
        for account in accounts {
            await refresh(account)
        }
        lastRefresh = Date()
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
            store.insertSnapshot(email: account.email, usage: usage)
        } catch OAuthError.unauthorized {
            errorByEmail[account.email] = "needs re-login"
        } catch {
            errorByEmail[account.email] = "fetch failed"
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
            statusMessage = "Switched to \(label(for: email)) — \(reason). New sessions only."
        } catch {
            statusMessage = "Switch failed: \(error)"
        }
    }

    // MARK: - Add / capture accounts

    /// Starts the add-account flow: opens a Terminal running `claude auth login`
    /// (which opens the browser and prompts for the pasted auth code), then watches
    /// the Keychain and auto-captures the new account once Claude writes it.
    ///
    /// We deliberately let `claude` perform the Keychain write so the credential blob
    /// is in exactly the format Claude Code expects — we never reconstruct it.
    func startAddAccount() {
        let preToken = OAuthCreds.parse(Keychain.currentOfficialBlob() ?? "")?.accessToken
        let knownTokens = Set(accounts.compactMap { acct in
            Keychain.storedBlob(email: acct.email).flatMap { OAuthCreds.parse($0)?.accessToken }
        })

        let script = "tell application \"Terminal\"\nactivate\ndo script \"claude auth login\"\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        do { try p.run() } catch {
            statusMessage = "Couldn't open Terminal: \(error)"
            return
        }

        isAwaitingLogin = true
        statusMessage = "Sign in (and paste the code) in Terminal — I'll capture it automatically."
        watchForNewLogin(preToken: preToken, knownTokens: knownTokens)
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
                    return
                }
            }
            self?.finishAwaitingLoginTimeout()
        }
    }

    private func finishAwaitingLoginTimeout() {
        guard isAwaitingLogin else { return }
        isAwaitingLogin = false
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
            statusMessage = "Captured: \(profile.email)"
            await refresh(account)
        } catch {
            statusMessage = "Capture failed (couldn't read profile): \(error)"
        }
    }

    func removeAccount(email: String) {
        Keychain.removeStored(email: email)
        store.deleteAccount(email: email)
        accounts = store.listAccounts()
        usageByEmail[email] = nil
        errorByEmail[email] = nil
        if activeEmail == email { activeEmail = nil }
    }

    // MARK: - Summaries (for the history section)

    func summary(email: String, lastSeconds: TimeInterval) -> UsageSummary {
        store.summary(email: email, lastSeconds: lastSeconds)
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

    /// Compact menu-bar label: active account's worst window %, or a dash if unknown.
    var menuTitle: String {
        guard let email = activeEmail, let u = usageByEmail[email] else { return "—" }
        return "\(Int(max(u.fiveHourPct, u.sevenDayPct)))%"
    }

    /// Minutes until the soonest 5-hour window resets, but only when that's within
    /// 5 minutes — used as a transient menu-bar hint. nil otherwise.
    var soonestResetMinutes: Int? {
        let now = Date()
        let secs = accounts
            .compactMap { usageByEmail[$0.email]?.fiveHourResets?.timeIntervalSince(now) }
            .filter { $0 > 0 && $0 <= 5 * 60 }
            .min()
        guard let secs else { return nil }
        return max(1, Int(ceil(secs / 60)))
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

    /// Menu-bar icon tint, or nil for the default (template white) when usage is safe.
    var menuIconColor: NSColor? {
        let c = combined
        guard c.hasData else { return nil }
        switch c.fiveHourLevel {
        case .full:   return .systemRed
        case .warn:   return .systemOrange
        case .normal: return nil
        }
    }

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
