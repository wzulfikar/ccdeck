import Foundation

/// Locates a *working* `claude` executable.
///
/// The menu-bar app can't rely on the shell's `PATH`, and a naive lookup can land
/// on a broken install (e.g. a pnpm/bun/asdf shim that prints
/// "claude native binary not installed" the moment it does real work like
/// `auth login`). We therefore prefer the Homebrew cask's native binary, then
/// `/usr/local`, then whatever the user's login shell resolves, then the common
/// version-manager shims as a last resort.
enum ClaudeBinary {
    /// First candidate that exists and is executable, in preference order.
    static func resolve() -> String? {
        for path in candidates() where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func candidates() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths = [
            "/opt/homebrew/bin/claude",   // Homebrew cask (native binary) — most reliable
            "/usr/local/bin/claude",
        ]
        // Whatever the user's own login shell would pick — matches "when I open claude
        // manually it works". Appended after the known-good absolute paths.
        if let shellResolved = loginShellClaude() { paths.append(shellResolved) }
        // Version-manager shims last: these are the usual culprits for the broken
        // "native binary not installed" state.
        paths += ["\(home)/.bun/bin/claude", "\(home)/.asdf/shims/claude"]
        // De-dupe while preserving order.
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// `command -v claude` under a login shell, so it sees the user's real PATH.
    private static func loginShellClaude() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
