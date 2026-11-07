/// ITSample.swift
///
/// `IMPS` sample headers (80 bytes) and sample PCM decoding.

import Foundation

/// One sample slot of an Impulse Tracker module: the 80-byte `IMPS`
/// header plus its decoded PCM.
///
/// PCM is always delivered as signed 16-bit integers. 8-bit sources are
/// scaled by 256 so both depths share one range. Stereo samples keep
/// both channels (``pcm`` is the left channel, ``pcmRight`` the right).
public struct ITSample: Sendable, Equatable {

    /// The `Flg` byte of the sample header.
    public struct Flags: OptionSet, Sendable, Hashable {
        /// The raw `Flg` byte.
        public let rawValue: UInt8
        /// Creates a flag set from the raw `Flg` byte.
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// Bit 0: a sample is associated with this header.
        public static let hasData = Flags(rawValue: 0x01)
        /// Bit 1: 16-bit sample (otherwise 8-bit).
        public static let is16Bit = Flags(rawValue: 0x02)
        /// Bit 2: stereo sample (left channel stored before right).
        public static let isStereo = Flags(rawValue: 0x04)
        /// Bit 3: IT 2.14 / 2.15 compressed sample.
        public static let isCompressed = Flags(rawValue: 0x08)
        /// Bit 4: loop enabled.
        public static let loop = Flags(rawValue: 0x10)
        /// Bit 5: sustain loop enabled.
        public static let sustainLoop = Flags(rawValue: 0x20)
        /// Bit 6: ping-pong (bidirectional) loop.
        public static let pingPongLoop = Flags(rawValue: 0x40)
        /// Bit 7: ping-pong sustain loop.
        public static let pingPongSustainLoop = Flags(rawValue: 0x80)
    }

    /// The `Cvt` (conversion) byte of the sample header.
    public struct Conversion: OptionSet, Sendable, Hashable {
        /// The raw `Cvt` byte.
        public let rawValue: UInt8
        /// Creates a conversion set from the raw `Cvt` byte.
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// Bit 0: samples are signed (otherwise unsigned).
        public static let signed = Conversion(rawValue: 0x01)
        /// Bit 1: 16-bit samples are big-endian.
        public static let bigEndian = Conversion(rawValue: 0x02)
        /// Bit 2: samples are delta-encoded. For compressed samples this
        /// bit selects the IT 2.15 codec variant.
        public static let delta = Conversion(rawValue: 0x04)
        /// Bit 3: byte-delta encoding (PTM-style 16-bit samples).
        public static let byteDelta = Conversion(rawValue: 0x08)
        /// Bit 4: 12-bit TX-Wave sample (not decoded; see README).
        public static let txWave12Bit = Conversion(rawValue: 0x10)

        /// The whole byte equal to 0xFF on an 8-bit sample marks
        /// ModPlug's 4-bit ADPCM encoding.
        public static let modPlugADPCM = Conversion(rawValue: 0xFF)
    }

    /// A sample loop. Offsets are in sample frames; `end` is exclusive.
    public struct Loop: Sendable, Hashable {
        /// First frame of the loop.
        public let start: Int
        /// Frame just past the end of the loop. Always `> start` and
        /// `<= ` the sample's ``ITSample/length``.
        public let end: Int
        /// Bidirectional (ping-pong) loop.
        public let isPingPong: Bool

        /// Creates a loop description.
        public init(start: Int, end: Int, isPingPong: Bool) {
            self.start = start
            self.end = end
            self.isPingPong = isPingPong
        }
    }

    /// Auto-vibrato waveform (`ViT`).
    public enum Waveform: UInt8, Sendable, Hashable {
        /// Sine wave.
        case sine = 0
        /// Ramp down (sawtooth).
        case rampDown = 1
        /// Square wave.
        case square = 2
        /// Random values.
        case random = 3
    }

    /// Sample auto-vibrato settings (`ViS`, `ViD`, `ViR`, `ViT`).
    public struct AutoVibrato: Sendable, Hashable {
        /// `ViS`: phase advance per tick (0...64).
        public let speed: UInt8
        /// `ViD`: maximum depth (0...64).
        public let depth: UInt8
        /// `ViR`: depth ramp per tick, in 1/256 depth units (0...64).
        public let rate: UInt8
        /// `ViT`: waveform. Values above 3 are read as ``Waveform/sine``.
        public let waveform: Waveform

        /// Creates an auto-vibrato description.
        public init(speed: UInt8, depth: UInt8, rate: UInt8, waveform: Waveform) {
            self.speed = speed
            self.depth = depth
            self.rate = rate
            self.waveform = waveform
        }
    }

    /// Sample name (26 bytes, CP437, trailing spaces trimmed).
    public let name: String
    /// DOS file name (12 bytes, CP437).
    public let fileName: String
    /// `GvL`: sample global volume, clamped to 0...64.
    public let globalVolume: UInt8
    /// `Vol`: default note volume, clamped to 0...64.
    public let defaultVolume: UInt8
    /// `DfP`: default pan 0...64, or `nil` when bit 7 ("use") is clear.
    public let defaultPan: UInt8?
    /// `C5Speed`: playback rate in Hz for note C-5. A stored value of 0
    /// is replaced with 8363.
    public let c5Speed: UInt32
    /// The raw `Flg` byte.
    public let flags: Flags
    /// The raw `Cvt` byte.
    public let conversion: Conversion
    /// Regular loop, or `nil` when disabled or degenerate.
    public let loop: Loop?
    /// Sustain loop, or `nil` when disabled or degenerate.
    public let sustainLoop: Loop?
    /// Auto-vibrato settings.
    public let autoVibrato: AutoVibrato
    /// Decoded PCM, left (or only) channel.
    public let pcm: [Int16]
    /// Decoded PCM, right channel, for stereo samples; otherwise `nil`.
    public let pcmRight: [Int16]?
    /// `true` when the file ended (or the compressed stream broke off)
    /// before the header's declared length was decoded. ``pcm`` then
    /// holds only the frames that were present.
    public let isTruncated: Bool

    /// Number of decoded frames (equal to `pcm.count`).
    public var length: Int { pcm.count }
    /// Whether the source data was 16-bit.
    public var is16Bit: Bool { flags.contains(.is16Bit) }
    /// Whether the sample has two channels of decoded PCM.
    public var isStereo: Bool { pcmRight != nil }
    /// Whether the source data used IT 2.14 / 2.15 compression.
    public var isCompressed: Bool { flags.contains(.isCompressed) }

    /// An empty slot (zero parapointer).
    public static let empty = ITSample(
        name: "", fileName: "", globalVolume: 64, defaultVolume: 64, defaultPan: nil,
        c5Speed: 8363, flags: [], conversion: [], loop: nil, sustainLoop: nil,
        autoVibrato: AutoVibrato(speed: 0, depth: 0, rate: 0, waveform: .sine),
        pcm: [], pcmRight: nil, isTruncated: false
    )

    init(
        name: String, fileName: String, globalVolume: UInt8, defaultVolume: UInt8,
        defaultPan: UInt8?, c5Speed: UInt32, flags: Flags, conversion: Conversion,
        loop: Loop?, sustainLoop: Loop?, autoVibrato: AutoVibrato,
        pcm: [Int16], pcmRight: [Int16]?, isTruncated: Bool
    ) {
        self.name = name
        self.fileName = fileName
        self.globalVolume = globalVolume
        self.defaultVolume = defaultVolume
        self.defaultPan = defaultPan
        self.c5Speed = c5Speed
        self.flags = flags
        self.conversion = conversion
        self.loop = loop
        self.sustainLoop = sustainLoop
        self.autoVibrato = autoVibrato
        self.pcm = pcm
        self.pcmRight = pcmRight
        self.isTruncated = isTruncated
    }
}

// MARK: - Parsing

extension ITSample {

    /// Size of the `IMPS` header.
    static let headerSize = 0x50

    /// Decoded PCM plus bookkeeping, cached by source so duplicate
    /// headers that share one data block are decoded once.
    struct DecodeKey: Hashable {
        let pointer: Int
        let length: Int
        let flags: UInt8
        let conversion: UInt8
    }

    struct Decoded {
        let left: [Int16]
        let right: [Int16]?
        let truncated: Bool
    }

    /// Parse the sample header at `base`.
    ///
    /// - Parameters:
    ///   - createdWith: The file's `Cwt`; stereo flags from IT < 2.14 are
    ///     ignored (old IT versions failed to clear them).
    ///   - frameBudget: Remaining decoded-frame budget; decremented.
    ///   - cache: Decoded-PCM cache keyed by data pointer and format.
    static func parse(
        bytes: [UInt8],
        at base: Int,
        index: Int,
        createdWith: UInt16,
        frameBudget: inout Int,
        cache: inout [DecodeKey: Decoded]
    ) throws -> ITSample {
        guard bytes.contains(offset: base, length: headerSize) else {
            throw ITError.invalidOffset(.sample, index: index, offset: base)
        }
        guard bytes[base] == 0x49, bytes[base + 1] == 0x4D,
              bytes[base + 2] == 0x50, bytes[base + 3] == 0x53 else {
            throw ITError.invalidSampleHeader(index: index)
        }

        let fileName = bytes.cp437String(at: base + 0x04, maxLength: 12)
        let globalVolume = min(bytes[base + 0x11], 64)
        var flags = Flags(rawValue: bytes[base + 0x12])
        let volume = min(bytes[base + 0x13], 64)
        let name = bytes.cp437String(at: base + 0x14, maxLength: 26)
        let cvt = Conversion(rawValue: bytes[base + 0x2E])
        let dfp = bytes[base + 0x2F]
        let declaredLength = Int(bytes.u32(base + 0x30))
        let loopBegin = Int(bytes.u32(base + 0x34))
        let loopEnd = Int(bytes.u32(base + 0x38))
        var c5 = bytes.u32(base + 0x3C)
        let susBegin = Int(bytes.u32(base + 0x40))
        let susEnd = Int(bytes.u32(base + 0x44))
        let pointer = Int(bytes.u32(base + 0x48))
        let vibrato = AutoVibrato(
            speed: min(bytes[base + 0x4C], 64),
            depth: min(bytes[base + 0x4D], 64),
            rate: min(bytes[base + 0x4E], 64),
            waveform: Waveform(rawValue: bytes[base + 0x4F]) ?? .sine
        )
        if c5 == 0 { c5 = 8363 }
        // IT itself caps C5Speed at 9999999 Hz.
        c5 = min(c5, 9_999_999)

        // IT before 2.14 did not clear the stereo bit when importing.
        if createdWith < 0x0214 { flags.remove(.isStereo) }

        var left: [Int16] = []
        var right: [Int16]? = nil
        var truncated = false

        if flags.contains(.hasData) && declaredLength > 0 {
            let key = DecodeKey(pointer: pointer, length: declaredLength,
                                flags: flags.rawValue, conversion: cvt.rawValue)
            let decoded: Decoded
            if let hit = cache[key] {
                decoded = hit
            } else {
                decoded = decode(bytes: bytes, pointer: pointer, length: declaredLength,
                                 flags: flags, conversion: cvt)
                let frames = decoded.left.count + (decoded.right?.count ?? 0)
                frameBudget -= frames
                guard frameBudget >= 0 else { throw ITError.limitExceeded(.sampleFrames) }
                cache[key] = decoded
            }
            left = decoded.left
            right = decoded.right
            truncated = decoded.truncated
        }

        let length = left.count
        func makeLoop(_ start: Int, _ end: Int, pingPong: Bool) -> Loop? {
            let clampedEnd = min(end, length)
            guard start >= 0, start < clampedEnd else { return nil }
            return Loop(start: start, end: clampedEnd, isPingPong: pingPong)
        }

        return ITSample(
            name: name,
            fileName: fileName,
            globalVolume: globalVolume,
            defaultVolume: volume,
            defaultPan: (dfp & 0x80) != 0 ? min(dfp & 0x7F, 64) : nil,
            c5Speed: c5,
            flags: flags,
            conversion: cvt,
            loop: flags.contains(.loop)
                ? makeLoop(loopBegin, loopEnd, pingPong: flags.contains(.pingPongLoop)) : nil,
            sustainLoop: flags.contains(.sustainLoop)
                ? makeLoop(susBegin, susEnd, pingPong: flags.contains(.pingPongSustainLoop)) : nil,
            autoVibrato: vibrato,
            pcm: left,
            pcmRight: right,
            isTruncated: truncated
        )
    }

    /// Decode the PCM block for one header.
    static func decode(
        bytes: [UInt8],
        pointer: Int,
        length: Int,
        flags: Flags,
        conversion cvt: Conversion
    ) -> Decoded {
        let is16 = flags.contains(.is16Bit)
        let stereo = flags.contains(.isStereo)

        guard pointer > 0, pointer < bytes.count else {
            return Decoded(left: [], right: stereo ? [] : nil, truncated: true)
        }

        if flags.contains(.isCompressed) {
            let it215 = cvt.contains(.delta)
            let l = ITDecompress.decompress(bytes: bytes, offset: pointer, length: length,
                                            is16Bit: is16, it215: it215)
            guard stereo else {
                return Decoded(left: l.samples, right: nil, truncated: !l.isComplete)
            }
            let r = ITDecompress.decompress(bytes: bytes, offset: l.endOffset, length: length,
                                            is16Bit: is16, it215: it215)
            let n = min(l.samples.count, r.samples.count)
            return Decoded(left: Array(l.samples.prefix(n)), right: Array(r.samples.prefix(n)),
                           truncated: !(l.isComplete && r.isComplete))
        }

        if !is16 && cvt == .modPlugADPCM {
            return decodeADPCM(bytes: bytes, pointer: pointer, length: length)
        }

        // Uncompressed PCM. Stereo data is stored as all left frames
        // followed by all right frames (not interleaved).
        let bytesPerFrame = is16 ? 2 : 1
        let available = bytes.count - pointer
        let channels = stereo ? 2 : 1
        let perChannelAvailable = available / (bytesPerFrame * channels)
        let frames = min(length, perChannelAvailable)
        let truncated = frames < length

        let channelStride = length.multipliedReportingOverflow(by: bytesPerFrame)
        let leftPCM = decodePCM(bytes: bytes, offset: pointer, frames: frames, is16: is16, cvt: cvt)
        var rightPCM: [Int16]? = nil
        if stereo {
            // The right channel starts after the full declared left
            // channel; whatever of it is present gets decoded.
            if !channelStride.overflow, pointer <= bytes.count - channelStride.partialValue {
                let rOffset = pointer + channelStride.partialValue
                let rFrames = min(frames, (bytes.count - rOffset) / bytesPerFrame)
                rightPCM = decodePCM(bytes: bytes, offset: rOffset, frames: rFrames, is16: is16, cvt: cvt)
            } else {
                rightPCM = []
            }
        }
        if let r = rightPCM, r.count < leftPCM.count {
            return Decoded(left: Array(leftPCM.prefix(r.count)), right: r, truncated: true)
        }
        return Decoded(left: leftPCM, right: rightPCM, truncated: truncated)
    }

    /// Decode `frames` uncompressed frames of one channel. The caller
    /// guarantees the bytes are present.
    static func decodePCM(bytes: [UInt8], offset: Int, frames: Int, is16: Bool, cvt: Conversion) -> [Int16] {
        guard frames > 0 else { return [] }
        var out = [Int16](repeating: 0, count: frames)
        let signed = cvt.contains(.signed)
        let delta = cvt.contains(.delta)
        bytes.withUnsafeBufferPointer { src in
            if is16 {
                let bigEndian = cvt.contains(.bigEndian)
                if cvt.contains(.byteDelta) {
                    // PTM-style: the byte stream itself is delta coded
                    // (8-bit wrapping), then pairs form LE words.
                    var acc: UInt8 = 0
                    for i in 0..<frames {
                        acc = acc &+ src[offset + 2 * i]
                        let lo = acc
                        acc = acc &+ src[offset + 2 * i + 1]
                        let word = UInt16(lo) | (UInt16(acc) << 8)
                        out[i] = signed ? Int16(bitPattern: word) : Int16(bitPattern: word ^ 0x8000)
                    }
                    return
                }
                var acc: UInt16 = 0
                for i in 0..<frames {
                    let b0 = UInt16(src[offset + 2 * i])
                    let b1 = UInt16(src[offset + 2 * i + 1])
                    var word = bigEndian ? (b0 << 8) | b1 : (b1 << 8) | b0
                    if delta { acc = acc &+ word; word = acc }
                    out[i] = signed ? Int16(bitPattern: word) : Int16(bitPattern: word ^ 0x8000)
                }
            } else {
                var acc: UInt8 = 0
                for i in 0..<frames {
                    var byte = src[offset + i]
                    if delta { acc = acc &+ byte; byte = acc }
                    let s = signed ? Int8(bitPattern: byte) : Int8(bitPattern: byte ^ 0x80)
                    out[i] = Int16(s) << 8
                }
            }
        }
        return out
    }

    /// ModPlug 4-bit ADPCM: a 16-byte table of signed deltas followed by
    /// `ceil(length / 2)` bytes, low nibble first.
    static func decodeADPCM(bytes: [UInt8], pointer: Int, length: Int) -> Decoded {
        guard bytes.contains(offset: pointer, length: 16) else {
            return Decoded(left: [], right: nil, truncated: true)
        }
        let table = (0..<16).map { Int8(bitPattern: bytes[pointer + $0]) }
        let dataStart = pointer + 16
        let maxFrames = (bytes.count - dataStart) * 2
        let frames = min(length, maxFrames)
        var out = [Int16](repeating: 0, count: frames)
        var acc: Int8 = 0
        for i in 0..<frames {
            let b = bytes[dataStart + i / 2]
            let nibble = i & 1 == 0 ? b & 0x0F : b >> 4
            acc = acc &+ table[Int(nibble)]
            out[i] = Int16(acc) << 8
        }
        return Decoded(left: out, right: nil, truncated: frames < length)
    }
}
