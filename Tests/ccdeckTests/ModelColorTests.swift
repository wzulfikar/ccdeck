import Testing
import Foundation
@testable import ccdeck

@Suite("ModelColor")
struct ModelColorTests {
    @Test("A name's preferred slot is stable across runs")
    func stableHash() {
        // Hand-rolled FNV-1a, not `hashValue` — seeded hashing would hand the same name a
        // different slot each launch and re-colour a chart on restart.
        #expect(ModelColor.preferredSlot(for: "Opus 5") == ModelColor.preferredSlot(for: "Opus 5"))
        #expect(ModelColor.preferredSlot(for: "Opus 5") != ModelColor.preferredSlot(for: "Sonnet 5"))
        #expect((0..<ModelColor.slots).contains(ModelColor.preferredSlot(for: "Haiku 4.5")))
    }

    @Test("An unclaimed name gets its hashed slot")
    func unclaimed() {
        let name = "Opus 5"
        #expect(ModelColor.claimSlot(for: name, taken: []) == ModelColor.preferredSlot(for: name))
    }

    @Test("A newcomer walks past a taken slot instead of displacing it")
    func collisionWalksForward() {
        let name = "Opus 5"
        let preferred = ModelColor.preferredSlot(for: name)
        let slot = ModelColor.claimSlot(for: name, taken: [preferred])
        #expect(slot == (preferred + 1) % ModelColor.slots)
        // And past a run of them.
        let taken: Set<Int> = [preferred, (preferred + 1) % ModelColor.slots]
        #expect(ModelColor.claimSlot(for: name, taken: taken) == (preferred + 2) % ModelColor.slots)
    }

    @Test("Every model in a realistic set gets a distinct slot")
    func noDuplicatesInAsetOfModels() {
        let names = ["Haiku 4.5", "Opus 4.6", "Opus 4.8", "Opus 5", "Sonnet 4.6", "Sonnet 5",
                     "Opus 4", "Opus 4.1", "Sonnet 4", "Fable 5.1", "Haiku 5"]
        var taken = Set<Int>()
        for name in names.sorted() { taken.insert(ModelColor.claimSlot(for: name, taken: taken)) }
        #expect(taken.count == names.count)
    }

    @Test("A full palette reuses a colour rather than looping forever")
    func fullPalette() {
        let all = Set(0..<ModelColor.slots)
        #expect(ModelColor.claimSlot(for: "Opus 9", taken: all) == ModelColor.preferredSlot(for: "Opus 9"))
    }
}
