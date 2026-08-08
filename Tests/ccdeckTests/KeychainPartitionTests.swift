import Testing
import Foundation
@testable import ccdeck

/// The partition list is an XML plist, hex-encoded, stored in a Keychain ACL entry's
/// description field. Only the pure encode/decode of that blob is covered here — the
/// surrounding `Keychain.trustSecurityTool()` touches the real login keychain and
/// stays untested.
@Suite("Keychain partition list")
struct KeychainPartitionTests {

    /// Verbatim description string read off the live `Claude Code-credentials` ACL
    /// entry (the one whose authorization is `ACLAuthorizationPartitionID`). Decodes to
    /// `{Partitions: ["apple-tool:"]}`. This is the format that must round-trip: writing
    /// raw XML here yields an entry the Security framework ignores.
    private let liveEntry = """
    3c3f786d6c2076657273696f6e3d22312e302220656e636f64696e673d225554462d38223f3e0a3c21\
    444f435459504520706c697374205055424c494320222d2f2f4170706c652f2f44544420504c495354\
    20312e302f2f454e222022687474703a2f2f7777772e6170706c652e636f6d2f445444732f50726f70\
    657274794c6973742d312e302e647464223e0a3c706c6973742076657273696f6e3d22312e30223e0a\
    3c646963743e0a093c6b65793e506172746974696f6e733c2f6b65793e0a093c61727261793e0a0909\
    3c737472696e673e6170706c652d746f6f6c3a3c2f737472696e673e0a093c2f61727261793e0a3c2f\
    646963743e0a3c2f706c6973743e0a
    """.replacingOccurrences(of: "\n", with: "")

    @Test("Reads the partition list off the live Claude Code entry")
    func decodesLiveEntry() {
        #expect(Keychain.decodePartitions(liveEntry) == ["apple-tool:"])
    }

    @Test("Round-trips through encode")
    func roundTrips() {
        let partitions = ["apple-tool:", "apple:", "teamid:ABCDE12345"]
        #expect(Keychain.decodePartitions(Keychain.encodePartitions(partitions)) == partitions)
    }

    /// Guards the hex hop specifically: a bare XML plist is what a naive implementation
    /// writes, and it must not be mistaken for a valid list.
    @Test("Un-hexed XML is not accepted")
    func rejectsRawXML() {
        let xml = String(decoding: Data(hexEncoded: liveEntry)!, as: UTF8.self)
        #expect(xml.hasPrefix("<?xml"))          // sanity: the fixture really is a plist
        #expect(Keychain.decodePartitions(xml).isEmpty)
    }

    /// A trusted-app ACL entry's description is a plain name, and a fresh item may have
    /// no partition entry at all. Both must read as empty rather than crash.
    @Test("Non-hex or malformed descriptions decode to empty", arguments: [
        nil, "", "Claude Code-credentials", "abc", "zzzz", "6162",
    ] as [String?])
    func decodesJunkAsEmpty(description: String?) {
        #expect(Keychain.decodePartitions(description).isEmpty)
    }

    @Test("A plist without a Partitions key decodes to empty")
    func decodesUnrelatedPlistAsEmpty() {
        let data = try! PropertyListSerialization.data(fromPropertyList: ["Other": ["x"]],
                                                       format: .xml, options: 0)
        #expect(Keychain.decodePartitions(data.hexEncodedString()).isEmpty)
    }

    /// `trustSecurityTool` merges this in. `/usr/bin/security` is an Apple-signed
    /// command-line tool, so `apple-tool:` is both necessary and sufficient — anything
    /// broader widens who can read the token without a prompt.
    @Test("Required partitions are the minimum the security tool needs")
    func requiredPartitions() {
        #expect(Keychain.requiredPartitions == ["apple-tool:"])
    }

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
