/// ITBuilder.swift
///
/// Hand-assembles Impulse Tracker files byte by byte, following the
/// layout in Reference/IT-Format.md, so tests never depend on external
/// module files.

import Foundation
@testable import SwiftIT

struct SampleSpec {
    var name = "smp"
    var flags: UInt8 = 0x01            // has data, 8-bit, mono
    var cvt: UInt8 = 0x01              // signed
    var volume: UInt8 = 64
    var globalVolume: UInt8 = 64
    var defaultPan: UInt8 = 0
    var length: UInt32 = 0
    var loopBegin: UInt32 = 0
    var loopEnd: UInt32 = 0
    var c5Speed: UInt32 = 8363
    var sustainBegin: UInt32 = 0
    var sustainEnd: UInt32 = 0
    var vibrato: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    var data: [UInt8] = []
    /// When set, written verbatim as the 80-byte header (magic and all).
    var rawHeaderOverride: [UInt8]? = nil
}

struct EnvelopeSpec {
    var flags: UInt8 = 0
    var nodes: [(Int8, UInt16)] = []
    var loop: (UInt8, UInt8) = (0, 0)
    var sustain: (UInt8, UInt8) = (0, 0)
}

struct InstrumentSpec {
    var name = "ins"
    var nna: UInt8 = 0
    var dct: UInt8 = 0
    var dca: UInt8 = 0
    var fadeOut: UInt16 = 0
    var pps: Int8 = 0
    var ppc: UInt8 = 60
    var globalVolume: UInt8 = 128
    var defaultPan: UInt8 = 0x80        // bit 7 set = don't use
    var ifc: UInt8 = 0
    var ifr: UInt8 = 0
    var sample: UInt8 = 1               // every key maps to this sample
    var volumeEnvelope = EnvelopeSpec()
    var panningEnvelope = EnvelopeSpec()
    var pitchEnvelope = EnvelopeSpec()

    func bytes() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 554)
        b.replaceSubrange(0..<4, with: Array("IMPI".utf8))
        b[0x11] = nna; b[0x12] = dct; b[0x13] = dca
        b[0x14] = UInt8(fadeOut & 0xFF); b[0x15] = UInt8(fadeOut >> 8)
        b[0x16] = UInt8(bitPattern: pps); b[0x17] = ppc
        b[0x18] = globalVolume; b[0x19] = defaultPan
        for (i, c) in name.utf8.prefix(26).enumerated() { b[0x20 + i] = c }
        b[0x3A] = ifc; b[0x3B] = ifr
        for k in 0..<120 { b[0x40 + k * 2] = UInt8(k); b[0x41 + k * 2] = sample }
        func env(_ e: EnvelopeSpec, at base: Int) {
            b[base] = e.flags; b[base + 1] = UInt8(e.nodes.count)
            b[base + 2] = e.loop.0; b[base + 3] = e.loop.1
            b[base + 4] = e.sustain.0; b[base + 5] = e.sustain.1
            for (i, n) in e.nodes.prefix(25).enumerated() {
                b[base + 6 + i * 3] = UInt8(bitPattern: n.0)
                b[base + 7 + i * 3] = UInt8(n.1 & 0xFF)
                b[base + 8 + i * 3] = UInt8(n.1 >> 8)
            }
        }
        env(volumeEnvelope, at: 0x130)
        env(panningEnvelope, at: 0x182)
        env(pitchEnvelope, at: 0x1D4)
        return b
    }
}

/// One cell for `ITBuilder.pattern`.
struct CellSpec {
    var row: Int
    var channel: Int
    var note: UInt8? = nil
    var instrument: UInt8? = nil
    var volume: UInt8? = nil
    var effect: UInt8? = nil      // 1 = A
    var param: UInt8 = 0
}

struct ITBuilder {
    var songName = "Test"
    var flags: UInt16 = 0x0009            // stereo + linear slides, sample mode
    var special: UInt16 = 0
    var cwt: UInt16 = 0x0214
    var cmwt: UInt16 = 0x0214
    var globalVolume: UInt8 = 128
    var mixVolume: UInt8 = 128
    var speed: UInt8 = 6
    var tempo: UInt8 = 125
    var separation: UInt8 = 128
    var channelPan = [UInt8](repeating: 32, count: 64)
    var channelVolume = [UInt8](repeating: 64, count: 64)
    var orders: [UInt8] = [0, 255]
    var instruments: [[UInt8]?] = []      // raw 554-byte blocks; nil = zero pointer
    var samples: [SampleSpec?] = []
    var patterns: [[UInt8]?] = []         // raw pattern incl. 8-byte header; nil = zero pointer
    var message: [UInt8]? = nil
    var trailer: [UInt8] = []             // bytes placed right after the pointer tables

    /// Pack cells into an IT pattern (8-byte header + packed stream),
    /// always writing an explicit mask byte.
    static func pattern(rows: Int, _ cells: [CellSpec]) -> [UInt8] {
        var data: [UInt8] = []
        for r in 0..<rows {
            for c in cells where c.row == r {
                var mask: UInt8 = 0
                if c.note != nil { mask |= 1 }
                if c.instrument != nil { mask |= 2 }
                if c.volume != nil { mask |= 4 }
                if c.effect != nil { mask |= 8 }
                data.append(UInt8(c.channel + 1) | 0x80)
                data.append(mask)
                if let n = c.note { data.append(n) }
                if let i = c.instrument { data.append(i) }
                if let v = c.volume { data.append(v) }
                if let e = c.effect { data.append(e); data.append(c.param) }
            }
            data.append(0)
        }
        return rawPattern(rows: rows, data)
    }

    static func rawPattern(rows: Int, _ packed: [UInt8]) -> [UInt8] {
        [UInt8(packed.count & 0xFF), UInt8(packed.count >> 8), UInt8(rows & 0xFF), UInt8(rows >> 8), 0, 0, 0, 0] + packed
    }

    func build() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 0xC0)
        out.replaceSubrange(0..<4, with: Array("IMPM".utf8))
        for (i, c) in songName.utf8.prefix(26).enumerated() { out[4 + i] = c }
        func put16(_ v: UInt16, _ o: Int) { out[o] = UInt8(v & 0xFF); out[o + 1] = UInt8(v >> 8) }
        func put32(_ v: UInt32, _ o: Int) {
            out[o] = UInt8(v & 0xFF); out[o + 1] = UInt8((v >> 8) & 0xFF)
            out[o + 2] = UInt8((v >> 16) & 0xFF); out[o + 3] = UInt8(v >> 24)
        }
        put16(UInt16(orders.count), 0x20)
        put16(UInt16(instruments.count), 0x22)
        put16(UInt16(samples.count), 0x24)
        put16(UInt16(patterns.count), 0x26)
        put16(cwt, 0x28); put16(cmwt, 0x2A); put16(flags, 0x2C); put16(special, 0x2E)
        out[0x30] = globalVolume; out[0x31] = mixVolume; out[0x32] = speed; out[0x33] = tempo
        out[0x34] = separation
        for i in 0..<64 { out[0x40 + i] = channelPan[i]; out[0x80 + i] = channelVolume[i] }
        out += orders
        let insTable = out.count
        out += [UInt8](repeating: 0, count: instruments.count * 4)
        let smpTable = out.count
        out += [UInt8](repeating: 0, count: samples.count * 4)
        let patTable = out.count
        out += [UInt8](repeating: 0, count: patterns.count * 4)
        out += trailer

        for (i, ins) in instruments.enumerated() {
            guard let ins else { continue }
            put32(UInt32(out.count), insTable + i * 4)
            out += ins
        }
        var sampleHeaderOffsets: [Int] = []
        for (i, s) in samples.enumerated() {
            guard let s else { sampleHeaderOffsets.append(-1); continue }
            put32(UInt32(out.count), smpTable + i * 4)
            sampleHeaderOffsets.append(out.count)
            out += s.rawHeaderOverride ?? [UInt8](repeating: 0, count: 80)
        }
        for (i, p) in patterns.enumerated() {
            guard let p else { continue }
            put32(UInt32(out.count), patTable + i * 4)
            out += p
        }
        for (i, s) in samples.enumerated() {
            guard let s, s.rawHeaderOverride == nil else { continue }
            let h = sampleHeaderOffsets[i]
            out.replaceSubrange(h..<h + 4, with: Array("IMPS".utf8))
            out[h + 0x11] = s.globalVolume
            out[h + 0x12] = s.flags
            out[h + 0x13] = s.volume
            for (j, c) in s.name.utf8.prefix(26).enumerated() { out[h + 0x14 + j] = c }
            out[h + 0x2E] = s.cvt
            out[h + 0x2F] = s.defaultPan
            put32(s.length, h + 0x30); put32(s.loopBegin, h + 0x34); put32(s.loopEnd, h + 0x38)
            put32(s.c5Speed, h + 0x3C); put32(s.sustainBegin, h + 0x40); put32(s.sustainEnd, h + 0x44)
            put32(UInt32(out.count), h + 0x48)
            out[h + 0x4C] = s.vibrato.0; out[h + 0x4D] = s.vibrato.1
            out[h + 0x4E] = s.vibrato.2; out[h + 0x4F] = s.vibrato.3
            out += s.data
        }
        if let message {
            put16(UInt16(message.count), 0x36)
            put32(UInt32(out.count), 0x38)
            out += message
        }
        return out
    }
}

/// LSB-first bit writer used to hand-encode IT-compressed streams.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var bit = 0

    mutating func write(_ value: Int, _ count: Int) {
        for i in 0..<count {
            if bit == 0 { bytes.append(0) }
            if (value >> i) & 1 != 0 { bytes[bytes.count - 1] |= UInt8(1 << bit) }
            bit = (bit + 1) & 7
        }
    }
}

/// Test encoder for one IT-compressed block. Supports explicit width
/// changes so every escape method can be exercised.
struct CompressedBlockWriter {
    let is16: Bool
    private(set) var width: Int
    var writer = BitWriter()

    init(is16: Bool) {
        self.is16 = is16
        self.width = is16 ? 17 : 9
    }

    var top: Int { is16 ? 17 : 9 }

    /// Emit an escape that switches the decoder to `target`.
    mutating func setWidth(_ target: Int) {
        precondition(target != width && target >= 1 && target <= top)
        if width < 7 {
            writer.write(1 << (width - 1), width)
            writer.write(target < width ? target - 1 : target - 2, is16 ? 4 : 3)
        } else if width < top {
            let border = ((is16 ? 0xFFFF : 0xFF) >> (top - width)) - (is16 ? 8 : 4)
            writer.write(border + (target < width ? target : target - 1), width)
        } else {
            writer.write((1 << (top - 1)) | (target - 1), top)
        }
        width = target
    }

    /// Emit one delta at the current width (caller avoids escape codes).
    mutating func delta(_ d: Int) {
        let bits = width == top ? top - 1 : width
        writer.write(d & ((1 << bits) - 1), width)
    }

    /// The block with its 2-byte length prefix.
    var block: [UInt8] {
        let b = writer.bytes
        return [UInt8(b.count & 0xFF), UInt8(b.count >> 8)] + b
    }
}

extension ITMixer {
    /// Run `n` ticks without rendering audio.
    func runTicks(_ n: Int) {
        for _ in 0..<n where !isFinished { processTick() }
    }
}
