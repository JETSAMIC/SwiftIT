/// ITInstrument.swift
///
/// `IMPI` instruments in both on-disk layouts (IT 1.x "old" format for
/// `Cmwt < 0x200`, IT 2.x "new" format otherwise) and their envelopes.

import Foundation

// MARK: - Envelope

/// A volume, panning, or pitch/filter envelope.
///
/// The parser sanitizes envelopes so the mixer can evaluate them without
/// further checks: at most 25 nodes, ticks never decrease, loop and
/// sustain indices are clamped into the node range with `start <= end`,
/// and node values are clamped (0...64 for volume, -32...32 otherwise).
public struct ITEnvelope: Sendable, Hashable {

    /// One envelope point.
    public struct Node: Sendable, Hashable {
        /// Node value: 0...64 for volume envelopes, -32...32 for panning
        /// and pitch/filter envelopes.
        public let value: Int8
        /// Position in ticks (0...9999 in files written by IT).
        public let tick: UInt16

        /// Creates an envelope node.
        public init(value: Int8, tick: UInt16) {
            self.value = value
            self.tick = tick
        }
    }

    /// Bit 0: the envelope is enabled.
    public let isEnabled: Bool
    /// Bit 1: the loop between ``loopStart`` and ``loopEnd`` is enabled.
    public let hasLoop: Bool
    /// Bit 2: the sustain loop is enabled.
    public let hasSustainLoop: Bool
    /// Bit 3 (Schism/OpenMPT extension): envelope carry. A new note with
    /// the same instrument continues from the previous note's position.
    public let carry: Bool
    /// Bit 7 (pitch envelope only): the envelope drives the filter cutoff
    /// instead of pitch.
    public let isFilter: Bool
    /// Loop start node index.
    public let loopStart: Int
    /// Loop end node index (inclusive).
    public let loopEnd: Int
    /// Sustain loop start node index.
    public let sustainStart: Int
    /// Sustain loop end node index (inclusive).
    public let sustainEnd: Int
    /// Nodes in tick order.
    public let nodes: [Node]

    /// A disabled envelope with no nodes.
    public static let empty = ITEnvelope(
        isEnabled: false, hasLoop: false, hasSustainLoop: false, carry: false, isFilter: false,
        loopStart: 0, loopEnd: 0, sustainStart: 0, sustainEnd: 0, nodes: []
    )

    /// Creates an envelope, applying the same sanitization as the parser.
    public init(
        isEnabled: Bool, hasLoop: Bool, hasSustainLoop: Bool, carry: Bool, isFilter: Bool,
        loopStart: Int, loopEnd: Int, sustainStart: Int, sustainEnd: Int, nodes: [Node]
    ) {
        var cleaned: [Node] = []
        cleaned.reserveCapacity(min(nodes.count, 25))
        var lastTick: UInt16 = 0
        for node in nodes.prefix(25) {
            let tick = max(node.tick, lastTick)
            cleaned.append(Node(value: node.value, tick: tick))
            lastTick = tick
        }
        let last = max(cleaned.count - 1, 0)
        func clampPair(_ a: Int, _ b: Int) -> (Int, Int) {
            let s = min(max(a, 0), last)
            let e = min(max(b, s), last)
            return (s, e)
        }
        let (ls, le) = clampPair(loopStart, loopEnd)
        let (ss, se) = clampPair(sustainStart, sustainEnd)
        self.isEnabled = isEnabled && !cleaned.isEmpty
        self.hasLoop = hasLoop
        self.hasSustainLoop = hasSustainLoop
        self.carry = carry
        self.isFilter = isFilter
        self.loopStart = ls
        self.loopEnd = le
        self.sustainStart = ss
        self.sustainEnd = se
        self.nodes = cleaned
    }

    /// Parse an 82-byte new-format envelope.
    static func parse(bytes: [UInt8], at base: Int, isVolume: Bool, allowFilter: Bool) -> ITEnvelope {
        let flags = bytes.u8(base)
        let count = min(Int(bytes.u8(base + 1)), 25)
        var nodes: [Node] = []
        nodes.reserveCapacity(count)
        for i in 0..<count {
            let p = base + 6 + i * 3
            var v = Int(Int8(bitPattern: bytes.u8(p)))
            v = isVolume ? min(max(v, 0), 64) : min(max(v, -32), 32)
            nodes.append(Node(value: Int8(v), tick: bytes.u16(p + 1)))
        }
        return ITEnvelope(
            isEnabled: flags & 0x01 != 0,
            hasLoop: flags & 0x02 != 0,
            hasSustainLoop: flags & 0x04 != 0,
            carry: flags & 0x08 != 0,
            isFilter: allowFilter && flags & 0x80 != 0,
            loopStart: Int(bytes.u8(base + 2)),
            loopEnd: Int(bytes.u8(base + 3)),
            sustainStart: Int(bytes.u8(base + 4)),
            sustainEnd: Int(bytes.u8(base + 5)),
            nodes: nodes
        )
    }

    /// Envelope value at `tick`, linearly interpolated between nodes.
    /// Before the first node the first value is returned; after the
    /// last node, the last value.
    public func value(atTick tick: Int) -> Double {
        guard let first = nodes.first, let lastNode = nodes.last else { return 0 }
        if tick <= Int(first.tick) { return Double(first.value) }
        if tick >= Int(lastNode.tick) { return Double(lastNode.value) }
        var i = 0
        while i + 1 < nodes.count && Int(nodes[i + 1].tick) <= tick { i += 1 }
        let a = nodes[i]
        let b = nodes[min(i + 1, nodes.count - 1)]
        let span = Int(b.tick) - Int(a.tick)
        guard span > 0 else { return Double(b.value) }
        let t = Double(tick - Int(a.tick)) / Double(span)
        return Double(a.value) + (Double(b.value) - Double(a.value)) * t
    }
}

// MARK: - Instrument

/// An Impulse Tracker instrument (`IMPI`).
///
/// Old-format (IT 1.x) instruments are converted on load into this
/// shape: their fadeout is doubled into new-format units, the
/// duplicate-note-check flag becomes ``DuplicateCheckType/note`` with
/// ``DuplicateCheckAction/cut``, and the node list becomes the volume
/// envelope. ``isOldFormat`` records where the data came from.
public struct ITInstrument: Sendable, Equatable {

    /// New Note Action (`NNA`): what happens to a playing note when a
    /// new note starts on the same channel.
    public enum NewNoteAction: UInt8, Sendable, Hashable {
        /// Stop the old note.
        case cut = 0
        /// Keep playing the old note in the background.
        case `continue` = 1
        /// Send note-off to the old note (releases sustain loops).
        case noteOff = 2
        /// Start fading the old note out.
        case noteFade = 3
    }

    /// Duplicate Check Type (`DCT`).
    public enum DuplicateCheckType: UInt8, Sendable, Hashable {
        /// No duplicate check.
        case off = 0
        /// Same note (and instrument).
        case note = 1
        /// Same sample (and instrument).
        case sample = 2
        /// Same instrument.
        case instrument = 3
    }

    /// Duplicate Check Action (`DCA`).
    public enum DuplicateCheckAction: UInt8, Sendable, Hashable {
        /// Stop the duplicate.
        case cut = 0
        /// Send note-off to the duplicate.
        case noteOff = 1
        /// Fade the duplicate out.
        case noteFade = 2
    }

    /// One keyboard (note-to-sample) table entry.
    public struct KeyboardEntry: Sendable, Hashable {
        /// Note actually played, 0...119 (C-0...B-9).
        public let note: UInt8
        /// 1-based sample number; 0 means "no sample".
        public let sample: UInt8

        /// Creates a keyboard entry.
        public init(note: UInt8, sample: UInt8) {
            self.note = note
            self.sample = sample
        }
    }

    /// Instrument name (26 bytes, CP437).
    public let name: String
    /// DOS file name (12 bytes, CP437).
    public let fileName: String
    /// New Note Action. Out-of-range bytes read as ``NewNoteAction/cut``.
    public let newNoteAction: NewNoteAction
    /// Duplicate Check Type. Out-of-range bytes read as ``DuplicateCheckType/off``.
    public let duplicateCheckType: DuplicateCheckType
    /// Duplicate Check Action. Out-of-range bytes read as ``DuplicateCheckAction/cut``.
    public let duplicateCheckAction: DuplicateCheckAction
    /// Fadeout amount subtracted per tick from a 1024-unit fade counter
    /// once the note is released (new-format units, 0...1024).
    public let fadeOut: UInt16
    /// `GbV`: instrument global volume, clamped to 0...128.
    public let globalVolume: UInt8
    /// `DfP`: default pan 0...64, or `nil` when bit 7 ("don't use") is set.
    public let defaultPan: UInt8?
    /// `PPS`: pitch-pan separation, -32...32.
    public let pitchPanSeparation: Int8
    /// `PPC`: pitch-pan center note, 0...119.
    public let pitchPanCenter: UInt8
    /// `RV`: random volume variation, percent (0...100).
    public let randomVolume: UInt8
    /// `RP`: random panning variation (0...64).
    public let randomPan: UInt8
    /// `IFC`: initial filter cutoff 0...127, or `nil` when bit 7 is clear.
    public let initialFilterCutoff: UInt8?
    /// `IFR`: initial filter resonance 0...127, or `nil` when bit 7 is clear.
    public let initialFilterResonance: UInt8?
    /// `MCh`: MIDI channel (raw; 0 = off).
    public let midiChannel: UInt8
    /// `MPr`: MIDI program (raw; 255 = off).
    public let midiProgram: UInt8
    /// `MIDIBnk`: MIDI bank (raw; 0xFFFF = off).
    public let midiBank: UInt16
    /// The 120-entry keyboard table, indexed by played note 0...119.
    /// Notes above 119 in the file are replaced with the key itself.
    public let keyboard: [KeyboardEntry]
    /// Volume envelope (values 0...64).
    public let volumeEnvelope: ITEnvelope
    /// Panning envelope (values -32...32). Always disabled for old-format
    /// instruments.
    public let panningEnvelope: ITEnvelope
    /// Pitch envelope (values -32...32, in half-semitones), or filter
    /// envelope when ``ITEnvelope/isFilter`` is set. Always disabled for
    /// old-format instruments.
    public let pitchEnvelope: ITEnvelope
    /// `true` when loaded from the IT 1.x layout (`Cmwt < 0x200`).
    public let isOldFormat: Bool

    /// An empty instrument slot (zero parapointer).
    public static let empty = ITInstrument(
        name: "", fileName: "", newNoteAction: .cut, duplicateCheckType: .off,
        duplicateCheckAction: .cut, fadeOut: 0, globalVolume: 128, defaultPan: nil,
        pitchPanSeparation: 0, pitchPanCenter: 60, randomVolume: 0, randomPan: 0,
        initialFilterCutoff: nil, initialFilterResonance: nil,
        midiChannel: 0, midiProgram: 255, midiBank: 0xFFFF,
        keyboard: (0..<120).map { KeyboardEntry(note: UInt8($0), sample: 0) },
        volumeEnvelope: .empty, panningEnvelope: .empty, pitchEnvelope: .empty,
        isOldFormat: false
    )

    init(
        name: String, fileName: String, newNoteAction: NewNoteAction,
        duplicateCheckType: DuplicateCheckType, duplicateCheckAction: DuplicateCheckAction,
        fadeOut: UInt16, globalVolume: UInt8, defaultPan: UInt8?, pitchPanSeparation: Int8,
        pitchPanCenter: UInt8, randomVolume: UInt8, randomPan: UInt8,
        initialFilterCutoff: UInt8?, initialFilterResonance: UInt8?,
        midiChannel: UInt8, midiProgram: UInt8, midiBank: UInt16,
        keyboard: [KeyboardEntry], volumeEnvelope: ITEnvelope, panningEnvelope: ITEnvelope,
        pitchEnvelope: ITEnvelope, isOldFormat: Bool
    ) {
        self.name = name
        self.fileName = fileName
        self.newNoteAction = newNoteAction
        self.duplicateCheckType = duplicateCheckType
        self.duplicateCheckAction = duplicateCheckAction
        self.fadeOut = fadeOut
        self.globalVolume = globalVolume
        self.defaultPan = defaultPan
        self.pitchPanSeparation = pitchPanSeparation
        self.pitchPanCenter = pitchPanCenter
        self.randomVolume = randomVolume
        self.randomPan = randomPan
        self.initialFilterCutoff = initialFilterCutoff
        self.initialFilterResonance = initialFilterResonance
        self.midiChannel = midiChannel
        self.midiProgram = midiProgram
        self.midiBank = midiBank
        self.keyboard = keyboard
        self.volumeEnvelope = volumeEnvelope
        self.panningEnvelope = panningEnvelope
        self.pitchEnvelope = pitchEnvelope
        self.isOldFormat = isOldFormat
    }

    /// Size of both instrument layouts on disk.
    static let headerSize = 554

    static func parseKeyboard(bytes: [UInt8], at base: Int) -> [KeyboardEntry] {
        (0..<120).map { i in
            let note = bytes.u8(base + i * 2)
            return KeyboardEntry(note: note < 120 ? note : UInt8(i), sample: bytes.u8(base + i * 2 + 1))
        }
    }

    /// Parse an instrument at `base`. `oldFormat` comes from the file's
    /// `Cmwt < 0x200`.
    static func parse(bytes: [UInt8], at base: Int, index: Int, oldFormat: Bool) throws -> ITInstrument {
        guard bytes.contains(offset: base, length: headerSize) else {
            throw ITError.invalidOffset(.instrument, index: index, offset: base)
        }
        guard bytes[base] == 0x49, bytes[base + 1] == 0x4D,
              bytes[base + 2] == 0x50, bytes[base + 3] == 0x49 else {
            throw ITError.invalidInstrumentHeader(index: index)
        }
        return oldFormat ? parseOld(bytes: bytes, at: base) : parseNew(bytes: bytes, at: base)
    }

    /// IT 2.x layout.
    static func parseNew(bytes: [UInt8], at base: Int) -> ITInstrument {
        let dfp = bytes.u8(base + 0x19)
        let ifc = bytes.u8(base + 0x3A)
        let ifr = bytes.u8(base + 0x3B)
        let pps = min(max(Int(Int8(bitPattern: bytes.u8(base + 0x16))), -32), 32)
        return ITInstrument(
            name: bytes.cp437String(at: base + 0x20, maxLength: 26),
            fileName: bytes.cp437String(at: base + 0x04, maxLength: 12),
            newNoteAction: NewNoteAction(rawValue: bytes.u8(base + 0x11)) ?? .cut,
            duplicateCheckType: DuplicateCheckType(rawValue: bytes.u8(base + 0x12)) ?? .off,
            duplicateCheckAction: DuplicateCheckAction(rawValue: bytes.u8(base + 0x13)) ?? .cut,
            fadeOut: min(bytes.u16(base + 0x14), 1024),
            globalVolume: min(bytes.u8(base + 0x18), 128),
            defaultPan: dfp & 0x80 == 0 ? min(dfp, 64) : nil,
            pitchPanSeparation: Int8(pps),
            pitchPanCenter: min(bytes.u8(base + 0x17), 119),
            randomVolume: min(bytes.u8(base + 0x1A), 100),
            randomPan: min(bytes.u8(base + 0x1B), 64),
            initialFilterCutoff: ifc & 0x80 != 0 ? ifc & 0x7F : nil,
            initialFilterResonance: ifr & 0x80 != 0 ? ifr & 0x7F : nil,
            midiChannel: bytes.u8(base + 0x3C),
            midiProgram: bytes.u8(base + 0x3D),
            midiBank: bytes.u16(base + 0x3E),
            keyboard: parseKeyboard(bytes: bytes, at: base + 0x40),
            volumeEnvelope: ITEnvelope.parse(bytes: bytes, at: base + 0x130, isVolume: true, allowFilter: false),
            panningEnvelope: ITEnvelope.parse(bytes: bytes, at: base + 0x182, isVolume: false, allowFilter: false),
            pitchEnvelope: ITEnvelope.parse(bytes: bytes, at: base + 0x1D4, isVolume: false, allowFilter: true),
            isOldFormat: false
        )
    }

    /// IT 1.x layout:
    /// ```
    /// 0x00 IMPI  0x04 filename[12]  0x11 Flg  0x12 VLS  0x13 VLE
    /// 0x14 SLS   0x15 SLE  0x18 FadeOut(u16, 0...64)  0x1A NNA  0x1B DNC
    /// 0x1C TrkVers  0x1E NoS  0x20 name[26]  0x40 keyboard[240]
    /// 0x130 precomputed volume curve[200]  0x1F8 nodes[25] (tick, value)
    /// ```
    static func parseOld(bytes: [UInt8], at base: Int) -> ITInstrument {
        let flags = bytes.u8(base + 0x11)
        var nodes: [ITEnvelope.Node] = []
        for i in 0..<25 {
            let p = base + 0x1F8 + i * 2
            let tick = bytes.u8(p)
            if tick == 0xFF { break }
            nodes.append(ITEnvelope.Node(value: Int8(min(bytes.u8(p + 1), 64)), tick: UInt16(tick)))
        }
        let volEnv = ITEnvelope(
            isEnabled: flags & 0x01 != 0,
            hasLoop: flags & 0x02 != 0,
            hasSustainLoop: flags & 0x04 != 0,
            carry: false, isFilter: false,
            loopStart: Int(bytes.u8(base + 0x12)),
            loopEnd: Int(bytes.u8(base + 0x13)),
            sustainStart: Int(bytes.u8(base + 0x14)),
            sustainEnd: Int(bytes.u8(base + 0x15)),
            nodes: nodes
        )
        let dnc = bytes.u8(base + 0x1B) != 0
        return ITInstrument(
            name: bytes.cp437String(at: base + 0x20, maxLength: 26),
            fileName: bytes.cp437String(at: base + 0x04, maxLength: 12),
            newNoteAction: NewNoteAction(rawValue: bytes.u8(base + 0x1A)) ?? .cut,
            duplicateCheckType: dnc ? .note : .off,
            duplicateCheckAction: .cut,
            // Old fadeout runs 0...64 against a 512 count; doubling puts
            // it on the new format's 1024 scale.
            fadeOut: min(bytes.u16(base + 0x18), 512) * 2,
            globalVolume: 128,
            defaultPan: nil,
            pitchPanSeparation: 0,
            pitchPanCenter: 60,
            randomVolume: 0,
            randomPan: 0,
            initialFilterCutoff: nil,
            initialFilterResonance: nil,
            midiChannel: 0,
            midiProgram: 255,
            midiBank: 0xFFFF,
            keyboard: parseKeyboard(bytes: bytes, at: base + 0x40),
            volumeEnvelope: volEnv,
            panningEnvelope: .empty,
            pitchEnvelope: .empty,
            isOldFormat: true
        )
    }
}
