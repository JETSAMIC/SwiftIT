/// ITFileTests.swift
///
/// Parser coverage built from hand-assembled bytes (see ITBuilder and
/// Reference/IT-Format.md).

import Testing
import Foundation
@testable import SwiftIT

@Suite("ITFile parser")
struct ITFileTests {

    // MARK: Header

    @Test("Rejects data missing the IMPM magic")
    func rejectsNonImpm() {
        #expect(throws: ITError.notAnITFile) { _ = try ITFile(data: Data(count: 256)) }
        #expect(throws: ITError.notAnITFile) { _ = try ITFile(data: Data()) }
    }

    @Test("Rejects a header shorter than 192 bytes")
    func shortHeader() {
        var d = [UInt8](repeating: 0, count: 100)
        d.replaceSubrange(0..<4, with: Array("IMPM".utf8))
        #expect(throws: ITError.truncatedHeader) { _ = try ITFile(bytes: d) }
    }

    @Test("Reads header fields from a hand-built file")
    func readsHeader() throws {
        var data = Data(count: 0x100)
        data[0] = 0x49; data[1] = 0x4D; data[2] = 0x50; data[3] = 0x4D
        for (i, byte) in "Test".utf8.enumerated() { data[0x04 + i] = byte }
        data[0x1E] = 4; data[0x1F] = 16
        data[0x20] = 1
        data[0x28] = 0x14; data[0x29] = 0x02
        data[0x2A] = 0x00; data[0x2B] = 0x02
        data[0x2C] = 0x0D
        data[0x30] = 200            // clamped to 128
        data[0x32] = 6; data[0x33] = 125; data[0x34] = 64
        data[0x40] = 0xA0           // disabled channel, pan 32
        data[0x80] = 99             // clamped to 64
        data[0xC0] = 255

        let file = try ITFile(data: data)
        #expect(file.songName == "Test")
        #expect(file.orders == [255])
        #expect(file.createdWith == 0x0214)
        #expect(file.compatibleWith == 0x0200)
        #expect(file.flags == [.stereo, .useInstruments, .linearSlides])
        #expect(file.usesLinearSlides && file.usesInstruments && file.isStereo && !file.usesOldEffects)
        #expect(file.initialSpeed == 6)
        #expect(file.initialTempo == 125)
        #expect(file.globalVolume == 128)
        #expect(file.panningSeparation == 64)
        #expect(file.rowsPerBeat == 4 && file.rowsPerMeasure == 16)
        #expect(file.channelPan[0] == 0xA0)
        #expect(file.channelVolume[0] == 64)
        #expect(file.message == nil)
    }

    @Test("Parses a slice of a larger Data without index traps")
    func dataSlice() throws {
        let bytes = ITBuilder().build()
        let padded = Data([1, 2, 3] + bytes)
        let file = try ITFile(data: padded[3...])
        #expect(file.songName == "Test")
    }

    @Test("Zero speed / low tempo fall back to IT defaults")
    func defaultsForZeroSpeed() throws {
        var b = ITBuilder()
        b.speed = 0
        b.tempo = 10
        let file = try ITFile(bytes: b.build())
        #expect(file.initialSpeed == 6)
        #expect(file.initialTempo == 125)
    }

    @Test("Song names and messages decode as CP437; CR becomes newline")
    func cp437AndMessage() throws {
        var b = ITBuilder()
        b.songName = "Cafe"
        var bytes = b.build()
        bytes[7] = 0x82   // CP437 0x82 = é
        var file = try ITFile(bytes: bytes)
        #expect(file.songName == "Café")

        b = ITBuilder()
        b.special = 0x0001
        b.message = Array("line1\rline2 \u{B0}".utf8.filter { $0 < 0x80 }) + [0xB0, 0]
        file = try ITFile(bytes: b.build())
        #expect(file.message == "line1\nline2 ░")
    }

    @Test("Truncated parapointer tables throw")
    func truncatedTables() {
        var b = ITBuilder()
        b.patterns = [ITBuilder.pattern(rows: 1, [])]
        let bytes = b.build()
        // Cut inside the pattern pointer table (orders end at 0xC2).
        #expect(throws: ITError.truncatedHeader) { _ = try ITFile(bytes: Array(bytes.prefix(0xC4))) }
    }

    // MARK: Patterns

    @Test("Empty-pattern parapointer (0) yields a silent 64-row pattern")
    func emptyPatternPointer() throws {
        var b = ITBuilder()
        b.patterns = [nil]
        let file = try ITFile(bytes: b.build())
        #expect(file.patterns.count == 1)
        #expect(file.patterns[0].rowCount == 64)
        #expect(file.patterns[0][row: 0, channel: 0] == .empty)
    }

    @Test("Pattern unpacking honours mask memory, value memory, and (b-1)&63")
    func patternMemory() throws {
        // Row 0, channel 1: mask 0x0F with note C-5, ins 2, vol 40, effect A06.
        // Row 1, channel 1: no mask byte (reuse 0x0F) -> new values.
        // Row 2, channel 1: mask 0xF0 -> replay last note/ins/vol/effect.
        // Row 3, channel byte 0xC2 = (0x42 - 1) & 63 = channel 1 with mask 0x01, note 255 (off).
        // Row 4: note 254 (cut), then note 130 (fade) on channel 2.
        let packed: [UInt8] = [
            0x82, 0x0F, 60, 2, 40, 1, 6, 0,
            0x02, 61, 3, 41, 4, 0x10, 0,
            0x82, 0xF0, 0,
            0xC2, 0x01, 255, 0,
            0x82, 0x01, 254, 0x83, 0x01, 130, 0,
        ]
        var b = ITBuilder()
        b.patterns = [ITBuilder.rawPattern(rows: 6, packed)]
        let p = try ITFile(bytes: b.build()).patterns[0]
        #expect(p.rowCount == 6)
        #expect(p.channelCount == 3)
        #expect(p[row: 0, channel: 1] == .init(note: .note(60), instrument: 2, volume: 40, effect: 1, effectParameter: 6))
        #expect(p[row: 1, channel: 1] == .init(note: .note(61), instrument: 3, volume: 41, effect: 4, effectParameter: 0x10))
        #expect(p[row: 2, channel: 1] == .init(note: .note(61), instrument: 3, volume: 41, effect: 4, effectParameter: 0x10))
        #expect(p[row: 3, channel: 1].note == .off)
        #expect(p[row: 4, channel: 1].note == .cut)
        #expect(p[row: 4, channel: 2].note == .fade)
        #expect(p[row: 5, channel: 1] == .empty)
        #expect(p[row: 0, channel: 0] == .empty)
        #expect(p[row: 99, channel: 99] == .empty)
        #expect(p[row: 0, channel: 1].effectLetter == "A")
        #expect(p[row: 0, channel: 1].volumeCommand == .volume(40))
    }

    @Test("Volume column decodes into commands")
    func volumeColumn() {
        #expect(ITVolumeCommand(rawValue: 64) == .volume(64))
        #expect(ITVolumeCommand(rawValue: 65) == .fineVolumeUp(0))
        #expect(ITVolumeCommand(rawValue: 84) == .fineVolumeDown(9))
        #expect(ITVolumeCommand(rawValue: 90) == .volumeSlideUp(5))
        #expect(ITVolumeCommand(rawValue: 104) == .volumeSlideDown(9))
        #expect(ITVolumeCommand(rawValue: 105) == .pitchSlideDown(0))
        #expect(ITVolumeCommand(rawValue: 124) == .pitchSlideUp(9))
        #expect(ITVolumeCommand(rawValue: 125) == nil)
        #expect(ITVolumeCommand(rawValue: 160) == .panning(32))
        #expect(ITVolumeCommand(rawValue: 193) == .tonePortamento(0))
        #expect(ITVolumeCommand(rawValue: 212) == .vibratoDepth(9))
        #expect(ITVolumeCommand(rawValue: 213) == nil)
    }

    @Test("Pattern with 0 rows, > 1024 rows, or a stream ending mid-entry throws")
    func invalidPatterns() {
        for raw in [
            ITBuilder.rawPattern(rows: 0, [0]),
            ITBuilder.rawPattern(rows: 1025, [0]),
            ITBuilder.rawPattern(rows: 4, [0x81, 0x0F, 60]),   // mask asks for 5 bytes, 1 present
        ] {
            var b = ITBuilder()
            b.patterns = [raw]
            #expect(throws: ITError.invalidPattern(index: 0)) { _ = try ITFile(bytes: b.build()) }
        }
    }

    @Test("Pattern data length past end of file throws invalidOffset")
    func patternPastEOF() {
        var b = ITBuilder()
        b.patterns = [ITBuilder.rawPattern(rows: 4, [0, 0, 0, 0])]
        var bytes = b.build()
        bytes.removeLast(2)
        #expect(throws: ITError.self) { _ = try ITFile(bytes: bytes) }
    }

    @Test("Shared pattern parapointers decode once and compare equal")
    func sharedPatternPointer() throws {
        var b = ITBuilder()
        b.patterns = [ITBuilder.pattern(rows: 2, [CellSpec(row: 0, channel: 0, note: 60)])]
        var bytes = b.build()
        // Duplicate the pointer: rebuild with two pattern slots, second
        // pointing to the first.
        b.patterns.append(nil)
        bytes = b.build()
        let patTable = 0xC0 + b.orders.count
        bytes.replaceSubrange(patTable + 4..<patTable + 8, with: bytes[patTable..<patTable + 4])
        let file = try ITFile(bytes: bytes)
        #expect(file.patterns[0] == file.patterns[1])
    }

    // MARK: Samples

    @Test("8-bit signed, unsigned and delta samples decode (delta wraps at 8 bits)")
    func eightBitSamples() throws {
        var b = ITBuilder()
        b.samples = [
            SampleSpec(cvt: 0x01, length: 3, data: [0x7F, 0x80, 0x00]),
            SampleSpec(cvt: 0x00, length: 3, data: [0xFF, 0x00, 0x80]),
            SampleSpec(cvt: 0x05, length: 3, data: [0x7F, 0x02, 0xFE]),
        ]
        let s = try ITFile(bytes: b.build()).samples
        #expect(s[0].pcm == [127 << 8, -128 << 8, 0])
        #expect(s[1].pcm == [127 << 8, -128 << 8, 0])
        // 0x7F, 0x7F+2 = 0x81 (-127), 0x81-2 = 0x7F
        #expect(s[2].pcm == [127 << 8, -127 << 8, 127 << 8])
        #expect(!s[0].isTruncated)
    }

    @Test("16-bit little/big endian and delta samples decode")
    func sixteenBitSamples() throws {
        var b = ITBuilder()
        b.samples = [
            SampleSpec(flags: 0x03, cvt: 0x01, length: 2, data: [0x34, 0x12, 0x00, 0x80]),
            SampleSpec(flags: 0x03, cvt: 0x03, length: 2, data: [0x12, 0x34, 0x80, 0x00]),
            SampleSpec(flags: 0x03, cvt: 0x05, length: 2, data: [0xFF, 0x7F, 0x02, 0x00]),
            SampleSpec(flags: 0x03, cvt: 0x00, length: 1, data: [0x00, 0x00]),
        ]
        let s = try ITFile(bytes: b.build()).samples
        #expect(s[0].pcm == [0x1234, -32768])
        #expect(s[1].pcm == [0x1234, -32768])
        #expect(s[2].pcm == [32767, -32767])
        #expect(s[3].pcm == [-32768])
        #expect(s[0].is16Bit)
    }

    @Test("Stereo PCM is stored left block then right block")
    func stereoSplit() throws {
        var b = ITBuilder()
        b.samples = [SampleSpec(flags: 0x05, cvt: 0x01, length: 2, data: [1, 2, 3, 4])]
        let s = try ITFile(bytes: b.build()).samples[0]
        #expect(s.isStereo)
        #expect(s.pcm == [1 << 8, 2 << 8])
        #expect(s.pcmRight == [3 << 8, 4 << 8])

        // IT < 2.14 did not clear the stereo flag: it is ignored.
        b.cwt = 0x0200
        let old = try ITFile(bytes: b.build()).samples[0]
        #expect(!old.isStereo)
        #expect(old.pcm == [1 << 8, 2 << 8])
    }

    @Test("Sample header fields, defaults and loop sanitization")
    func sampleHeader() throws {
        var b = ITBuilder()
        b.samples = [SampleSpec(
            name: "kick", flags: 0x01 | 0x10 | 0x20 | 0x40, volume: 80, globalVolume: 70, defaultPan: 0x80 | 20,
            length: 4, loopBegin: 1, loopEnd: 99, c5Speed: 0, sustainBegin: 3, sustainEnd: 2,
            vibrato: (5, 6, 7, 9), data: [1, 2, 3, 4]
        )]
        let s = try ITFile(bytes: b.build()).samples[0]
        #expect(s.name == "kick")
        #expect(s.defaultVolume == 64)
        #expect(s.globalVolume == 64)
        #expect(s.defaultPan == 20)
        #expect(s.c5Speed == 8363)
        #expect(s.loop == ITSample.Loop(start: 1, end: 4, isPingPong: true))
        #expect(s.sustainLoop == nil)   // start >= end
        #expect(s.autoVibrato == .init(speed: 5, depth: 6, rate: 7, waveform: .sine))
    }

    @Test("Short sample data decodes partially and is flagged truncated")
    func truncatedSampleData() throws {
        var b = ITBuilder()
        b.samples = [SampleSpec(length: 1000, data: [1, 2, 3])]
        let s = try ITFile(bytes: b.build()).samples[0]
        #expect(s.isTruncated)
        #expect(s.pcm == [1 << 8, 2 << 8, 3 << 8])
    }

    @Test("A sample parapointer without IMPS throws; one past EOF throws")
    func badSampleHeaders() {
        var b = ITBuilder()
        b.samples = [SampleSpec(rawHeaderOverride: [UInt8](repeating: 0, count: 80))]
        #expect(throws: ITError.invalidSampleHeader(index: 0)) { _ = try ITFile(bytes: b.build()) }

        b = ITBuilder()
        b.samples = [SampleSpec(length: 1, data: [0])]
        let bytes = b.build()
        #expect(throws: ITError.self) { _ = try ITFile(bytes: Array(bytes.prefix(bytes.count - 40))) }
    }

    @Test("Compressed samples pick IT 2.15 from Cvt bit 2, not Cmwt")
    func compressedVariantFromCvt() throws {
        var w = CompressedBlockWriter(is16: false)
        for d in [10, 10, 10] { w.delta(d) }
        var b = ITBuilder()
        b.cmwt = 0x0217
        b.samples = [
            SampleSpec(flags: 0x09, cvt: 0x01, length: 3, data: w.block),   // IT 2.14
            SampleSpec(flags: 0x09, cvt: 0x05, length: 3, data: w.block),   // IT 2.15
        ]
        let s = try ITFile(bytes: b.build()).samples
        #expect(s[0].pcm == [10 << 8, 20 << 8, 30 << 8])
        #expect(s[1].pcm == [10 << 8, 30 << 8, 60 << 8])
        #expect(s[0].isCompressed && !s[0].isTruncated)
    }

    @Test("Compressed stereo decodes the right channel from the second stream")
    func compressedStereo() throws {
        var l = CompressedBlockWriter(is16: true)
        var r = CompressedBlockWriter(is16: true)
        for _ in 0..<4 { l.delta(100); r.delta(-50) }
        var b = ITBuilder()
        b.samples = [SampleSpec(flags: 0x0F, cvt: 0x01, length: 4, data: l.block + r.block)]
        let s = try ITFile(bytes: b.build()).samples[0]
        #expect(s.pcm == [100, 200, 300, 400])
        #expect(s.pcmRight == [-50, -100, -150, -200])
    }

    @Test("ModPlug ADPCM and PTM byte-delta samples decode")
    func adpcmAndByteDelta() throws {
        var table = [UInt8](repeating: 0, count: 16)
        table[1] = 1; table[2] = 0xFF   // +1, -1
        var b = ITBuilder()
        b.samples = [
            SampleSpec(cvt: 0xFF, length: 3, data: table + [0x11, 0x02]),
            SampleSpec(flags: 0x03, cvt: 0x09, length: 1, data: [0x10, 0x10]),
        ]
        let s = try ITFile(bytes: b.build()).samples
        #expect(s[0].pcm == [1 << 8, 2 << 8, 1 << 8])
        // bytes delta: 0x10, 0x20 -> word 0x2010
        #expect(s[1].pcm == [0x2010])
    }

    @Test("Shared sample data pointers cannot multiply memory beyond the budget")
    func sampleBudget() throws {
        var b = ITBuilder()
        let data = [UInt8](repeating: 0, count: 20_000)
        b.samples = [SampleSpec(length: 20_000, data: data)]
        var bytes = b.build()
        // Add 600 more headers pointing at the same data with distinct lengths.
        let firstHeader = Int(bytes.u32(0xC0 + b.orders.count))
        let header = Array(bytes[firstHeader..<firstHeader + 80])
        var extra: [UInt8] = []
        for i in 0..<600 {
            var h = header
            let len = UInt32(20_000 - i)
            h[0x30] = UInt8(len & 0xFF); h[0x31] = UInt8((len >> 8) & 0xFF)
            extra += h
        }
        // Rebuild with 601 sample slots: patch counts and tables manually.
        var c = ITBuilder()
        c.samples = Array(repeating: SampleSpec(length: 0), count: 601)
        var built = c.build()
        let table = 0xC0 + c.orders.count
        let base = built.count
        built += extra + header
        for i in 0..<601 {
            let off = UInt32(base + i * 80)
            built[table + i * 4] = UInt8(off & 0xFF); built[table + i * 4 + 1] = UInt8((off >> 8) & 0xFF)
            built[table + i * 4 + 2] = UInt8((off >> 16) & 0xFF); built[table + i * 4 + 3] = 0
        }
        // Point every header at the data appended at the end.
        let dataOffset = UInt32(built.count)
        built += data
        for i in 0..<601 {
            let h = base + i * 80
            built[h + 0x48] = UInt8(dataOffset & 0xFF); built[h + 0x49] = UInt8((dataOffset >> 8) & 0xFF)
            built[h + 0x4A] = UInt8((dataOffset >> 16) & 0xFF); built[h + 0x4B] = 0
        }
        _ = bytes
        bytes = built
        #expect(throws: ITError.limitExceeded(.sampleFrames)) { _ = try ITFile(bytes: bytes) }
    }

    // MARK: Instruments

    @Test("New-format instrument fields; DfP bit 7 means don't use")
    func newInstrument() throws {
        var spec = InstrumentSpec()
        spec.name = "lead"
        spec.nna = 2; spec.dct = 1; spec.dca = 2; spec.fadeOut = 256
        spec.pps = -8; spec.ppc = 48; spec.globalVolume = 100
        spec.defaultPan = 16           // bit 7 clear: use pan 16
        spec.ifc = 0x80 | 64; spec.ifr = 0x10
        spec.volumeEnvelope = EnvelopeSpec(flags: 0x07, nodes: [(64, 0), (32, 10), (0, 5)], loop: (2, 0), sustain: (1, 9))
        spec.pitchEnvelope = EnvelopeSpec(flags: 0x81, nodes: [(-40, 0), (40, 4)])
        var b = ITBuilder()
        b.flags = 0x000D
        b.instruments = [spec.bytes()]
        let ins = try ITFile(bytes: b.build()).instruments[0]
        #expect(ins.name == "lead")
        #expect(ins.newNoteAction == .noteOff)
        #expect(ins.duplicateCheckType == .note)
        #expect(ins.duplicateCheckAction == .noteFade)
        #expect(ins.fadeOut == 256)
        #expect(ins.pitchPanSeparation == -8 && ins.pitchPanCenter == 48)
        #expect(ins.globalVolume == 100)
        #expect(ins.defaultPan == 16)
        #expect(ins.initialFilterCutoff == 64)
        #expect(ins.initialFilterResonance == nil)
        #expect(ins.keyboard[60] == .init(note: 60, sample: 1))
        #expect(!ins.isOldFormat)

        let ve = ins.volumeEnvelope
        #expect(ve.isEnabled && ve.hasLoop && ve.hasSustainLoop)
        // Ticks are made non-decreasing; loop/sustain indices clamped.
        #expect(ve.nodes.map(\.tick) == [0, 10, 10])
        #expect(ve.loopStart == 2 && ve.loopEnd == 2)
        #expect(ve.sustainStart == 1 && ve.sustainEnd == 2)
        let pe = ins.pitchEnvelope
        #expect(pe.isFilter)
        #expect(pe.nodes.map(\.value) == [-32, 32])
        #expect(pe.value(atTick: 2) == 0)

        spec.defaultPan = 0x80 | 16
        b.instruments = [spec.bytes()]
        #expect(try ITFile(bytes: b.build()).instruments[0].defaultPan == nil)
    }

    @Test("Old-format (Cmwt < 0x200) instruments use the IT 1.x layout")
    func oldInstrument() throws {
        var raw = [UInt8](repeating: 0, count: 554)
        raw.replaceSubrange(0..<4, with: Array("IMPI".utf8))
        raw[0x11] = 0x03          // envelope on + loop
        raw[0x12] = 0; raw[0x13] = 1
        raw[0x18] = 20            // fadeout (old units)
        raw[0x1A] = 1             // NNA continue
        raw[0x1B] = 1             // duplicate note check on
        for (i, c) in "oldie".utf8.enumerated() { raw[0x20 + i] = c }
        for k in 0..<120 { raw[0x40 + k * 2] = UInt8(k); raw[0x41 + k * 2] = 2 }
        raw[0x1F8] = 0; raw[0x1F9] = 64
        raw[0x1FA] = 8; raw[0x1FB] = 16
        raw[0x1FC] = 0xFF
        var b = ITBuilder()
        b.cmwt = 0x0100
        b.flags = 0x000D
        b.instruments = [raw]
        let ins = try ITFile(bytes: b.build()).instruments[0]
        #expect(ins.isOldFormat)
        #expect(ins.name == "oldie")
        #expect(ins.newNoteAction == .continue)
        #expect(ins.duplicateCheckType == .note && ins.duplicateCheckAction == .cut)
        #expect(ins.fadeOut == 40)
        #expect(ins.keyboard[10].sample == 2)
        #expect(ins.volumeEnvelope.isEnabled && ins.volumeEnvelope.hasLoop)
        #expect(ins.volumeEnvelope.nodes == [.init(value: 64, tick: 0), .init(value: 16, tick: 8)])
        #expect(!ins.panningEnvelope.isEnabled && !ins.pitchEnvelope.isEnabled)
    }

    @Test("An instrument parapointer without IMPI throws")
    func badInstrumentHeader() {
        var b = ITBuilder()
        b.instruments = [[UInt8](repeating: 0, count: 554)]
        #expect(throws: ITError.invalidInstrumentHeader(index: 0)) { _ = try ITFile(bytes: b.build()) }
    }

    // MARK: MIDI configuration

    @Test("Embedded MIDI configuration follows the edit history")
    func midiConfiguration() throws {
        var config = [UInt8](repeating: 0, count: 4896)
        let sf0 = Array("F0F000z".utf8)
        config.replaceSubrange(9 * 32..<9 * 32 + sf0.count, with: sf0)
        let z80 = Array("F0F00140".utf8)
        config.replaceSubrange(25 * 32..<25 * 32 + z80.count, with: z80)
        var b = ITBuilder()
        b.special = 0x000A
        b.trailer = [1, 0] + [UInt8](repeating: 0, count: 8) + config
        let file = try ITFile(bytes: b.build())
        let midi = try #require(file.midiConfiguration)
        #expect(midi.parametered[0] == "F0F000z")
        #expect(midi.fixed[0] == "F0F00140")
        #expect(ITMIDIConfiguration.filterAction(macro: midi.fixed[0], parameter: 0) == .resonance(64))
        #expect(ITMIDIConfiguration.filterAction(macro: "F0 F0 00 z", parameter: 99) == .cutoff(99))
        #expect(ITMIDIConfiguration.filterAction(macro: "9c n v", parameter: 1) == nil)
    }

    @Test("Macros: several messages per macro, raw z, case-sensitive variables, FA/FC/FF reset")
    func macroEvaluation() {
        typealias C = ITMIDIConfiguration
        // MultiZxx: one macro may set both cutoff and resonance.
        #expect(C.filterActions(macro: "F0F00040 F0F00120", parameter: 0) == [.cutoff(0x40), .resonance(0x20)])
        // MacroExtendedParam: z is the raw command byte, 0x80...0xFF included.
        #expect(C.filterActions(macro: "F0F000z", parameter: 0x90) == [.cutoff(127)])
        #expect(C.filterActions(macro: "F0F001z", parameter: 0x10) == [.resonance(0x10)])
        // Lowercase a/b/c are variables, so this is not a filter message.
        #expect(C.filterActions(macro: "F0F000c", parameter: 0) == [])
        #expect(C.filterActions(macro: "f0f000z", parameter: 5) == [.cutoff(5)])
        // ZxxSecrets: FA, FC, and FF reset the filter.
        #expect(C.filterActions(macro: "FC", parameter: 0) == [.reset])
        #expect(C.impulseTrackerDefault.global[7] == "Bc 0 a 20 b")
    }

    @Test("Special bit 1 without an edit history: the MIDI block is still found")
    func editHistoryFlagWithoutHistory() throws {
        // Old writers set the edit-history bit but wrote no count at all.
        // Reading the macro text as a count would run past the first
        // instrument, so the history is treated as absent.
        var config = [UInt8](repeating: 0, count: 4896)
        let sf0 = Array("F0F000z".utf8)
        config.replaceSubrange(9 * 32..<9 * 32 + sf0.count, with: sf0)
        let start = Array("FF".utf8)
        config.replaceSubrange(0..<2, with: start)
        var b = ITBuilder()
        b.special = 0x000A
        b.trailer = config
        b.instruments = [InstrumentSpec().bytes()]
        let file = try ITFile(bytes: b.build())
        let midi = try #require(file.midiConfiguration)
        #expect(midi.global[0] == "FF")
        #expect(midi.parametered[0] == "F0F000z")
    }

    @Test("Message line breaks: CR, LF, and CR LF each give one newline")
    func messageLineEndings() throws {
        var b = ITBuilder()
        b.special = 0x0001
        b.message = Array("a\rb\nc\r\nd".utf8) + [0]
        let file = try ITFile(bytes: b.build())
        #expect(file.message == "a\nb\nc\nd")
    }
}
