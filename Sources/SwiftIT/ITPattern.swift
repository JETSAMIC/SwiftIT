/// ITPattern.swift
///
/// Packed IT pattern decoding.

import Foundation

/// The note column of a pattern cell.
public enum ITNote: Sendable, Hashable {
    /// A playable note, 0...119 (C-0...B-9; C-5 is 60).
    case note(UInt8)
    /// Note off (`===`, byte 255): releases sustain loops.
    case off
    /// Note cut (`^^^`, byte 254): stops the note.
    case cut
    /// Note fade (`~~~`, bytes 120...253): starts the fadeout.
    case fade

    /// Decode a note byte from the packed stream.
    public init(rawValue: UInt8) {
        switch rawValue {
        case 0...119: self = .note(rawValue)
        case 255: self = .off
        case 254: self = .cut
        default: self = .fade
        }
    }
}

/// A decoded volume-column command. Parameters for the `a`...`j` style
/// commands are 0...9.
public enum ITVolumeCommand: Sendable, Hashable {
    /// 0...64: set note volume.
    case volume(UInt8)
    /// 65...74 (`a`): fine volume slide up on the first tick.
    case fineVolumeUp(UInt8)
    /// 75...84 (`b`): fine volume slide down on the first tick.
    case fineVolumeDown(UInt8)
    /// 85...94 (`c`): volume slide up every non-first tick.
    case volumeSlideUp(UInt8)
    /// 95...104 (`d`): volume slide down every non-first tick.
    case volumeSlideDown(UInt8)
    /// 105...114 (`e`): pitch slide down, shares memory with `Exx`/`Fxx`.
    case pitchSlideDown(UInt8)
    /// 115...124 (`f`): pitch slide up, shares memory with `Exx`/`Fxx`.
    case pitchSlideUp(UInt8)
    /// 128...192: set panning 0...64.
    case panning(UInt8)
    /// 193...202 (`g`): tone portamento with speed from the fixed table.
    case tonePortamento(UInt8)
    /// 203...212 (`h`): vibrato with depth 0...9.
    case vibratoDepth(UInt8)

    /// Decode a raw volume-column byte. Returns `nil` for the unused
    /// ranges 125...127 and 213...255.
    public init?(rawValue v: UInt8) {
        switch v {
        case 0...64: self = .volume(v)
        case 65...74: self = .fineVolumeUp(v - 65)
        case 75...84: self = .fineVolumeDown(v - 75)
        case 85...94: self = .volumeSlideUp(v - 85)
        case 95...104: self = .volumeSlideDown(v - 95)
        case 105...114: self = .pitchSlideDown(v - 105)
        case 115...124: self = .pitchSlideUp(v - 115)
        case 128...192: self = .panning(v - 128)
        case 193...202: self = .tonePortamento(v - 193)
        case 203...212: self = .vibratoDepth(v - 203)
        default: return nil
        }
    }
}

/// One unpacked IT pattern.
///
/// Storage is dense but only as wide as the highest channel the pattern
/// uses (``channelCount``). Reading any channel 0...63 (or any
/// out-of-range coordinate) through ``subscript(row:channel:)`` is safe
/// and returns ``Cell/empty`` where nothing is stored.
public struct ITPattern: Sendable, Equatable {

    /// One cell of the pattern grid.
    public struct Cell: Sendable, Hashable {
        /// Note column, or `nil` when empty.
        public let note: ITNote?
        /// Instrument (instrument mode) or sample (sample mode) number,
        /// 1-based; 0 when empty.
        public let instrument: UInt8
        /// Raw volume-column byte, or `nil` when empty. See
        /// ``volumeCommand`` for the decoded form.
        public let volume: UInt8?
        /// Effect command: 0 = none, 1...26 = `A`...`Z`.
        public let effect: UInt8
        /// Effect parameter.
        public let effectParameter: UInt8

        /// Creates a cell.
        public init(note: ITNote? = nil, instrument: UInt8 = 0, volume: UInt8? = nil,
                    effect: UInt8 = 0, effectParameter: UInt8 = 0) {
            self.note = note
            self.instrument = instrument
            self.volume = volume
            self.effect = effect
            self.effectParameter = effectParameter
        }

        /// An empty cell.
        public static let empty = Cell()

        /// The volume column decoded into a command, if any.
        public var volumeCommand: ITVolumeCommand? {
            volume.flatMap(ITVolumeCommand.init(rawValue:))
        }

        /// The effect letter (`"A"`...`"Z"`), or `nil` for no effect or
        /// an out-of-range command byte.
        public var effectLetter: Character? {
            guard effect >= 1 && effect <= 26 else { return nil }
            return Character(Unicode.Scalar(UInt8(64) + effect))
        }
    }

    /// Number of rows (1...1024).
    public let rowCount: Int
    /// Number of stored channels: the highest channel used plus one
    /// (0 for an empty pattern). IT always has 64 logical channels.
    public let channelCount: Int
    /// Row-major cells, `rowCount * channelCount` long.
    let cells: [Cell]

    /// Cell at (`row`, `channel`), or ``Cell/empty`` when out of range.
    public subscript(row row: Int, channel channel: Int) -> Cell {
        guard row >= 0, row < rowCount, channel >= 0, channel < channelCount else { return .empty }
        return cells[row * channelCount + channel]
    }

    /// An empty pattern with `rows` rows (IT uses 64 for missing patterns).
    public static func empty(rows: Int) -> ITPattern {
        ITPattern(rowCount: max(rows, 1), channelCount: 0, cells: [])
    }

    /// Maximum rows accepted (OpenMPT's limit; IT itself writes 32...200).
    static let maximumRows = 1024

    /// Decode the packed stream at `base` (8-byte header first).
    ///
    /// Packed stream per ITTECH.TXT: a channel byte (0 = end of row;
    /// channel = `(byte - 1) & 63`; bit 7 = a new mask byte follows),
    /// then fields selected by the mask: 1 note, 2 instrument,
    /// 4 volume, 8 command + parameter, 16/32/64/128 = reuse the
    /// channel's last note / instrument / volume / command.
    static func parse(bytes: [UInt8], at base: Int, index: Int, cellBudget: inout Int) throws -> ITPattern {
        guard bytes.contains(offset: base, length: 8) else {
            throw ITError.invalidOffset(.pattern, index: index, offset: base)
        }
        let length = Int(bytes.u16(base))
        let rows = Int(bytes.u16(base + 2))
        guard rows >= 1 && rows <= maximumRows else { throw ITError.invalidPattern(index: index) }
        let start = base + 8
        guard bytes.contains(offset: start, length: length) else {
            throw ITError.invalidOffset(.pattern, index: index, offset: base)
        }
        let end = start + length

        // Pass 1 decodes into sparse (row, channel, cell) entries and
        // finds the widest channel, so storage only covers channels used.
        var entries: [(row: Int, channel: Int, cell: Cell)] = []
        var maxChannel = -1

        var lastMask = [UInt8](repeating: 0, count: 64)
        var lastNote = [UInt8](repeating: 0, count: 64)
        var lastInstrument = [UInt8](repeating: 0, count: 64)
        var lastVolume = [UInt8](repeating: 0, count: 64)
        var lastEffect = [UInt8](repeating: 0, count: 64)
        var lastParam = [UInt8](repeating: 0, count: 64)

        var cursor = start
        var row = 0

        func next() throws -> UInt8 {
            guard cursor < end else { throw ITError.invalidPattern(index: index) }
            defer { cursor += 1 }
            return bytes[cursor]
        }

        while row < rows && cursor < end {
            let channelByte = bytes[cursor]
            cursor += 1
            if channelByte == 0 {
                row += 1
                continue
            }
            let channel = (Int(channelByte) - 1) & 63
            var mask = lastMask[channel]
            if channelByte & 0x80 != 0 {
                mask = try next()
                lastMask[channel] = mask
            }

            var note: ITNote? = nil
            var instrument: UInt8 = 0
            var volume: UInt8? = nil
            var effect: UInt8 = 0
            var param: UInt8 = 0

            if mask & 0x01 != 0 {
                let n = try next()
                lastNote[channel] = n
                note = ITNote(rawValue: n)
            }
            if mask & 0x02 != 0 {
                instrument = try next()
                lastInstrument[channel] = instrument
            }
            if mask & 0x04 != 0 {
                let v = try next()
                lastVolume[channel] = v
                volume = v
            }
            if mask & 0x08 != 0 {
                effect = try next()
                param = try next()
                lastEffect[channel] = effect
                lastParam[channel] = param
            }
            if mask & 0x10 != 0 { note = ITNote(rawValue: lastNote[channel]) }
            if mask & 0x20 != 0 { instrument = lastInstrument[channel] }
            if mask & 0x40 != 0 { volume = lastVolume[channel] }
            if mask & 0x80 != 0 {
                effect = lastEffect[channel]
                param = lastParam[channel]
            }

            let cell = Cell(note: note, instrument: instrument, volume: volume,
                            effect: effect, effectParameter: param)
            if cell != .empty {
                entries.append((row, channel, cell))
                maxChannel = max(maxChannel, channel)
            }
        }

        let width = maxChannel + 1
        let cellCount = rows * width
        cellBudget -= cellCount
        guard cellBudget >= 0 else { throw ITError.limitExceeded(.patternCells) }

        var cells = [Cell](repeating: .empty, count: cellCount)
        for e in entries {
            cells[e.row * width + e.channel] = e.cell
        }
        return ITPattern(rowCount: rows, channelCount: width, cells: cells)
    }
}
