/// ITFileTests.swift
///
/// Lightweight regression coverage for the parser. We construct
/// minimal valid IT files in memory so the tests don't depend on
/// any external samples being checked in.

import Testing
import Foundation
@testable import SwiftIT

@Suite("ITFile parser")
struct ITFileTests {

    @Test("Rejects data missing the IMPM magic")
    func rejectsNonImpm() {
        let bogus = Data(count: 256)  // all zeros
        #expect(throws: ITError.self) {
            _ = try ITFile(data: bogus)
        }
    }

    @Test("Reads header fields from a hand-built file")
    func readsHeader() throws {
        var data = Data(count: 0x100)
        // Magic
        data[0] = 0x49; data[1] = 0x4D; data[2] = 0x50; data[3] = 0x4D
        // Song name "Test"
        for (i, byte) in "Test".utf8.enumerated() { data[0x04 + i] = byte }
        // OrdNum = 1, InsNum = 0, SmpNum = 0, PatNum = 0
        data[0x20] = 1; data[0x21] = 0
        // Cwt = 0x0214
        data[0x28] = 0x14; data[0x29] = 0x02
        // Flags = 0x08 (linear slides)
        data[0x2C] = 0x08
        // Speed/tempo
        data[0x32] = 6; data[0x33] = 125
        // Order list at 0xC0 — single entry (255 = end)
        data[0xC0] = 255

        let file = try ITFile(data: data)
        #expect(file.songName == "Test")
        #expect(file.orderCount == 1)
        #expect(file.createdWith == 0x0214)
        #expect(file.usesLinearSlides)
        #expect(file.initialSpeed == 6)
        #expect(file.initialTempo == 125)
    }

    @Test("Empty-pattern parapointer (0) yields a silent pattern")
    func emptyPatternPointer() throws {
        var data = Data(count: 0x100)
        data[0] = 0x49; data[1] = 0x4D; data[2] = 0x50; data[3] = 0x4D
        data[0x20] = 1
        data[0x26] = 1  // PatNum = 1
        // Order list at 0xC0 — one order pointing at pattern 0.
        data[0xC0] = 0
        // Pattern pointer table sits right after the order list +
        // (zero) instrument/sample tables. With OrdNum=1, InsNum=0,
        // SmpNum=0 the pattern pointer lives at 0xC0 + 1 = 0xC1.
        // We leave it zero so the parser drops in an empty pattern.

        let file = try ITFile(data: data)
        #expect(file.patterns.count == 1)
        #expect(file.patterns[0].rowCount > 0)
    }
}
