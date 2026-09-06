import Testing
import Foundation
@testable import ccdeck

/// `Keychain.SecurityTool` exists to keep the live `Claude Code-credentials` entry's
/// **partition list** intact — the thing every in-process write silently rewrites, and
/// the reason a switch used to leave every open `claude` session prompting.
///
/// The round-trip test below touches the real login keychain, but only through a
/// scratch service name of its own, and deletes it again. It skips rather than fails
/// when the keychain is unavailable (locked, or a headless CI runner).
@Suite("Keychain security tool")
struct KeychainSecurityToolTests {

    private static let service = "ccdeck-test-\(UUID().uuidString)"
    private static let account = "roundtrip"

    @Test("Round-trips a value through /usr/bin/security")
    func roundTrips() throws {
        let value = #"{"claudeAiOauth":{"accessToken":"tok en\"quoted\"","x":1}}"#
        try Keychain.SecurityTool.write(service: Self.service,
                                        account: Self.account,
                                        value: value)
        defer { Keychain.delete(service: Self.service, account: Self.account) }
        #expect(try Keychain.SecurityTool.read(service: Self.service, account: Self.account) == value)
    }

    /// The real blob is ~2KB and grows with every MCP server the user authorises, which
    /// is what broke the first version of this: it fed the command to `security -i`,
    /// whose ~4KB line buffer split the hex and ran the tail as a command. Anything
    /// comfortably past that boundary pins the regression.
    @Test("Round-trips a blob far larger than security -i's line buffer")
    func roundTripsLargeBlob() throws {
        let service = "ccdeck-test-large-\(UUID().uuidString)"
        let servers = (0..<200).map { #""server\#($0)":{"accessToken":"tok-\#($0)"}"# }
        let value = #"{"mcpOAuth":{"# + servers.joined(separator: ",") + "}}"
        #expect(value.count > 4096)
        try Keychain.SecurityTool.write(service: service, account: Self.account, value: value)
        defer { Keychain.delete(service: service, account: Self.account) }
        #expect(try Keychain.SecurityTool.read(service: service, account: Self.account) == value)
    }

    /// A missing item must read as nil, not as an empty string — `activate` treats nil
    /// as "no live login" and an empty blob would parse as a corrupt one.
    @Test("A missing item reads as nil")
    func missingIsNil() throws {
        #expect(try Keychain.SecurityTool.read(service: "ccdeck-absent-\(UUID().uuidString)",
                                               account: "nobody") == nil)
    }

    // MARK: - Hex

    /// The secret reaches `security` as hex via `-X`, so it never lands in `ps` output.

    @Test("Hex round-trips arbitrary bytes")
    func hexRoundTrip() {
        let data = Data((0...255).map(UInt8.init))
        #expect(Data(hexEncoded: data.hexEncodedString()) == data)
    }

    @Test("Odd-length and non-hex strings decode to nil", arguments: ["abc", "gg", "1g"])
    func hexRejectsJunk(input: String) {
        #expect(Data(hexEncoded: input) == nil)
    }
}
