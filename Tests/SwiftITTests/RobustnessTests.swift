/// RobustnessTests.swift
///
/// Hostile-input coverage: every truncation of a feature-rich fixture,
/// and a deterministic seeded mutation fuzz. The assertion is simply
/// "throws an ITError or parses (and then plays) without trapping".

import Testing
import Foundation
@testable import SwiftIT

typealias M = ITMixerTests

@Suite("Robustness")
struct RobustnessTests {

    /// A module exercising every structure the parser knows about.
    static let fixture: [UInt8] = {
        var compressed = CompressedBlockWriter(is16: false)
        for i in 0..<40 { compressed.delta(i % 7 - 3) }
        compressed.setWidth(5)
        for _ in 0..<10 { compressed.delta(2) }

        var lead = InstrumentSpec()
        lead.nna = 1; lead.dct = 1; lead.dca = 2; lead.fadeOut = 64
        lead.ifc = 0x80 | 90; lead.ifr = 0x80 | 20
        lead.volumeEnvelope = EnvelopeSpec(flags: 0x07, nodes: [(64, 0), (40, 6), (20, 12), (0, 20)], loop: (1, 2), sustain: (0, 1))
        lead.panningEnvelope = EnvelopeSpec(flags: 0x01, nodes: [(-20, 0), (20, 10)])
        lead.pitchEnvelope = EnvelopeSpec(flags: 0x81, nodes: [(0, 0), (-16, 8)])
        var pad = InstrumentSpec()
        pad.sample = 2; pad.nna = 3; pad.fadeOut = 200
        var hit = InstrumentSpec()
        hit.sample = 3; hit.pps = 8

        let p0 = ITBuilder.pattern(rows: 8, [
            M.note(0, 60, ch: 0, ins: 1, vol: 48, fx: "H", 0x44),
            M.note(0, 48, ch: 1, ins: 2, vol: 200, fx: "Z", 0x30),
            M.note(1, 64, ch: 0, ins: 1, vol: nil, fx: "G", 0x20),
            M.note(1, 36, ch: 2, ins: 3, vol: 170, fx: "Q", 0x13),
            M.fx(2, "D", 0x04), M.fx(2, "S", 0xB0, ch: 1),
            M.note(3, 67, ch: 0, ins: 1, vol: 90, fx: "J", 0x37),
            M.fx(3, "S", 0xB1, ch: 1), M.fx(4, "Y", 0x86, ch: 2),
            CellSpec(row: 5, channel: 0, note: 255), M.note(5, 50, ch: 3, ins: 2, fx: "O", 0x01),
            M.fx(6, "T", 0x11), M.fx(6, "W", 0x02, ch: 2),
            CellSpec(row: 7, channel: 1, note: 254), M.fx(7, "B", 1),
        ])
        let p1 = ITBuilder.pattern(rows: 4, [
            M.note(0, 72, ch: 0, ins: 1, fx: "S", 0x73), M.note(1, 72, ch: 0, ins: 1, fx: "S", 0xD1),
            M.fx(2, "C", 0), CellSpec(row: 2, channel: 4, note: 130),
        ])

        var b = ITBuilder()
        b.songName = "fixture"
        b.flags = 0x000D
        b.special = 0x0001
        b.speed = 3
        b.orders = [0, 254, 1, 255]
        b.instruments = [lead.bytes(), pad.bytes(), hit.bytes()]
        b.samples = [
            SampleSpec(name: "saw", flags: 0x01 | 0x10 | 0x20, length: 64, loopBegin: 8, loopEnd: 64,
                       sustainBegin: 0, sustainEnd: 32, vibrato: (4, 8, 16, 0),
                       data: (0..<64).map { UInt8($0 * 4) }),
            SampleSpec(name: "pad", flags: 0x01 | 0x02 | 0x04 | 0x10 | 0x40, cvt: 0x05, length: 16,
                       loopBegin: 2, loopEnd: 16, data: (0..<64).map { UInt8(($0 * 13) & 0xFF) }),
            SampleSpec(name: "cmp", flags: 0x09, cvt: 0x05, length: 50, data: compressed.block),
        ]
        b.patterns = [p0, p1]
        b.message = Array("fixture\rmessage".utf8) + [0]
        return b.build()
    }()

    /// Parse; when it succeeds, also play a little of it.
    static func exercise(_ bytes: [UInt8], frames: Int = 512) {
        do {
            let file = try ITFile(bytes: bytes)
            let mixer = ITMixer(file: file, sampleRate: 22_050)
            var buffer = [Float](repeating: 0, count: frames * 2)
            _ = buffer.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
            #expect(buffer.allSatisfy { $0.isFinite && abs($0) <= 1 })
        } catch {
            #expect(error is ITError)
        }
    }

    @Test("The fixture itself parses and plays to the end")
    func fixtureParses() throws {
        let file = try ITFile(bytes: Self.fixture)
        #expect(file.instruments.count == 3)
        #expect(file.samples.map(\.length) == [64, 16, 50])
        #expect(file.samples.allSatisfy { !$0.isTruncated })
        #expect(file.message == "fixture\nmessage")
        let mixer = ITMixer(file: file, sampleRate: 22_050)
        var buffer = [Float](repeating: 0, count: 4096)
        var total = 0
        for _ in 0..<200 where !mixer.isFinished {
            total += buffer.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
        }
        #expect(mixer.isFinished)
        #expect(total > 0)
    }

    @Test("Truncation at every byte offset throws or parses, never traps")
    func truncationAtEveryOffset() {
        let full = Self.fixture
        for n in 0..<full.count {
            Self.exercise(Array(full.prefix(n)), frames: 64)
        }
    }

    @Test("Seeded random mutations throw or parse, never trap or hang")
    func mutationFuzz() {
        var rng = SplitMix64(seed: 0x5EED_17)
        let base = Self.fixture
        for _ in 0..<3000 {
            var bytes = base
            let edits = 1 + Int(rng.next() % 8)
            for _ in 0..<edits {
                let i = Int(rng.next() % UInt64(bytes.count))
                switch rng.next() % 4 {
                case 0: bytes[i] = UInt8(truncatingIfNeeded: rng.next())
                case 1: bytes[i] ^= 1 << UInt8(rng.next() % 8)
                case 2: bytes[i] = [0x00, 0xFF, 0x7F, 0x80][Int(rng.next() % 4)]
                default:
                    if bytes.count > 1 { bytes.remove(at: i) }
                }
            }
            Self.exercise(bytes, frames: 256)
        }
    }

    @Test("Random garbage after a valid IMPM signature never traps")
    func garbageFuzz() {
        var rng = SplitMix64(seed: 42)
        for _ in 0..<500 {
            let count = 192 + Int(rng.next() % 2048)
            var bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
            bytes.replaceSubrange(0..<4, with: Array("IMPM".utf8))
            // Keep the tables small so pointers have a chance of landing.
            bytes[0x20] = UInt8(rng.next() % 8); bytes[0x21] = 0
            bytes[0x22] = UInt8(rng.next() % 4); bytes[0x23] = 0
            bytes[0x24] = UInt8(rng.next() % 4); bytes[0x25] = 0
            bytes[0x26] = UInt8(rng.next() % 4); bytes[0x27] = 0
            Self.exercise(bytes, frames: 128)
        }
    }
}

/// Small deterministic PRNG for the fuzzers.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
