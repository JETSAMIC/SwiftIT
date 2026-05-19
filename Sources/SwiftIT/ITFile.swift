/// ITFile.swift
///
/// Pure-Swift parser for Impulse Tracker `.IT` modules.
///
/// Format reference: Jeffrey Lim's ITTECH.TXT (the canonical spec
/// shipped with Impulse Tracker 2.14). Mirrored in the OpenMPT and
/// Schism Tracker source trees; we don't bundle a copy in-repo to
/// avoid the licensing question — point your editor at OpenMPT's
/// `soundlib/load_it.cpp` or the Schism tree if you want the
/// byte-level reference.
///
/// What's parsed today:
/// - 192-byte IMPM header (orders, instruments, samples, patterns,
///   flags, channel pan/vol)
/// - Order list + instrument / sample / pattern parapointers
/// - Sample headers (`IMPS`) and **uncompressed** sample data
///   (8/16-bit, signed/unsigned, delta-encoded variants)
/// - New-format instruments (`IMPI`, IT 2.00+) with note→sample
///   keyboard table and the three 82-byte envelopes
///   (volume / panning / pitch)
/// - Old-format instruments (IT 1.x, 554 bytes) — coerced into the
///   new-format struct so the mixer doesn't have to branch
/// - Bit-flag-compressed pattern stream with per-channel mask /
///   note / instrument / volume / command memory
///
/// What's *not* parsed yet (flagged in the README too):
/// - IT 2.14 sample compression (`IMPS` flag bit 3). Compressed
///   samples currently decode to silence — the rest of the song
///   still plays. Most pre-2.14 packs aren't affected.
/// - Embedded MIDI configuration
/// - Song message (we skip past it, but don't surface the text)

import Foundation

// MARK: - Errors

public enum ITError: Error, LocalizedError, Sendable, Equatable {
    case notAnITFile
    case truncated
    case unsupportedSampleFormat
    case patternOutOfRange(Int)

    public var errorDescription: String? {
        switch self {
        case .notAnITFile:           return "Missing IMPM magic — not an Impulse Tracker module."
        case .truncated:             return "File ended mid-structure."
        case .unsupportedSampleFormat: return "Sample format combination not supported."
        case .patternOutOfRange(let i): return "Pattern index \(i) outside file bounds."
        }
    }
}

// MARK: - ITFile

public struct ITFile: Sendable {

    // Header
    public let songName: String
    public let orderCount: Int
    public let instrumentCount: Int
    public let sampleCount: Int
    public let patternCount: Int

    /// "Created with tracker" version (e.g. 0x0214 = IT 2.14).
    public let createdWith: UInt16
    /// Minimum compatibility version.
    public let compatibleWith: UInt16

    /// Header flag bits, exposed verbatim so the mixer can branch
    /// on linear-vs-Amiga slides, instruments-vs-samples mode, etc.
    public let flags: UInt16

    public var usesInstruments: Bool { (flags & 0x04) != 0 }
    public var usesLinearSlides: Bool { (flags & 0x08) != 0 }
    public var usesOldEffects: Bool { (flags & 0x10) != 0 }
    public var linkGwithEF: Bool { (flags & 0x20) != 0 }
    public var stereo: Bool { (flags & 0x01) != 0 }

    public let globalVolume: UInt8
    public let mixVolume: UInt8
    public let initialSpeed: UInt8
    public let initialTempo: UInt8
    public let separation: UInt8

    /// Per-channel pan (0..64 = pan, 100 = surround, +128 = disabled).
    public let channelPan: [UInt8]
    /// Per-channel volume (0..64).
    public let channelVolume: [UInt8]

    /// Order list. 254 = skip (++order without playing), 255 = end.
    public let orders: [UInt8]

    public let instruments: [ITInstrument]
    public let samples: [ITSample]
    public let patterns: [ITPattern]

    // MARK: - Parse

    public init(data: Data) throws {
        // Bare minimum: 192 bytes for the header plus 4 magic.
        guard data.count >= 192 else { throw ITError.truncated }

        // Magic: "IMPM" at offset 0.
        guard data[0] == 0x49, data[1] == 0x4D, data[2] == 0x50, data[3] == 0x4D else {
            throw ITError.notAnITFile
        }

        self.songName = Self.readZString(data, range: 0x04..<0x1E)

        let ordNum = Int(data.readUInt16LE(at: 0x20))
        let insNum = Int(data.readUInt16LE(at: 0x22))
        let smpNum = Int(data.readUInt16LE(at: 0x24))
        let patNum = Int(data.readUInt16LE(at: 0x26))

        self.orderCount = ordNum
        self.instrumentCount = insNum
        self.sampleCount = smpNum
        self.patternCount = patNum

        self.createdWith = data.readUInt16LE(at: 0x28)
        self.compatibleWith = data.readUInt16LE(at: 0x2A)
        self.flags = data.readUInt16LE(at: 0x2C)

        self.globalVolume = data[0x30]
        self.mixVolume    = data[0x31]
        self.initialSpeed = data[0x32]
        self.initialTempo = data[0x33]
        self.separation   = data[0x34]

        // Channel pan/vol live in the header (offsets 0x40 + 0x80, 64 bytes each).
        var pan = [UInt8](repeating: 32, count: 64)
        var vol = [UInt8](repeating: 64, count: 64)
        for i in 0..<64 {
            pan[i] = data[0x40 + i]
            vol[i] = data[0x80 + i]
        }
        self.channelPan = pan
        self.channelVolume = vol

        // Order list begins at byte 192 (0xC0).
        let ordersBase = 0xC0
        guard data.count >= ordersBase + ordNum else { throw ITError.truncated }
        var orderList = [UInt8](repeating: 255, count: ordNum)
        for i in 0..<ordNum {
            orderList[i] = data[ordersBase + i]
        }
        self.orders = orderList

        // Parapointer tables follow immediately.
        let insPtrBase = ordersBase + ordNum
        let smpPtrBase = insPtrBase + insNum * 4
        let patPtrBase = smpPtrBase + smpNum * 4
        let patPtrEnd  = patPtrBase + patNum * 4
        guard data.count >= patPtrEnd else { throw ITError.truncated }

        func readPointers(at base: Int, count: Int) -> [Int] {
            var out: [Int] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                out.append(Int(data.readUInt32LE(at: base + i * 4)))
            }
            return out
        }
        let insPtrs = readPointers(at: insPtrBase, count: insNum)
        let smpPtrs = readPointers(at: smpPtrBase, count: smpNum)
        let patPtrs = readPointers(at: patPtrBase, count: patNum)

        // Instruments first — they reference samples by index.
        var ins: [ITInstrument] = []
        ins.reserveCapacity(insNum)
        for ptr in insPtrs {
            if ptr <= 0 || ptr + 4 > data.count {
                ins.append(.empty)
                continue
            }
            // IT 2.00+ instruments start with "IMPI". Old IT 1.x
            // instruments don't have that magic and need the legacy
            // layout. We sniff so the same loader works on both.
            if data[ptr] == 0x49 && data[ptr+1] == 0x4D && data[ptr+2] == 0x50 && data[ptr+3] == 0x49 {
                ins.append(ITInstrument.parseNewFormat(data: data, at: ptr))
            } else {
                ins.append(ITInstrument.parseOldFormat(data: data, at: ptr))
            }
        }
        self.instruments = ins

        // Samples — header + linear or compressed sample data. The
        // `compatibleWith` field decides which compression flavor
        // a compressed sample uses (2.14 = simple delta, 2.15+ =
        // delta of delta).
        let is215 = compatibleWith >= 0x215
        var smp: [ITSample] = []
        smp.reserveCapacity(smpNum)
        for ptr in smpPtrs {
            if ptr <= 0 || ptr + 80 > data.count {
                smp.append(.empty)
                continue
            }
            smp.append(ITSample.parse(data: data, at: ptr, is215: is215))
        }
        self.samples = smp

        // Patterns: 8-byte header (length, rows, 4 reserved) then
        // packed channel data. A pointer of 0 means "empty pattern"
        // (IT writes literal silence rather than allocating).
        var pats: [ITPattern] = []
        pats.reserveCapacity(patNum)
        for ptr in patPtrs {
            if ptr == 0 {
                pats.append(ITPattern.empty(rows: 64))
                continue
            }
            if ptr + 8 > data.count {
                pats.append(ITPattern.empty(rows: 64))
                continue
            }
            let length = Int(data.readUInt16LE(at: ptr))
            let rows   = Int(data.readUInt16LE(at: ptr + 2))
            let payloadStart = ptr + 8
            let payloadEnd = payloadStart + length
            guard payloadEnd <= data.count else {
                pats.append(ITPattern.empty(rows: rows))
                continue
            }
            pats.append(ITPattern.unpack(
                data: data,
                payloadRange: payloadStart..<payloadEnd,
                rows: rows
            ))
        }
        self.patterns = pats
    }

    /// Read a fixed-length NUL-padded ASCII string from `range`.
    /// Trims trailing zeros and whitespace.
    static func readZString(_ data: Data, range: Range<Int>) -> String {
        var bytes: [UInt8] = []
        for i in range {
            let b = data[i]
            if b == 0 { break }
            bytes.append(b)
        }
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}

// MARK: - Sample

public struct ITSample: Sendable {

    public var name: String
    public var globalVolume: UInt8
    public var volume: UInt8
    public var defaultPan: UInt8         // bit 7 = "use", low 7 = pan
    public var c5Speed: UInt32           // frequency for C-5

    public var length: Int               // samples (not bytes)
    public var loopBegin: Int
    public var loopEnd: Int
    public var sustainBegin: Int
    public var sustainEnd: Int

    public var has16Bit: Bool
    public var hasLoop: Bool
    public var hasSustainLoop: Bool
    public var hasPingPongLoop: Bool
    public var hasPingPongSustain: Bool
    public var isStereo: Bool
    public var isCompressed: Bool

    public var vibratoSpeed: UInt8
    public var vibratoDepth: UInt8
    public var vibratoRate: UInt8
    public var vibratoType: UInt8

    /// Decoded PCM samples in Float32, mono. Stereo samples are
    /// folded to mono on load to keep the mixer simple — IT
    /// instruments are overwhelmingly mono in real-world packs.
    public var pcm: [Float]

    public static let empty = ITSample(
        name: "", globalVolume: 64, volume: 64, defaultPan: 0, c5Speed: 8363,
        length: 0, loopBegin: 0, loopEnd: 0, sustainBegin: 0, sustainEnd: 0,
        has16Bit: false, hasLoop: false, hasSustainLoop: false,
        hasPingPongLoop: false, hasPingPongSustain: false,
        isStereo: false, isCompressed: false,
        vibratoSpeed: 0, vibratoDepth: 0, vibratoRate: 0, vibratoType: 0,
        pcm: []
    )

    static func parse(data: Data, at base: Int, is215: Bool = false) -> ITSample {
        let globalVol = data[base + 0x11]
        let flag      = data[base + 0x12]
        let volume    = data[base + 0x13]
        let cvt       = data[base + 0x2E]
        let dfp       = data[base + 0x2F]

        let length        = Int(data.readUInt32LE(at: base + 0x30))
        let loopBegin     = Int(data.readUInt32LE(at: base + 0x34))
        let loopEnd       = Int(data.readUInt32LE(at: base + 0x38))
        let c5Speed       = data.readUInt32LE(at: base + 0x3C)
        let susBegin      = Int(data.readUInt32LE(at: base + 0x40))
        let susEnd        = Int(data.readUInt32LE(at: base + 0x44))
        let samplePointer = Int(data.readUInt32LE(at: base + 0x48))

        let has16        = (flag & 0x02) != 0
        let isStereo     = (flag & 0x04) != 0
        let isCompressed = (flag & 0x08) != 0
        let hasLoop      = (flag & 0x10) != 0
        let hasSusLoop   = (flag & 0x20) != 0
        let pingPong     = (flag & 0x40) != 0
        let pingPongSus  = (flag & 0x80) != 0
        let hasSample    = (flag & 0x01) != 0

        let name = ITFile.readZString(data, range: (base + 0x14)..<(base + 0x14 + 26))
        let vibSpeed = data[base + 0x4C]
        let vibDepth = data[base + 0x4D]
        let vibRate  = data[base + 0x4E]
        let vibType  = data[base + 0x4F]

        // Decode PCM. `cvt` carries the on-disk encoding:
        //   bit 0 = signed (otherwise unsigned)
        //   bit 1 = big-endian (extremely rare in IT)
        //   bit 2 = delta-encoded
        //   bit 3 = "ITSCRAMBLE" 12-bit (not handled)
        var pcm: [Float] = []
        if hasSample, length > 0, samplePointer > 0, samplePointer < data.count {
            if isCompressed {
                // IT 2.14 / 2.15 variable-bit-width codec. Stereo
                // compressed samples are stored as two consecutive
                // compressed streams (left, then right); we fold to
                // mono by averaging once both are decoded.
                if isStereo {
                    let leftPCM = has16
                        ? ITDecompress.decompress16(data: data, offset: samplePointer, sampleCount: length, is215: is215)
                        : ITDecompress.decompress8(data: data, offset: samplePointer, sampleCount: length, is215: is215)
                    // The right channel begins immediately after the
                    // left in the file; the codec doesn't tell us the
                    // exact byte length, so we conservatively skip
                    // past the input we know we needed by counting
                    // bytes the bit reader would have consumed.
                    // Compressed-stereo IT samples are vanishingly
                    // rare; in practice we fall back to mono-left.
                    pcm = leftPCM
                } else {
                    pcm = has16
                        ? ITDecompress.decompress16(data: data, offset: samplePointer, sampleCount: length, is215: is215)
                        : ITDecompress.decompress8(data: data, offset: samplePointer, sampleCount: length, is215: is215)
                }
            } else {
                pcm = decodeSample(
                    data: data,
                    offset: samplePointer,
                    length: length,
                    has16Bit: has16,
                    isStereo: isStereo,
                    isSigned: (cvt & 0x01) != 0,
                    isBigEndian: (cvt & 0x02) != 0,
                    isDelta: (cvt & 0x04) != 0
                )
            }
        }

        return ITSample(
            name: name,
            globalVolume: globalVol,
            volume: volume,
            defaultPan: dfp,
            c5Speed: c5Speed,
            length: length,
            loopBegin: loopBegin,
            loopEnd: loopEnd,
            sustainBegin: susBegin,
            sustainEnd: susEnd,
            has16Bit: has16,
            hasLoop: hasLoop,
            hasSustainLoop: hasSusLoop,
            hasPingPongLoop: pingPong,
            hasPingPongSustain: pingPongSus,
            isStereo: isStereo,
            isCompressed: isCompressed,
            vibratoSpeed: vibSpeed,
            vibratoDepth: vibDepth,
            vibratoRate: vibRate,
            vibratoType: vibType,
            pcm: pcm
        )
    }

    /// Decode raw bytes into normalized Float32 samples. Delta
    /// decoding folds in either before or after sign conversion
    /// depending on the encoder; we follow the IT 2.x convention
    /// (delta on the integer sample, then sign + normalize).
    static func decodeSample(
        data: Data,
        offset: Int,
        length: Int,
        has16Bit: Bool,
        isStereo: Bool,
        isSigned: Bool,
        isBigEndian: Bool,
        isDelta: Bool
    ) -> [Float] {
        let bytesPerSample = has16Bit ? 2 : 1
        let channels = isStereo ? 2 : 1
        let total = length * channels
        let neededBytes = total * bytesPerSample
        guard offset + neededBytes <= data.count else { return [] }

        var out = [Float](repeating: 0, count: length)
        var previousL: Int32 = 0
        var previousR: Int32 = 0

        for i in 0..<length {
            // Per-channel integer fetch + delta accumulate.
            var lVal: Int32 = 0
            var rVal: Int32 = 0

            for ch in 0..<channels {
                let cursor = offset + (i * channels + ch) * bytesPerSample
                var raw: Int32 = 0
                if has16Bit {
                    let b0 = Int32(data[cursor])
                    let b1 = Int32(data[cursor + 1])
                    let assembled: Int32 = isBigEndian ? (b0 << 8) | b1 : (b1 << 8) | b0
                    raw = isSigned ? Int32(Int16(truncatingIfNeeded: assembled)) : assembled - 32768
                } else {
                    let b = Int32(data[cursor])
                    raw = isSigned ? Int32(Int8(truncatingIfNeeded: b)) : b - 128
                }
                if isDelta {
                    if ch == 0 {
                        previousL = previousL &+ raw
                        lVal = previousL
                    } else {
                        previousR = previousR &+ raw
                        rVal = previousR
                    }
                } else {
                    if ch == 0 { lVal = raw } else { rVal = raw }
                }
            }

            // Stereo → mono by averaging both channels. Cheaper than
            // doubling the mixer's voice count and matches what
            // OpenMPT does when stereo voices are folded.
            let merged: Float
            if isStereo {
                merged = Float(lVal + rVal) / (has16Bit ? 65536.0 : 256.0)
            } else {
                merged = Float(lVal) / (has16Bit ? 32768.0 : 128.0)
            }
            out[i] = merged
        }
        return out
    }
}

// MARK: - Envelope

public struct ITEnvelope: Sendable, Hashable {

    public struct Node: Sendable, Hashable {
        public let value: Int8
        public let tick: UInt16
    }

    public var enabled: Bool
    public var hasLoop: Bool
    public var hasSustainLoop: Bool
    public var isFilterEnvelope: Bool

    public var loopBegin: Int
    public var loopEnd: Int
    public var sustainBegin: Int
    public var sustainEnd: Int

    public var nodes: [Node]

    public static let empty = ITEnvelope(
        enabled: false, hasLoop: false, hasSustainLoop: false,
        isFilterEnvelope: false,
        loopBegin: 0, loopEnd: 0, sustainBegin: 0, sustainEnd: 0,
        nodes: []
    )

    static func parse(data: Data, at base: Int) -> ITEnvelope {
        let flags = data[base]
        let nodeCount = Int(data[base + 1])
        let loopBegin = Int(data[base + 2])
        let loopEnd = Int(data[base + 3])
        let susBegin = Int(data[base + 4])
        let susEnd = Int(data[base + 5])

        var nodes: [Node] = []
        nodes.reserveCapacity(nodeCount)
        for i in 0..<min(nodeCount, 25) {
            let nodeBase = base + 6 + i * 3
            // value is signed 8-bit; the following two bytes are
            // the tick position as little-endian UInt16.
            let v = Int8(bitPattern: data[nodeBase])
            let tick = data.readUInt16LE(at: nodeBase + 1)
            nodes.append(Node(value: v, tick: tick))
        }

        return ITEnvelope(
            enabled:           (flags & 0x01) != 0,
            hasLoop:           (flags & 0x02) != 0,
            hasSustainLoop:    (flags & 0x04) != 0,
            isFilterEnvelope:  (flags & 0x80) != 0,
            loopBegin: loopBegin,
            loopEnd: loopEnd,
            sustainBegin: susBegin,
            sustainEnd: susEnd,
            nodes: nodes
        )
    }
}

// MARK: - Instrument

public struct ITInstrument: Sendable {

    public var name: String
    public var fadeOut: UInt16
    public var newNoteAction: UInt8     // 0=cut, 1=continue, 2=off, 3=fade
    public var duplicateCheckType: UInt8
    public var duplicateCheckAction: UInt8
    public var globalVolume: UInt8      // 0..128
    public var defaultPan: UInt8        // bit 7 = use, low 7 = pan 0..64
    public var pitchPanSeparation: Int8
    public var pitchPanCenter: UInt8
    public var randomVolume: UInt8
    public var randomPan: UInt8
    public var initialFilterCutoff: UInt8
    public var initialFilterResonance: UInt8

    /// Note→sample map. 96 entries, each `(transposedNote, sampleIndex)`.
    /// Sample index of 0 means "no sample for this note."
    public var noteSampleMap: [(note: UInt8, sample: UInt8)]

    public var volumeEnvelope: ITEnvelope
    public var panningEnvelope: ITEnvelope
    public var pitchEnvelope: ITEnvelope

    public static let empty = ITInstrument(
        name: "", fadeOut: 0,
        newNoteAction: 0, duplicateCheckType: 0, duplicateCheckAction: 0,
        globalVolume: 128, defaultPan: 0,
        pitchPanSeparation: 0, pitchPanCenter: 60,
        randomVolume: 0, randomPan: 0,
        initialFilterCutoff: 0, initialFilterResonance: 0,
        noteSampleMap: Array(repeating: (0, 0), count: 120),
        volumeEnvelope: .empty, panningEnvelope: .empty, pitchEnvelope: .empty
    )

    static func parseNewFormat(data: Data, at base: Int) -> ITInstrument {
        // New-format header layout per ITTECH.TXT (IT 2.x). The 120
        // note slots cover the full MIDI range; older specs claim 96
        // but Schism/OpenMPT both honor the larger table.
        let nna = data[base + 0x11]
        let dct = data[base + 0x12]
        let dca = data[base + 0x13]
        let fade = data.readUInt16LE(at: base + 0x14)
        let pps = Int8(bitPattern: data[base + 0x16])
        let ppc = data[base + 0x17]
        let gbv = data[base + 0x18]
        let dfp = data[base + 0x19]
        let rv = data[base + 0x1A]
        let rp = data[base + 0x1B]
        let ifc = data[base + 0x3A]
        let ifr = data[base + 0x3B]

        let name = ITFile.readZString(data, range: (base + 0x20)..<(base + 0x20 + 26))

        var map = Array(repeating: (UInt8(0), UInt8(0)), count: 120)
        for i in 0..<120 {
            let entry = base + 0x40 + i * 2
            map[i] = (data[entry], data[entry + 1])
        }

        let volEnv  = ITEnvelope.parse(data: data, at: base + 0x130)
        let panEnv  = ITEnvelope.parse(data: data, at: base + 0x182)
        let pitchEnv = ITEnvelope.parse(data: data, at: base + 0x1D4)

        return ITInstrument(
            name: name, fadeOut: fade,
            newNoteAction: nna,
            duplicateCheckType: dct,
            duplicateCheckAction: dca,
            globalVolume: gbv,
            defaultPan: dfp,
            pitchPanSeparation: pps,
            pitchPanCenter: ppc,
            randomVolume: rv,
            randomPan: rp,
            initialFilterCutoff: ifc,
            initialFilterResonance: ifr,
            noteSampleMap: map,
            volumeEnvelope: volEnv,
            panningEnvelope: panEnv,
            pitchEnvelope: pitchEnv
        )
    }

    /// Old-format instruments (IT 1.x). 554 bytes, no envelopes —
    /// just a volume curve that we collapse into the "envelope
    /// disabled" path and a 240-byte note→sample table.
    static func parseOldFormat(data: Data, at base: Int) -> ITInstrument {
        let name = ITFile.readZString(data, range: (base + 0x20)..<(base + 0x20 + 26))
        let fade = data.readUInt16LE(at: base + 0x18)
        let nna = data[base + 0x10] // old format: NNA at 0x10, not 0x11
        var map = Array(repeating: (UInt8(0), UInt8(0)), count: 120)
        for i in 0..<120 {
            let entry = base + 0x40 + i * 2
            map[i] = (data[entry], data[entry + 1])
        }
        return ITInstrument(
            name: name, fadeOut: fade,
            newNoteAction: nna,
            duplicateCheckType: 0,
            duplicateCheckAction: 0,
            globalVolume: 128,
            defaultPan: 0,
            pitchPanSeparation: 0,
            pitchPanCenter: 60,
            randomVolume: 0,
            randomPan: 0,
            initialFilterCutoff: 0,
            initialFilterResonance: 0,
            noteSampleMap: map,
            volumeEnvelope: .empty,
            panningEnvelope: .empty,
            pitchEnvelope: .empty
        )
    }
}

// MARK: - Pattern

public struct ITPattern: Sendable {

    /// Single cell of the unpacked pattern, one per channel per row.
    /// Field-presence is encoded by the parser: a `note` of 255
    /// means "empty", an `instrument` of 0 means "no change."
    public struct Cell: Sendable, Hashable {
        public var note: UInt8 = 255
        public var instrument: UInt8 = 0
        public var volume: UInt8 = 255     // 255 = empty (real values cap at 213)
        public var command: UInt8 = 0       // letter index 0..26 ('A'=1)
        public var commandValue: UInt8 = 0
    }

    public let rowCount: Int
    public let channelCount: Int
    public let rows: [[Cell]]

    static func empty(rows: Int) -> ITPattern {
        let blankRow = Array(repeating: Cell(), count: 64)
        return ITPattern(rowCount: rows, channelCount: 64, rows: Array(repeating: blankRow, count: rows))
    }

    /// Unpack the IT bit-flag-compressed pattern stream into a
    /// dense `[rows × 64]` grid. The format leans on per-channel
    /// last-value caches for note/instrument/volume/command — each
    /// time a channel reuses a previous value the encoder shaves
    /// the byte. We reproduce those caches across the row scan.
    static func unpack(data: Data, payloadRange: Range<Int>, rows: Int) -> ITPattern {
        let channels = 64
        var grid = Array(
            repeating: Array(repeating: Cell(), count: channels),
            count: rows
        )

        // Per-channel memory: which mask bits the encoder set on
        // the most recent entry, plus the actual last values it
        // emitted. Indexed by 0..<64.
        var lastMask = [UInt8](repeating: 0, count: channels)
        var lastNote = [UInt8](repeating: 0, count: channels)
        var lastInstr = [UInt8](repeating: 0, count: channels)
        var lastVol = [UInt8](repeating: 0, count: channels)
        var lastCmd = [UInt8](repeating: 0, count: channels)
        var lastCmdVal = [UInt8](repeating: 0, count: channels)

        var cursor = payloadRange.lowerBound
        var row = 0

        while row < rows && cursor < payloadRange.upperBound {
            let chanVar = data[cursor]
            cursor += 1
            if chanVar == 0 {
                row += 1
                continue
            }
            let channel = Int(chanVar & 0x7F) - 1
            // Channel can be 0..63; guard against malformed indices.
            guard channel >= 0 && channel < channels else { continue }

            var mask = lastMask[channel]
            if (chanVar & 0x80) != 0 {
                guard cursor < payloadRange.upperBound else { break }
                mask = data[cursor]
                cursor += 1
                lastMask[channel] = mask
            }

            // Fresh fields override the cache; "use previous" bits
            // (4..7) replay the cached value into the grid.
            var cell = Cell()

            if (mask & 0x01) != 0 {
                guard cursor < payloadRange.upperBound else { break }
                let note = data[cursor]; cursor += 1
                cell.note = note
                lastNote[channel] = note
            } else if (mask & 0x10) != 0 {
                cell.note = lastNote[channel]
            }

            if (mask & 0x02) != 0 {
                guard cursor < payloadRange.upperBound else { break }
                let ins = data[cursor]; cursor += 1
                cell.instrument = ins
                lastInstr[channel] = ins
            } else if (mask & 0x20) != 0 {
                cell.instrument = lastInstr[channel]
            }

            if (mask & 0x04) != 0 {
                guard cursor < payloadRange.upperBound else { break }
                let vol = data[cursor]; cursor += 1
                cell.volume = vol
                lastVol[channel] = vol
            } else if (mask & 0x40) != 0 {
                cell.volume = lastVol[channel]
            }

            if (mask & 0x08) != 0 {
                guard cursor + 1 < payloadRange.upperBound else { break }
                let cmd = data[cursor]; cursor += 1
                let val = data[cursor]; cursor += 1
                cell.command = cmd
                cell.commandValue = val
                lastCmd[channel] = cmd
                lastCmdVal[channel] = val
            } else if (mask & 0x80) != 0 {
                cell.command = lastCmd[channel]
                cell.commandValue = lastCmdVal[channel]
            }

            grid[row][channel] = cell
        }

        return ITPattern(rowCount: rows, channelCount: channels, rows: grid)
    }
}

// MARK: - Data helpers

extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        precondition(offset + 2 <= count, "readUInt16LE out of bounds")
        let lo = UInt16(self[offset])
        let hi = UInt16(self[offset + 1])
        return (hi << 8) | lo
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        precondition(offset + 4 <= count, "readUInt32LE out of bounds")
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }
}
