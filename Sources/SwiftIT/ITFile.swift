/// ITFile.swift
///
/// Pure-Swift parser for Impulse Tracker `.it` modules. The byte-level
/// layout is documented in `Reference/IT-Format.md`.

import Foundation

/// A parsed Impulse Tracker module.
///
/// `ITFile` is an immutable value: construct it from the file's bytes
/// and hand it to ``ITMixer`` for playback, or inspect its header,
/// instruments, samples, and patterns directly.
///
/// ```swift
/// let module = try ITFile(data: Data(contentsOf: url))
/// print(module.songName, module.orders.count, module.samples.count)
/// ```
public struct ITFile: Sendable {

    /// Header `Flags` word (offset 0x2C).
    public struct Flags: OptionSet, Sendable, Hashable {
        /// The raw 16-bit value.
        public let rawValue: UInt16
        /// Creates a flag set from the raw header word.
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        /// Bit 0: stereo output (otherwise mono).
        public static let stereo = Flags(rawValue: 0x0001)
        /// Bit 1: skip mixing voices whose volume is 0.
        public static let volumeZeroOptimizations = Flags(rawValue: 0x0002)
        /// Bit 2: instrument mode (otherwise sample mode).
        public static let useInstruments = Flags(rawValue: 0x0004)
        /// Bit 3: linear frequency slides (otherwise Amiga period slides).
        public static let linearSlides = Flags(rawValue: 0x0008)
        /// Bit 4: "old effects" (S3M-compatible vibrato depth and timing,
        /// `Oxx` past the end plays from the end).
        public static let oldEffects = Flags(rawValue: 0x0010)
        /// Bit 5: `Gxx` shares memory with `Exx`/`Fxx`
        /// ("compatible Gxx").
        public static let linkedPortamentoMemory = Flags(rawValue: 0x0020)
        /// Bit 6: use the MIDI pitch controller.
        public static let midiPitchController = Flags(rawValue: 0x0040)
        /// Bit 7: request the embedded MIDI configuration.
        public static let requestEmbeddedMIDIConfiguration = Flags(rawValue: 0x0080)
    }

    /// Header `Special` word (offset 0x2E).
    public struct Special: OptionSet, Sendable, Hashable {
        /// The raw 16-bit value.
        public let rawValue: UInt16
        /// Creates a set from the raw header word.
        public init(rawValue: UInt16) { self.rawValue = rawValue }

        /// Bit 0: a song message is attached.
        public static let hasMessage = Special(rawValue: 0x0001)
        /// Bit 1: an edit-history block follows the parapointers.
        public static let hasEditHistory = Special(rawValue: 0x0002)
        /// Bit 2: the row highlight bytes are valid.
        public static let hasRowHighlights = Special(rawValue: 0x0004)
        /// Bit 3: a MIDI macro configuration block is embedded.
        public static let hasMIDIConfiguration = Special(rawValue: 0x0008)
    }

    // MARK: Header

    /// Song name (26 bytes, CP437, trailing spaces trimmed).
    public let songName: String
    /// Song message (CP437; IT's CR line breaks converted to `\n`), or
    /// `nil` when absent or unreadable.
    public let message: String?
    /// `PHiligt` minor highlight: rows per beat.
    public let rowsPerBeat: UInt8
    /// `PHiligt` major highlight: rows per measure.
    public let rowsPerMeasure: UInt8
    /// `Cwt/v`: "created with tracker" version (0x0214 = IT 2.14).
    public let createdWith: UInt16
    /// `Cmwt`: lowest tracker version that can read the file. Values
    /// below 0x0200 select the IT 1.x instrument layout.
    public let compatibleWith: UInt16
    /// Header `Flags`.
    public let flags: Flags
    /// Header `Special` flags.
    public let special: Special
    /// `GV`: initial global volume, clamped to 0...128.
    public let globalVolume: UInt8
    /// `MV`: mix volume, clamped to 0...128.
    public let mixVolume: UInt8
    /// `IS`: initial speed (ticks per row). 0 in the file reads as 6.
    public let initialSpeed: UInt8
    /// `IT`: initial tempo (BPM, 31...255). Values below 31 read as 125.
    public let initialTempo: UInt8
    /// `Sep`: stereo separation, clamped to 0...128.
    public let panningSeparation: UInt8
    /// `PWD`: MIDI pitch wheel depth.
    public let pitchWheelDepth: UInt8
    /// Raw per-channel pan bytes (64): 0...64 = pan, 100 = surround,
    /// +128 = channel disabled (effects still run, output is muted).
    public let channelPan: [UInt8]
    /// Per-channel volume (64), clamped to 0...64.
    public let channelVolume: [UInt8]
    /// Order list. 0...199 are pattern numbers, 254 = skip ("+++"),
    /// 255 = end of song ("---").
    public let orders: [UInt8]
    /// Embedded MIDI macro configuration, or `nil` when the file has none
    /// (playback then uses ``ITMIDIConfiguration/impulseTrackerDefault``).
    public let midiConfiguration: ITMIDIConfiguration?

    // MARK: Content

    /// Instruments, in file order (instrument 1 is index 0).
    public let instruments: [ITInstrument]
    /// Samples, in file order (sample 1 is index 0).
    public let samples: [ITSample]
    /// Patterns, in file order. A zero parapointer yields an empty
    /// 64-row pattern.
    public let patterns: [ITPattern]

    // MARK: Convenience

    /// Instrument mode (header flag bit 2).
    public var usesInstruments: Bool { flags.contains(.useInstruments) }
    /// Linear slides (header flag bit 3).
    public var usesLinearSlides: Bool { flags.contains(.linearSlides) }
    /// Old effects (header flag bit 4).
    public var usesOldEffects: Bool { flags.contains(.oldEffects) }
    /// Compatible Gxx (header flag bit 5).
    public var linksPortamentoMemory: Bool { flags.contains(.linkedPortamentoMemory) }
    /// Stereo output (header flag bit 0).
    public var isStereo: Bool { flags.contains(.stereo) }
    /// Number of channels any pattern actually uses (highest used + 1).
    public var channelCount: Int { patterns.map(\.channelCount).max() ?? 0 }

    // MARK: Limits

    /// Ceiling on `rows x stored channels` summed over distinct patterns
    /// (8 Mi cells, about 64 MiB). Impulse Tracker's own maximum is
    /// 200 x 200 x 64 = 2.56 Mi.
    public static let maximumPatternCells = 8 * 1024 * 1024

    // MARK: - Parse

    /// Parse an Impulse Tracker module.
    ///
    /// Resource use is bounded by the input: decoded sample frames may
    /// not exceed `8 * data.count + 1 Mi`, and pattern cells may not
    /// exceed ``maximumPatternCells``. Parapointers that are shared
    /// between slots are decoded once.
    ///
    /// - Parameter data: The complete file contents. Slices are fine.
    /// - Throws: ``ITError`` describing the first structural problem.
    public init(data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    /// Parse an Impulse Tracker module from raw bytes.
    ///
    /// - Parameter bytes: The complete file contents.
    /// - Throws: ``ITError`` describing the first structural problem.
    public init(bytes: [UInt8]) throws {
        guard bytes.count >= 4,
              bytes[0] == 0x49, bytes[1] == 0x4D, bytes[2] == 0x50, bytes[3] == 0x4D else {
            throw ITError.notAnITFile
        }
        guard bytes.count >= 0xC0 else { throw ITError.truncatedHeader }

        songName = bytes.cp437String(at: 0x04, maxLength: 26)
        rowsPerBeat = bytes[0x1E]
        rowsPerMeasure = bytes[0x1F]

        let ordNum = Int(bytes.u16(0x20))
        let insNum = Int(bytes.u16(0x22))
        let smpNum = Int(bytes.u16(0x24))
        let patNum = Int(bytes.u16(0x26))

        createdWith = bytes.u16(0x28)
        compatibleWith = bytes.u16(0x2A)
        flags = Flags(rawValue: bytes.u16(0x2C))
        special = Special(rawValue: bytes.u16(0x2E))
        globalVolume = min(bytes[0x30], 128)
        mixVolume = min(bytes[0x31], 128)
        initialSpeed = bytes[0x32] == 0 ? 6 : bytes[0x32]
        initialTempo = bytes[0x33] < 31 ? 125 : bytes[0x33]
        panningSeparation = min(bytes[0x34], 128)
        pitchWheelDepth = bytes[0x35]
        let messageLength = Int(bytes.u16(0x36))
        let messageOffset = Int(bytes.u32(0x38))

        channelPan = Array(bytes[0x40..<0x80])
        channelVolume = bytes[0x80..<0xC0].map { min($0, 64) }

        // Order list and parapointer tables. All counts are 16-bit, so
        // this arithmetic cannot overflow.
        let ordersBase = 0xC0
        let insTable = ordersBase + ordNum
        let smpTable = insTable + insNum * 4
        let patTable = smpTable + smpNum * 4
        let tablesEnd = patTable + patNum * 4
        guard tablesEnd <= bytes.count else { throw ITError.truncatedHeader }

        orders = Array(bytes[ordersBase..<insTable])
        let insPtrs = (0..<insNum).map { Int(bytes.u32(insTable + $0 * 4)) }
        let smpPtrs = (0..<smpNum).map { Int(bytes.u32(smpTable + $0 * 4)) }
        let patPtrs = (0..<patNum).map { Int(bytes.u32(patTable + $0 * 4)) }

        // Song message.
        if special.contains(.hasMessage), messageLength > 0,
           messageOffset > 0, messageOffset < bytes.count {
            let available = min(messageLength, bytes.count - messageOffset)
            var scalars = String.UnicodeScalarView()
            for i in 0..<available {
                let b = bytes[messageOffset + i]
                if b == 0 { break }
                scalars.append(b == 0x0D ? "\n" : CP437.scalar(for: b))
            }
            message = String(scalars)
        } else {
            message = nil
        }

        // Edit history, then MIDI configuration.
        var cursor = tablesEnd
        if special.contains(.hasEditHistory), bytes.contains(offset: cursor, length: 2) {
            let entries = Int(bytes.u16(cursor))
            cursor += 2
            if bytes.contains(offset: cursor, length: entries * 8) { cursor += entries * 8 }
        }
        midiConfiguration = special.contains(.hasMIDIConfiguration)
            ? ITMIDIConfiguration.parse(bytes: bytes, at: cursor) : nil

        // Instruments.
        let oldFormat = compatibleWith < 0x0200
        var instrumentCache: [Int: ITInstrument] = [:]
        var ins: [ITInstrument] = []
        ins.reserveCapacity(insNum)
        for (i, ptr) in insPtrs.enumerated() {
            if ptr == 0 { ins.append(.empty); continue }
            if let hit = instrumentCache[ptr] { ins.append(hit); continue }
            let parsed = try ITInstrument.parse(bytes: bytes, at: ptr, index: i, oldFormat: oldFormat)
            instrumentCache[ptr] = parsed
            ins.append(parsed)
        }
        instruments = ins

        // Samples.
        var frameBudget = bytes.count.multipliedReportingOverflow(by: 8).partialValue + (1 << 20)
        var sampleCache: [ITSample.DecodeKey: ITSample.Decoded] = [:]
        var smp: [ITSample] = []
        smp.reserveCapacity(smpNum)
        for (i, ptr) in smpPtrs.enumerated() {
            if ptr == 0 { smp.append(.empty); continue }
            smp.append(try ITSample.parse(bytes: bytes, at: ptr, index: i, createdWith: createdWith,
                                          frameBudget: &frameBudget, cache: &sampleCache))
        }
        samples = smp

        // Patterns. Shared parapointers decode once (copy-on-write keeps
        // the duplicates free).
        var cellBudget = Self.maximumPatternCells
        var patternCache: [Int: ITPattern] = [:]
        var pats: [ITPattern] = []
        pats.reserveCapacity(patNum)
        for (i, ptr) in patPtrs.enumerated() {
            if ptr == 0 { pats.append(.empty(rows: 64)); continue }
            if let hit = patternCache[ptr] { pats.append(hit); continue }
            let parsed = try ITPattern.parse(bytes: bytes, at: ptr, index: i, cellBudget: &cellBudget)
            patternCache[ptr] = parsed
            pats.append(parsed)
        }
        patterns = pats
    }
}
