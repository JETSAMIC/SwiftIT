/// ITDecompress.swift
///
/// IT 2.14 / 2.15 sample decompression — Jeffrey Lim's variable-bit-
/// width codec that ships with Impulse Tracker 2.14 and later.
///
/// Two variants distinguished by the file's `compatibleWith` version:
/// - `cmwt < 0x215` (IT 2.14)  → single-level delta
/// - `cmwt >= 0x215` (IT 2.15) → "delta of delta", an extra cumulative
///   pass after the inner one
///
/// The on-disk layout is a sequence of length-prefixed blocks. Each
/// block decompresses to a fixed number of samples (0x8000 for 8-bit,
/// 0x4000 for 16-bit) except the last, which is whatever's needed to
/// reach the sample's declared length. Inside a block the codec
/// reads a variable number of bits per sample, using a small set of
/// escape codes to bump the read width up or down.
///
/// Reference: ITTECH.TXT plus OpenMPT's `soundlib/ITCompression.cpp`
/// — both decoders agree on the bit-by-bit semantics, including the
/// nasty edge cases at width 6/8/9 (8-bit) and 14/16/17 (16-bit).

import Foundation

enum ITDecompress {

    /// Maximum samples per compressed block, by bit depth.
    static let blockSamples8: Int = 0x8000
    static let blockSamples16: Int = 0x4000

    /// Decompress an 8-bit IT-compressed sample. `is215` toggles the
    /// delta-of-delta cumulative pass that IT 2.15+ wraps around the
    /// inner deltas.
    static func decompress8(
        data: Data,
        offset: Int,
        sampleCount: Int,
        is215: Bool
    ) -> [Float] {
        var output = [Int8](repeating: 0, count: sampleCount)
        var cursor = offset
        var written = 0

        while written < sampleCount && cursor + 2 <= data.count {
            // Length prefix: bytes inside this block, excluding the
            // word itself.
            let blockLen = Int(data.readUInt16LE(at: cursor))
            cursor += 2
            let blockEnd = cursor + blockLen
            if blockEnd > data.count { break }

            let blockTarget = min(blockSamples8, sampleCount - written)
            decompressBlock8(
                data: data,
                blockRange: cursor..<blockEnd,
                output: &output,
                outputBase: written,
                outputCount: blockTarget,
                is215: is215
            )
            written += blockTarget
            cursor = blockEnd
        }

        // Promote Int8 → normalized Float32 mono.
        var pcm = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            pcm[i] = Float(output[i]) / 128.0
        }
        return pcm
    }

    /// Decompress a 16-bit IT-compressed sample. Same general
    /// machinery as the 8-bit path, just with a wider starting
    /// `width` (17 vs 9) and a 16-bit accumulator.
    static func decompress16(
        data: Data,
        offset: Int,
        sampleCount: Int,
        is215: Bool
    ) -> [Float] {
        var output = [Int16](repeating: 0, count: sampleCount)
        var cursor = offset
        var written = 0

        while written < sampleCount && cursor + 2 <= data.count {
            let blockLen = Int(data.readUInt16LE(at: cursor))
            cursor += 2
            let blockEnd = cursor + blockLen
            if blockEnd > data.count { break }

            let blockTarget = min(blockSamples16, sampleCount - written)
            decompressBlock16(
                data: data,
                blockRange: cursor..<blockEnd,
                output: &output,
                outputBase: written,
                outputCount: blockTarget,
                is215: is215
            )
            written += blockTarget
            cursor = blockEnd
        }

        var pcm = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            pcm[i] = Float(output[i]) / 32768.0
        }
        return pcm
    }

    // MARK: - 8-bit block

    private static func decompressBlock8(
        data: Data,
        blockRange: Range<Int>,
        output: inout [Int8],
        outputBase: Int,
        outputCount: Int,
        is215: Bool
    ) {
        var reader = BitReader(data: data, range: blockRange)
        var width = 9
        var accumulator: Int8 = 0
        var carry: Int8 = 0
        var produced = 0

        while produced < outputCount {
            guard let value = reader.read(bits: width) else { break }

            var delta: Int8?

            if width < 7 {
                // Small-width case: the all-but-top-bit-zero,
                // top-bit-one pattern (`1 << (width - 1)`) escapes to
                // "change width by next 3 bits". Otherwise the read
                // bits are a sign-extended delta.
                if value == (1 << (width - 1)) {
                    guard let raw = reader.read(bits: 3) else { break }
                    var newWidth = raw + 1
                    if newWidth >= width { newWidth += 1 }
                    width = newWidth
                    continue
                }
                delta = Int8(truncatingIfNeeded: signExtend(value, bits: width))
            } else if width < 9 {
                // Mid range: a window of 8 codes around the midpoint
                // is reserved for width-change escapes; everything
                // else is a delta.
                let border = (0xFF >> (9 - width)) - 4
                if value > border && value <= border + 8 {
                    var newWidth = value - border
                    if newWidth >= width { newWidth += 1 }
                    width = newWidth
                    continue
                }
                delta = Int8(truncatingIfNeeded: signExtend(value, bits: width))
            } else {
                // width == 9: a leading 1 in the top bit means
                // "set width to (low 8 bits) + 1".
                if (value & 0x100) != 0 {
                    width = (value & 0xFF) + 1
                    continue
                }
                delta = Int8(truncatingIfNeeded: signExtend(value, bits: width))
            }

            guard let d = delta else { break }
            accumulator = accumulator &+ d
            if is215 {
                // IT 2.15 wraps the delta in a second cumulative
                // pass — `carry` holds the running sum.
                carry = carry &+ accumulator
                output[outputBase + produced] = carry
            } else {
                output[outputBase + produced] = accumulator
            }
            produced += 1
        }
    }

    // MARK: - 16-bit block

    private static func decompressBlock16(
        data: Data,
        blockRange: Range<Int>,
        output: inout [Int16],
        outputBase: Int,
        outputCount: Int,
        is215: Bool
    ) {
        var reader = BitReader(data: data, range: blockRange)
        var width = 17
        var accumulator: Int16 = 0
        var carry: Int16 = 0
        var produced = 0

        while produced < outputCount {
            guard let value = reader.read(bits: width) else { break }

            var delta: Int16?

            if width < 7 {
                if value == (1 << (width - 1)) {
                    guard let raw = reader.read(bits: 4) else { break }
                    var newWidth = raw + 1
                    if newWidth >= width { newWidth += 1 }
                    width = newWidth
                    continue
                }
                delta = Int16(truncatingIfNeeded: signExtend(value, bits: width))
            } else if width < 17 {
                let border = (0xFFFF >> (17 - width)) - 8
                if value > border && value <= border + 16 {
                    var newWidth = value - border
                    if newWidth >= width { newWidth += 1 }
                    width = newWidth
                    continue
                }
                delta = Int16(truncatingIfNeeded: signExtend(value, bits: width))
            } else {
                if (value & 0x10000) != 0 {
                    width = (value & 0xFFFF) + 1
                    continue
                }
                delta = Int16(truncatingIfNeeded: signExtend(value, bits: width))
            }

            guard let d = delta else { break }
            accumulator = accumulator &+ d
            if is215 {
                carry = carry &+ accumulator
                output[outputBase + produced] = carry
            } else {
                output[outputBase + produced] = accumulator
            }
            produced += 1
        }
    }

    // MARK: - Bit helpers

    /// Sign-extend `value` from `bits` bits into a regular Int. The
    /// codec emits two's-complement integers with a variable width,
    /// so we have to flip the high bits manually after the read.
    private static func signExtend(_ value: Int, bits: Int) -> Int {
        let signBit = 1 << (bits - 1)
        if (value & signBit) != 0 {
            return value | (~0 << bits)
        }
        return value
    }
}

/// Forward-only LSB-first bit reader. The IT codec packs bits into
/// bytes little-endian (low bit first), so consecutive reads chain
/// naturally without juggling bit order.
private struct BitReader {

    let data: Data
    let upperBound: Int
    var cursor: Int

    /// Buffer of bits we've pulled out of `data` but not yet consumed.
    /// Up to 31 bits live here; we top it off whenever a read would
    /// otherwise underflow.
    private var bitBuffer: UInt64 = 0
    private var bitsAvailable: Int = 0

    init(data: Data, range: Range<Int>) {
        self.data = data
        self.upperBound = range.upperBound
        self.cursor = range.lowerBound
    }

    /// Read up to 32 bits. Returns `nil` when the underlying buffer
    /// is exhausted before we can satisfy the request — the caller
    /// breaks out of its decompression loop.
    mutating func read(bits: Int) -> Int? {
        while bitsAvailable < bits {
            if cursor >= upperBound { return nil }
            bitBuffer |= UInt64(data[cursor]) << bitsAvailable
            cursor += 1
            bitsAvailable += 8
        }
        let mask: UInt64 = (1 << UInt64(bits)) - 1
        let value = Int(bitBuffer & mask)
        bitBuffer >>= UInt64(bits)
        bitsAvailable -= bits
        return value
    }
}
