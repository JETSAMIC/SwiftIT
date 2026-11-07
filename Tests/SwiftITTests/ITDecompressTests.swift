/// ITDecompressTests.swift
///
/// The IT 2.14 / 2.15 codec, driven by streams hand-encoded with the
/// test BitWriter so every width-change method, both variants, block
/// boundaries, and corrupt streams are covered.

import Testing
import Foundation
@testable import SwiftIT

@Suite("ITDecompress")
struct ITDecompressTests {

    /// Integrate deltas the way the decoder should (per block).
    static func integrate(_ deltas: [Int], it215: Bool, is16: Bool) -> [Int16] {
        var d1 = 0, d2 = 0
        return deltas.map { d in
            if is16 {
                d1 = Int(Int16(truncatingIfNeeded: d1 + d))
                d2 = Int(Int16(truncatingIfNeeded: d2 + d1))
                return Int16(truncatingIfNeeded: it215 ? d2 : d1)
            } else {
                d1 = Int(Int8(truncatingIfNeeded: d1 + d))
                d2 = Int(Int8(truncatingIfNeeded: d2 + d1))
                return Int16(truncatingIfNeeded: it215 ? d2 : d1) << 8
            }
        }
    }

    /// An 8-bit block that walks through all three escape methods:
    /// 9 -> 4 (method 3), 4 -> 7 (method 1), 7 -> 3 (method 2),
    /// 3 -> 8 (method 1), 8 -> 9 (method 2).
    static func eightBitBlock() -> (block: [UInt8], deltas: [Int]) {
        var w = CompressedBlockWriter(is16: false)
        var deltas: [Int] = []
        func emit(_ ds: [Int]) { for d in ds { w.delta(d); deltas.append(d) } }
        emit([100, -100, 127, -128, 5])          // width 9
        w.setWidth(4); emit([7, -7, 3, 0])       // -8 would be the escape
        w.setWidth(7); emit([59, -60, 10])
        w.setWidth(3); emit([3, -3, 1])
        w.setWidth(8); emit([120, -120, 0])
        w.setWidth(9); emit([1, 2, 3])
        return (w.block, deltas)
    }

    @Test("8-bit IT 2.14 stream with every width-change method")
    func eightBit214() {
        let (block, deltas) = Self.eightBitBlock()
        let r = ITDecompress.decompress(bytes: block, offset: 0, length: deltas.count, is16Bit: false, it215: false)
        #expect(r.isComplete)
        #expect(r.samples == Self.integrate(deltas, it215: false, is16: false))
        #expect(r.endOffset == block.count)
    }

    @Test("8-bit IT 2.15 adds the second integration pass")
    func eightBit215() {
        let (block, deltas) = Self.eightBitBlock()
        let r = ITDecompress.decompress(bytes: block, offset: 0, length: deltas.count, is16Bit: false, it215: true)
        #expect(r.samples == Self.integrate(deltas, it215: true, is16: false))
    }

    @Test("16-bit stream with every width-change method, both variants")
    func sixteenBit() {
        var w = CompressedBlockWriter(is16: true)
        var deltas: [Int] = []
        func emit(_ ds: [Int]) { for d in ds { w.delta(d); deltas.append(d) } }
        emit([30000, -30000, 32767, -32768])     // width 17
        w.setWidth(5); emit([15, -15, 1])        // method 3
        w.setWidth(12); emit([2000, -2000])      // method 1
        w.setWidth(2); emit([1, -1])             // method 2
        w.setWidth(16); emit([20000, -20000])    // method 1
        w.setWidth(17); emit([7])                // method 2
        for it215 in [false, true] {
            let r = ITDecompress.decompress(bytes: w.block, offset: 0, length: deltas.count, is16Bit: true, it215: it215)
            #expect(r.isComplete)
            #expect(r.samples == Self.integrate(deltas, it215: it215, is16: true))
        }
    }

    @Test("Accumulators and width reset at each 0x8000-sample block boundary")
    func blockBoundary() {
        var first = CompressedBlockWriter(is16: false)
        for _ in 0..<ITDecompress.blockSamples8 { first.delta(1) }
        var second = CompressedBlockWriter(is16: false)
        for _ in 0..<10 { second.delta(2) }
        let stream = first.block + second.block
        let total = ITDecompress.blockSamples8 + 10
        let r = ITDecompress.decompress(bytes: stream, offset: 0, length: total, is16Bit: false, it215: false)
        #expect(r.isComplete)
        #expect(r.samples.count == total)
        // Block 1 counts 1, 2, ..., wrapping at 8 bits.
        #expect(r.samples[127] == Int16(Int8(truncatingIfNeeded: 128)) << 8)
        // Block 2 restarts from zero: 2, 4, 6, ...
        #expect(r.samples[ITDecompress.blockSamples8] == 2 << 8)
        #expect(r.samples[total - 1] == 20 << 8)
    }

    @Test("A block that runs out of bits stops decoding and reports incomplete")
    func truncatedBlock() {
        var w = CompressedBlockWriter(is16: false)
        for _ in 0..<8 { w.delta(1) }
        let r = ITDecompress.decompress(bytes: w.block, offset: 0, length: 100, is16Bit: false, it215: false)
        #expect(!r.isComplete)
        #expect(r.samples.count == 8)
    }

    @Test("A block header claiming more bytes than the file holds is rejected")
    func blockPastEOF() {
        let data: [UInt8] = [0x10, 0x00, 0xFF, 0xFF]
        let r = ITDecompress.decompress(bytes: data, offset: 0, length: 256, is16Bit: false, it215: false)
        #expect(!r.isComplete)
        #expect(r.samples.isEmpty)
    }

    @Test("An illegal width (0 or > 9) stops decoding")
    func illegalWidth() {
        var bw = BitWriter()
        bw.write(0x1FF, 9)   // width = (0x1FF + 1) & 0xFF = 0
        bw.write(0, 16)
        let block = [UInt8(bw.bytes.count), 0] + bw.bytes
        let r = ITDecompress.decompress(bytes: block, offset: 0, length: 4, is16Bit: false, it215: false)
        #expect(!r.isComplete)
        #expect(r.samples.isEmpty)
    }

    @Test("Empty input and out-of-range offsets return nothing")
    func emptyInput() {
        for offset in [-5, 0, 3, Int.max] {
            let r = ITDecompress.decompress(bytes: [], offset: offset, length: 32, is16Bit: false, it215: false)
            #expect(r.samples.isEmpty)
            #expect(!r.isComplete)
        }
    }

    @Test("A huge declared length cannot force a huge allocation")
    func hugeLength() {
        var w = CompressedBlockWriter(is16: true)
        w.delta(1)
        let r = ITDecompress.decompress(bytes: w.block, offset: 0, length: Int(UInt32.max), is16Bit: true, it215: false)
        #expect(r.samples.count == 1)
        #expect(!r.isComplete)
    }
}
