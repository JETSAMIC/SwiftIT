/// ITDecompress.swift
///
/// IT 2.14 / 2.15 sample decompression: Jeffrey Lim's variable-bit-width
/// delta codec, introduced with Impulse Tracker 2.14.
///
/// ## Stream layout
///
/// A compressed sample is a sequence of blocks. Each block is a
/// little-endian `UInt16` byte count (not including itself) followed by
/// that many bytes of LSB-first bit-packed data. A block decodes to at
/// most 0x8000 samples (8-bit) or 0x4000 samples (16-bit); the last
/// block covers whatever remains of the header's `Length`. The delta
/// accumulators and the bit width are reset at the start of every block.
///
/// ## Variants
///
/// The sample's `Cvt` bit 2 selects the variant (this is what Impulse
/// Tracker, OpenMPT, and Schism Tracker key on; the header's `Cmwt` is
/// *not* consulted):
/// - IT 2.14: one integration pass (`out = d1`)
/// - IT 2.15: two passes (`out = d2`, where `d2 += d1`)
///
/// ## Bit-width escapes (W = 9 for 8-bit, 17 for 16-bit)
///
/// - width 1...6: the value `1 << (width - 1)` is an escape; the next
///   3 (8-bit) or 4 (16-bit) bits plus one give the new width, bumped
///   by one if it is >= the current width.
/// - width 7...W-1: values in `(border, border + N]` with
///   `border = (2^(W-1) - 1) >> (W - width) - N/2` (N = 8 or 16) are
///   escapes; `value - border` is the new width, bumped likewise.
/// - width W: a set top bit means "new width = (value + 1) & 0xFF".
///   Anything outside 1...W is corrupt; decoding stops.
///
/// Every other value is a delta, sign-extended from `width` bits.
///
/// ## Robustness
///
/// The decoder never trusts the header length for allocation: output
/// grows only as bits are consumed (at least one bit per sample), so a
/// tiny file cannot make it allocate gigabytes. A block that runs out of
/// bits, a block header past end of file, or an illegal width stops
/// decoding and reports the result as incomplete.

import Foundation

enum ITDecompress {

    /// Samples per block for 8-bit data.
    static let blockSamples8 = 0x8000
    /// Samples per block for 16-bit data.
    static let blockSamples16 = 0x4000

    /// Output of a decode.
    struct Result: Equatable {
        /// Decoded samples. 8-bit data is scaled into the 16-bit range
        /// (`value << 8`).
        var samples: [Int16]
        /// Byte offset just past the last block that was read. For
        /// stereo samples the right channel's stream starts here.
        var endOffset: Int
        /// `false` when the stream ended before `length` samples were
        /// produced.
        var isComplete: Bool
    }

    /// Decode one channel of an IT-compressed sample.
    ///
    /// - Parameters:
    ///   - bytes: The whole file.
    ///   - offset: Offset of the first block header.
    ///   - length: Number of samples the header declares.
    ///   - is16Bit: Decode 16-bit (width 17) rather than 8-bit (width 9).
    ///   - it215: Apply the IT 2.15 second integration pass.
    static func decompress(
        bytes: [UInt8],
        offset: Int,
        length: Int,
        is16Bit: Bool,
        it215: Bool
    ) -> Result {
        let blockSize = is16Bit ? blockSamples16 : blockSamples8
        let topWidth = is16Bit ? 17 : 9
        let escapeBits = is16Bit ? 4 : 3
        let borderMask = is16Bit ? 0xFFFF : 0xFF
        let borderHalf = is16Bit ? 8 : 4
        let sampleBits = is16Bit ? 16 : 8

        var out: [Int16] = []
        let available = offset >= 0 && offset < bytes.count ? bytes.count - offset : 0
        // At least one bit per decoded sample, so 8 samples per byte
        // is a hard upper bound on what the input can produce.
        out.reserveCapacity(Swift.max(0, Swift.min(length, available.multipliedReportingOverflow(by: 8).partialValue)))

        var cursor = offset
        var complete = true

        decoding: while out.count < length {
            guard bytes.contains(offset: cursor, length: 2) else { complete = false; break }
            let blockLength = Int(bytes.u16(cursor))
            cursor += 2
            guard bytes.contains(offset: cursor, length: blockLength) else {
                complete = false
                break
            }
            var reader = BitReader(bytes: bytes, start: cursor, end: cursor + blockLength)
            cursor += blockLength

            let target = Swift.min(blockSize, length - out.count)
            var width = topWidth
            var d1 = 0
            var d2 = 0
            var produced = 0

            while produced < target {
                guard let value = reader.read(width) else { complete = false; break decoding }

                if width < 7 {
                    if value == 1 << (width - 1) {
                        guard let raw = reader.read(escapeBits) else { complete = false; break decoding }
                        let newWidth = raw + 1
                        width = newWidth < width ? newWidth : newWidth + 1
                        continue
                    }
                } else if width < topWidth {
                    let border = (borderMask >> (topWidth - width)) - borderHalf
                    if value > border && value <= border + 2 * borderHalf {
                        let newWidth = value - border
                        width = newWidth < width ? newWidth : newWidth + 1
                        continue
                    }
                } else if value & (1 << (topWidth - 1)) != 0 {
                    width = (value + 1) & 0xFF
                    guard width >= 1 && width <= topWidth else { complete = false; break decoding }
                    continue
                }

                // Sign-extend the delta from `width` bits.
                let delta: Int
                if width < sampleBits {
                    let shift = Int.bitWidth - width
                    delta = (value << shift) >> shift
                } else {
                    delta = is16Bit ? Int(Int16(truncatingIfNeeded: value))
                                    : Int(Int8(truncatingIfNeeded: value))
                }

                if is16Bit {
                    d1 = Int(Int16(truncatingIfNeeded: d1 &+ delta))
                    d2 = Int(Int16(truncatingIfNeeded: d2 &+ d1))
                    out.append(Int16(truncatingIfNeeded: it215 ? d2 : d1))
                } else {
                    d1 = Int(Int8(truncatingIfNeeded: d1 &+ delta))
                    d2 = Int(Int8(truncatingIfNeeded: d2 &+ d1))
                    out.append(Int16(truncatingIfNeeded: it215 ? d2 : d1) << 8)
                }
                produced += 1
            }
        }

        return Result(samples: out, endOffset: cursor, isComplete: complete && out.count == length)
    }
}

/// Forward-only LSB-first bit reader over one block.
struct BitReader {
    private let bytes: [UInt8]
    private let end: Int
    private var cursor: Int
    private var buffer: UInt64 = 0
    private var available = 0

    init(bytes: [UInt8], start: Int, end: Int) {
        self.bytes = bytes
        self.cursor = start
        self.end = end
    }

    /// Read `count` bits (1...32), first bit in the least significant
    /// position. Returns `nil` when the block is exhausted.
    mutating func read(_ count: Int) -> Int? {
        guard count >= 1 && count <= 32 else { return nil }
        while available < count {
            guard cursor < end else { return nil }
            buffer |= UInt64(bytes[cursor]) << UInt64(available)
            cursor += 1
            available += 8
        }
        let value = Int(buffer & ((1 << UInt64(count)) - 1))
        buffer >>= UInt64(count)
        available -= count
        return value
    }
}
