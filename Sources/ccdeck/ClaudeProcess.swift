import Foundation

/// Whether any Claude Code process is alive right now.
///
/// This gates the one case where ccdeck may refresh the credential it *shares* with
/// Claude Code. Refresh tokens rotate, so an exchange invalidates the token the other
/// holder is carrying — only one process can safely do it. While a session or the
/// background daemon is running, that process is the refresher (its log shows a
/// proactive refresh scheduled hours ahead of expiry) and ccdeck must stay out of the
/// way. But the daemon exits as soon as it goes idle, so a machine left alone over a
/// weekend has no refresher at all and the live token simply dies. That is the gap
/// ccdeck fills — see `AppModel.usableCredentials(for:)`.
///
/// `pgrep -x` matches on executable name, which every entry point shares (the CLI, the
/// agent SDK binary, the daemon). Matching too broadly only costs a skipped renewal,
/// which is the harmless direction; matching too narrowly would let us race a live
/// session, so we also treat "couldn't tell" as running.
enum ClaudeProcess {
    static let pgrep = "/usr/bin/pgrep"
    static let processName = "claude"

    static func isRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pgrep)
        p.arguments = ["-x", processName]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return true }
        p.waitUntilExit()
        return p.terminationStatus == 0   // 0 = at least one match, 1 = none
    }
}
