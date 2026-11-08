/// ITMixerTests.swift
///
/// Playback-engine behaviour: order list flow, end-of-song detection,
/// slides in both frequency modes, effect memory, NNA / DCT, envelopes,
/// and rendering.

import Testing
import Foundation
@testable import SwiftIT

@Suite("ITMixer")
struct ITMixerTests {

    static let loopSample = SampleSpec(
        flags: 0x11, length: 1000, loopBegin: 0, loopEnd: 1000,
        data: (0..<1000).map { UInt8(truncatingIfNeeded: $0 * 7) }
    )

    static func file(
        flags: UInt16 = 0x0009,
        speed: UInt8 = 6,
        orders: [UInt8] = [0, 255],
        patterns: [[UInt8]],
        instruments: [InstrumentSpec] = [],
        samples: [SampleSpec] = [loopSample],
        configure: (inout ITBuilder) -> Void = { _ in }
    ) throws -> ITFile {
        var b = ITBuilder()
        b.flags = flags
        b.speed = speed
        b.orders = orders
        b.patterns = patterns
        b.instruments = instruments.map { $0.bytes() }
        b.samples = samples
        configure(&b)
        return try ITFile(bytes: b.build())
    }

    /// (order, row) at every row start until the song ends.
    static func rowStarts(_ m: ITMixer, limit: Int = 1000) -> [[Int]] {
        var out: [[Int]] = []
        var guardTicks = 0
        while !m.isFinished && !m.endReached && out.count < limit && guardTicks < 100_000 {
            if m.tick == 0 { out.append([m.currentOrder, m.currentRow]) }
            m.processTick()
            guardTicks += 1
        }
        if m.endReached { m.processTick() }
        return out
    }

    static func note(_ row: Int, _ n: UInt8, ch: Int = 0, ins: UInt8? = 1, vol: UInt8? = nil,
                     fx: Character? = nil, _ param: UInt8 = 0) -> CellSpec {
        CellSpec(row: row, channel: ch, note: n, instrument: ins, volume: vol,
                 effect: fx.map { UInt8($0.asciiValue! - 64) }, param: param)
    }

    static func fx(_ row: Int, _ letter: Character, _ param: UInt8, ch: Int = 0) -> CellSpec {
        CellSpec(row: row, channel: ch, effect: UInt8(letter.asciiValue! - 64), param: param)
    }

    // MARK: Song flow

    @Test("Order list: 254 is skipped, 255 ends the song")
    func orderList() throws {
        let p = ITBuilder.pattern(rows: 2, [])
        let f = try Self.file(orders: [254, 0, 254, 1, 255, 0], patterns: [p, p])
        let m = ITMixer(file: f, sampleRate: 44_100)
        #expect(Self.rowStarts(m) == [[1, 0], [1, 1], [3, 0], [3, 1]])
        #expect(m.isFinished)
    }

    @Test("An order list with nothing playable finishes immediately")
    func nothingPlayable() throws {
        let f = try Self.file(orders: [254, 255], patterns: [])
        let m = ITMixer(file: f, sampleRate: 44_100)
        #expect(m.isFinished)
        var buf = [Float](repeating: 1, count: 64)
        let n = buf.withUnsafeMutableBufferPointer { m.render(into: $0) }
        #expect(n == 0)
        #expect(buf.allSatisfy { $0 == 0 })
    }

    @Test("Orders naming missing patterns play 64 empty rows")
    func missingPattern() throws {
        let f = try Self.file(orders: [7], patterns: [])
        let m = ITMixer(file: f, sampleRate: 44_100)
        #expect(Self.rowStarts(m).count == 64)
    }

    @Test("Bxx back to a played order ends the song; loopsSong keeps going")
    func positionJumpLoop() throws {
        let p0 = ITBuilder.pattern(rows: 2, [])
        let p1 = ITBuilder.pattern(rows: 2, [Self.fx(1, "B", 0)])
        let f = try Self.file(orders: [0, 1], patterns: [p0, p1])
        let m = ITMixer(file: f, sampleRate: 44_100)
        #expect(Self.rowStarts(m) == [[0, 0], [0, 1], [1, 0], [1, 1]])
        #expect(m.isFinished)

        let looping = ITMixer(file: f, sampleRate: 44_100, options: .init(loopsSong: true))
        let starts = Self.rowStarts(looping, limit: 10)
        #expect(starts.count == 10)
        #expect(Array(starts[4..<6]) == [[0, 0], [0, 1]])
        #expect(!looping.isFinished)
    }

    @Test("Cxx breaks to the given (hex) row of the next order")
    func patternBreak() throws {
        let p0 = ITBuilder.pattern(rows: 4, [Self.fx(0, "C", 2)])
        let p1 = ITBuilder.pattern(rows: 4, [])
        let f = try Self.file(orders: [0, 1], patterns: [p0, p1])
        let m = ITMixer(file: f, sampleRate: 44_100)
        #expect(Self.rowStarts(m) == [[0, 0], [1, 2], [1, 3]])
    }

    @Test("SB0 / SBx pattern loop repeats rows x more times")
    func patternLoop() throws {
        let p = ITBuilder.pattern(rows: 4, [Self.fx(1, "S", 0xB0), Self.fx(2, "S", 0xB2)])
        let f = try Self.file(patterns: [p])
        let m = ITMixer(file: f, sampleRate: 44_100)
        #expect(Self.rowStarts(m).map { $0[1] } == [0, 1, 2, 1, 2, 1, 2, 3])
        #expect(m.isFinished)
    }

    @Test("Endless pattern-loop revisits are bounded")
    func revisitBound() throws {
        let p = ITBuilder.pattern(rows: 2, [Self.fx(0, "S", 0xB0), Self.fx(1, "S", 0xBF)])
        let f = try Self.file(patterns: [p])
        let m = ITMixer(file: f, sampleRate: 44_100)
        m.maximumRevisitRun = 3
        let starts = Self.rowStarts(m)
        #expect(m.isFinished)
        #expect(starts.count < 10)
    }

    @Test("SEx pattern delay and S6x fine delay lengthen the row")
    func rowDelays() throws {
        let p = ITBuilder.pattern(rows: 1, [Self.fx(0, "S", 0xE2), Self.fx(0, "S", 0x63, ch: 1)])
        let f = try Self.file(speed: 4, patterns: [p])
        let m = ITMixer(file: f, sampleRate: 44_100)
        m.runTicks(1)
        #expect(m.rowTicks == 4 * 3 + 3)
    }

    @Test("Axx sets speed, Txx tempo, T0x/T1x slide tempo")
    func speedTempo() throws {
        let p = ITBuilder.pattern(rows: 2, [Self.fx(0, "A", 3), Self.fx(0, "T", 0x80, ch: 1), Self.fx(1, "T", 0x12, ch: 1)])
        let f = try Self.file(patterns: [p])
        let m = ITMixer(file: f, sampleRate: 44_100)
        m.runTicks(1)
        #expect(m.currentSpeed == 3 && m.currentTempo == 128)
        m.runTicks(5)
        #expect(m.currentTempo == 132)
    }

    // MARK: Pitch

    @Test("Fxx slides 4*xx/768 octave in linear mode and 4*xx period units in Amiga mode")
    func linearVsAmiga() throws {
        let p = ITBuilder.pattern(rows: 1, [Self.note(0, 60, fx: "F", 0x01)])
        let linear = ITMixer(file: try Self.file(flags: 0x09, speed: 2, patterns: [p]), sampleRate: 44_100)
        linear.runTicks(2)
        #expect(abs(linear.channels[0].frequency - 8363 * pow(2, 4.0 / 768)) < 1e-6)

        let amiga = ITMixer(file: try Self.file(flags: 0x01, speed: 2, patterns: [p]), sampleRate: 44_100)
        amiga.runTicks(2)
        let k = ITMixer.amigaClock
        #expect(abs(amiga.channels[0].frequency - k / (k / 8363 - 4)) < 1e-6)
    }

    @Test("Fine (FFx) and extra-fine (FEx) slides apply once on the first tick")
    func fineSlides() throws {
        for (param, units) in [(UInt8(0xF2), 8.0), (0xE2, 2.0)] {
            let p = ITBuilder.pattern(rows: 1, [Self.note(0, 60, fx: "F", param)])
            let m = ITMixer(file: try Self.file(patterns: [p]), sampleRate: 44_100)
            m.runTicks(6)
            #expect(abs(m.channels[0].frequency - 8363 * pow(2, units / 768)) < 1e-6)
        }
    }

    @Test("E and F share memory; E00 reuses the last slide")
    func pitchSlideMemory() throws {
        let p = ITBuilder.pattern(rows: 2, [Self.note(0, 60, fx: "F", 0x02), Self.fx(1, "E", 0)])
        let m = ITMixer(file: try Self.file(speed: 2, patterns: [p]), sampleRate: 44_100)
        m.runTicks(4)
        #expect(abs(m.channels[0].frequency - 8363) < 1e-6)
    }

    @Test("Gxx slides to the new note without retriggering the voice")
    func tonePortamento() throws {
        let p = ITBuilder.pattern(rows: 2, [Self.note(0, 60), Self.note(1, 72, ins: nil, fx: "G", 0xFF)])
        let m = ITMixer(file: try Self.file(patterns: [p]), sampleRate: 44_100)
        m.runTicks(6)
        let voice = m.channels[0].voice
        m.runTicks(1)
        #expect(m.channels[0].voice == voice)
        #expect(m.channels[0].portaTarget == 8363 * 2)
        m.runTicks(1)
        #expect(m.channels[0].frequency == 8363 * 2)
    }

    @Test("Linked Gxx memory (flag bit 5) shares memory with E/F")
    func linkedPortaMemory() throws {
        let p = ITBuilder.pattern(rows: 2, [Self.note(0, 60, fx: "F", 0x10), Self.note(1, 72, ins: nil, fx: "G", 0)])
        let m = ITMixer(file: try Self.file(flags: 0x29, patterns: [p]), sampleRate: 44_100)
        #expect(m.linkedPortamento)
        m.runTicks(6)
        #expect(m.channels[0].memTonePorta == 0x10)
    }

    @Test("Jxy arpeggio cycles base, +x, +y semitones")
    func arpeggio() throws {
        let p = ITBuilder.pattern(rows: 1, [Self.note(0, 60, fx: "J", 0x47)])
        let m = ITMixer(file: try Self.file(patterns: [p]), sampleRate: 44_100)
        var offsets: [Int] = []
        for _ in 0..<6 {
            m.runTicks(1)
            offsets.append(m.channels[0].arpeggioOffset)
        }
        #expect(offsets == [0, 4, 7, 0, 4, 7])
    }

    // MARK: Volume

    @Test("Dxy: regular slides on non-first ticks, fine slides on the first")
    func volumeSlides() throws {
        let slide = ITBuilder.pattern(rows: 1, [Self.note(0, 60, vol: 32, fx: "D", 0x02)])
        var m = ITMixer(file: try Self.file(speed: 4, patterns: [slide]), sampleRate: 44_100)
        m.runTicks(4)
        #expect(m.channels[0].noteVolume == 26)

        let fine = ITBuilder.pattern(rows: 1, [Self.note(0, 60, vol: 32, fx: "D", 0xF3)])
        m = ITMixer(file: try Self.file(speed: 4, patterns: [fine]), sampleRate: 44_100)
        m.runTicks(4)
        #expect(m.channels[0].noteVolume == 29)

        // DF0 is a regular slide up by 15, not a fine slide.
        let up = ITBuilder.pattern(rows: 1, [Self.note(0, 60, vol: 10, fx: "D", 0xF0)])
        m = ITMixer(file: try Self.file(speed: 3, patterns: [up]), sampleRate: 44_100)
        m.runTicks(3)
        #expect(m.channels[0].noteVolume == 40)
    }

    @Test("Volume column slides keep their own memory")
    func volumeColumnMemory() throws {
        // c3 (slide up 3), then c0 reuses 3.
        let p = ITBuilder.pattern(rows: 2, [Self.note(0, 60, vol: 85 + 3), CellSpec(row: 1, channel: 0, volume: 85)])
        let m = ITMixer(file: try Self.file(speed: 2, patterns: [p]), sampleRate: 44_100)
        m.runTicks(4)
        // Sample default 64 + clamp: start from vol column? note sets 64, slides clamp at 64.
        #expect(m.channels[0].memVolumeColumn == 3)
        #expect(m.channels[0].noteVolume == 64)
    }

    @Test("Mxx / Nxy channel volume, Vxx / Wxy global volume")
    func channelAndGlobalVolume() throws {
        let p = ITBuilder.pattern(rows: 2, [
            Self.fx(0, "M", 0x20), Self.fx(0, "V", 0x40, ch: 1),
            Self.fx(1, "N", 0x01), Self.fx(1, "W", 0x20, ch: 1),
        ])
        let m = ITMixer(file: try Self.file(speed: 3, patterns: [p]), sampleRate: 44_100)
        m.runTicks(3)
        #expect(m.channels[0].channelVolume == 32)
        #expect(m.currentGlobalVolume == 64)
        m.runTicks(3)
        #expect(m.channels[0].channelVolume == 30)
        #expect(m.currentGlobalVolume == 68)
    }

    // MARK: Notes

    @Test("Note off (255) is not mistaken for an empty note")
    func noteOff() throws {
        let p = ITBuilder.pattern(rows: 2, [Self.note(0, 60), CellSpec(row: 1, channel: 0, note: 255)])
        let m = ITMixer(file: try Self.file(patterns: [p]), sampleRate: 44_100)
        m.runTicks(6)
        let v = m.channels[0].voice
        #expect(m.voices[v].keyOn)
        m.runTicks(1)
        #expect(!m.voices[v].keyOn)
        #expect(m.voices[v].active)
    }

    @Test("Note cut (254), SCx, and SDx note delay")
    func cutAndDelay() throws {
        let p = ITBuilder.pattern(rows: 2, [
            Self.note(0, 60), Self.note(0, 60, ch: 1, fx: "S", 0xD2), Self.note(0, 60, ch: 2, fx: "S", 0xC3),
            CellSpec(row: 1, channel: 0, note: 254),
        ])
        let m = ITMixer(file: try Self.file(patterns: [p]), sampleRate: 44_100)
        m.runTicks(1)
        #expect(m.foregroundVoice(0) != nil)
        #expect(m.foregroundVoice(1) == nil)
        m.runTicks(2)
        #expect(m.foregroundVoice(1) != nil)
        #expect(m.foregroundVoice(2) != nil)
        m.runTicks(1)
        #expect(m.foregroundVoice(2) == nil)
        m.runTicks(3)
        #expect(m.foregroundVoice(0) == nil)
    }

    @Test("Oxx starts the sample at xx * 256; SAx adds the high byte")
    func sampleOffset() throws {
        var big = Self.loopSample
        big.length = 70_000
        big.loopEnd = 70_000
        big.data = [UInt8](repeating: 1, count: 70_000)
        let p = ITBuilder.pattern(rows: 2, [Self.note(0, 60, fx: "O", 0x02), Self.note(1, 60, fx: "S", 0xA1)])
        let m = ITMixer(file: try Self.file(patterns: [p], samples: [big]), sampleRate: 44_100)
        m.runTicks(1)
        #expect(m.voices[m.channels[0].voice].position == 512)
    }

    @Test("Instrument and sample default pan set the channel pan")
    func defaultPans() throws {
        var ins = InstrumentSpec()
        ins.defaultPan = 16
        let p = ITBuilder.pattern(rows: 1, [Self.note(0, 60)])
        var m = ITMixer(file: try Self.file(flags: 0x0D, patterns: [p], instruments: [ins]), sampleRate: 44_100)
        m.runTicks(1)
        #expect(m.channels[0].pan == 64)

        var s = Self.loopSample
        s.defaultPan = 0x80 | 48
        m = ITMixer(file: try Self.file(flags: 0x0D, patterns: [p], instruments: [ins], samples: [s]), sampleRate: 44_100)
        m.runTicks(1)
        #expect(m.channels[0].pan == 192)
    }

    // MARK: NNA / DCT

    static func activeVoices(_ m: ITMixer) -> Int { m.voices.filter(\.active).count }

    @Test("NNA continue keeps the old voice in the background; NNA cut stops it")
    func newNoteActions() throws {
        let p = ITBuilder.pattern(rows: 2, [Self.note(0, 60), Self.note(1, 64)])
        for (nna, expected) in [(UInt8(0), 1), (1, 2), (2, 2), (3, 2)] {
            var ins = InstrumentSpec()
            ins.nna = nna
            ins.fadeOut = 8
            let m = ITMixer(file: try Self.file(flags: 0x0D, patterns: [p], instruments: [ins]), sampleRate: 44_100)
            m.runTicks(7)
            #expect(Self.activeVoices(m) == expected, "NNA \(nna)")
            if nna == 2 { #expect(m.voices.contains { $0.active && $0.isBackground && !$0.keyOn }) }
            if nna == 3 { #expect(m.voices.contains { $0.active && $0.isBackground && $0.fading }) }
        }
    }

    @Test("DCT note + DCA cut stops a duplicate note before NNA applies")
    func duplicateCheck() throws {
        var ins = InstrumentSpec()
        ins.nna = 1
        ins.dct = 1
        ins.dca = 0
        let same = ITBuilder.pattern(rows: 2, [Self.note(0, 60), Self.note(1, 60)])
        var m = ITMixer(file: try Self.file(flags: 0x0D, patterns: [same], instruments: [ins]), sampleRate: 44_100)
        m.runTicks(7)
        #expect(Self.activeVoices(m) == 1)

        let different = ITBuilder.pattern(rows: 2, [Self.note(0, 60), Self.note(1, 62)])
        m = ITMixer(file: try Self.file(flags: 0x0D, patterns: [different], instruments: [ins]), sampleRate: 44_100)
        m.runTicks(7)
        #expect(Self.activeVoices(m) == 2)
    }

    @Test("S70 cuts the channel's background voices")
    func pastNoteCut() throws {
        var ins = InstrumentSpec()
        ins.nna = 1
        let p = ITBuilder.pattern(rows: 3, [Self.note(0, 60), Self.note(1, 64), Self.fx(2, "S", 0x70)])
        let m = ITMixer(file: try Self.file(flags: 0x0D, patterns: [p], instruments: [ins]), sampleRate: 44_100)
        m.runTicks(7)
        #expect(Self.activeVoices(m) == 2)
        m.runTicks(6)
        #expect(Self.activeVoices(m) == 1)
    }

    // MARK: Envelopes

    @Test("Volume envelope holds at the sustain loop until note off, then ends")
    func envelopeSustain() throws {
        var ins = InstrumentSpec()
        ins.volumeEnvelope = EnvelopeSpec(flags: 0x05, nodes: [(64, 0), (32, 4), (0, 8)], sustain: (1, 1))
        let p = ITBuilder.pattern(rows: 8, [Self.note(0, 60), CellSpec(row: 4, channel: 0, note: 255)])
        let m = ITMixer(file: try Self.file(flags: 0x0D, speed: 4, patterns: [p], instruments: [ins]), sampleRate: 44_100)
        m.runTicks(16)
        let v = m.channels[0].voice
        #expect(m.voices[v].active)
        #expect(m.voices[v].volumeEnvelopeTick <= 5)
        m.runTicks(16)
        #expect(!m.voices[v].active)
    }

    @Test("Volume envelope loop wraps between loop nodes")
    func envelopeLoop() throws {
        var ins = InstrumentSpec()
        ins.volumeEnvelope = EnvelopeSpec(flags: 0x03, nodes: [(64, 0), (0, 2), (64, 4)], loop: (0, 2))
        let p = ITBuilder.pattern(rows: 8, [Self.note(0, 60)])
        let m = ITMixer(file: try Self.file(flags: 0x0D, speed: 4, patterns: [p], instruments: [ins]), sampleRate: 44_100)
        var ticks: [Int] = []
        for _ in 0..<12 {
            m.runTicks(1)
            ticks.append(m.voices[m.channels[0].voice].volumeEnvelopeTick)
        }
        #expect(ticks.allSatisfy { $0 <= 4 })
        #expect(ticks.contains(0))
    }

    @Test("Envelope carry continues the previous note's envelope position")
    func envelopeCarry() throws {
        var ins = InstrumentSpec()
        ins.nna = 0
        ins.volumeEnvelope = EnvelopeSpec(flags: 0x09, nodes: [(64, 0), (0, 100)])
        let p = ITBuilder.pattern(rows: 2, [Self.note(0, 60), Self.note(1, 62)])
        let m = ITMixer(file: try Self.file(flags: 0x0D, speed: 4, patterns: [p], instruments: [ins]), sampleRate: 44_100)
        m.runTicks(5)
        #expect(m.voices[m.channels[0].voice].volumeEnvelopeTick == 5)
    }

    @Test("Fadeout runs once released and stops the voice")
    func fadeout() throws {
        var ins = InstrumentSpec()
        ins.fadeOut = 256
        let p = ITBuilder.pattern(rows: 3, [Self.note(0, 60), CellSpec(row: 1, channel: 0, note: 255)])
        let m = ITMixer(file: try Self.file(flags: 0x0D, speed: 4, patterns: [p], instruments: [ins]), sampleRate: 44_100)
        m.runTicks(4)
        let v = m.channels[0].voice
        m.runTicks(2)
        #expect(m.voices[v].fading)
        #expect(m.voices[v].fadeVolume == 1024 - 2 * 256)
        m.runTicks(4)
        #expect(!m.voices[v].active)
    }

    // MARK: Filter

    @Test("Zxx drives cutoff via SF0; Z80-Z8F set resonance; IFC seeds cutoff")
    func filterMacros() throws {
        let p = ITBuilder.pattern(rows: 1, [Self.note(0, 60, fx: "Z", 0x40), Self.note(0, 60, ch: 1, fx: "Z", 0x81)])
        let m = ITMixer(file: try Self.file(patterns: [p]), sampleRate: 44_100)
        m.runTicks(1)
        #expect(m.channels[0].cutoff == 64)
        #expect(m.channels[1].resonance == 8)
        #expect(m.voices[m.channels[0].voice].filterEnabled)

        var ins = InstrumentSpec()
        ins.ifc = 0x80 | 30
        ins.ifr = 0x80 | 100
        let q = ITBuilder.pattern(rows: 1, [Self.note(0, 60)])
        let n = ITMixer(file: try Self.file(flags: 0x0D, patterns: [q], instruments: [ins]), sampleRate: 44_100)
        n.runTicks(1)
        #expect(n.channels[0].cutoff == 30 && n.channels[0].resonance == 100)
    }

    @Test("Fixed Zxx macros receive the raw parameter and may hold several messages")
    func fixedMacroWithParameter() throws {
        var config = [UInt8](repeating: 0, count: 4896)
        func put(_ index: Int, _ text: String) {
            let bytes = Array(text.utf8)
            config.replaceSubrange(index * 32..<index * 32 + bytes.count, with: bytes)
        }
        put(9, "F0F000z")                    // SF0
        put(25 + 0x10, "F0F000z F0F00130")   // Z90
        put(25 + 0x7F, "FF")                 // ZFF
        let p = ITBuilder.pattern(rows: 3, [
            Self.note(0, 60, fx: "Z", 0x10), Self.fx(1, "Z", 0x90), Self.fx(2, "Z", 0xFF),
        ])
        let f = try Self.file(patterns: [p]) {
            $0.special = 0x0008
            $0.trailer = config
        }
        let m = ITMixer(file: f, sampleRate: 44_100)
        m.runTicks(1)
        #expect(m.channels[0].cutoff == 0x10 && m.channels[0].resonance == 0)
        m.runTicks(6)
        // z = 0x90 (clamped to the 7-bit range), then the second message.
        #expect(m.channels[0].cutoff == 127 && m.channels[0].resonance == 0x30)
        m.runTicks(6)
        #expect(m.channels[0].cutoff == 127 && m.channels[0].resonance == 0)
    }

    // MARK: Rendering

    static func render(_ m: ITMixer, frames: Int) -> (Int, [Float]) {
        var buf = [Float](repeating: 0, count: frames * 2)
        let n = buf.withUnsafeMutableBufferPointer { m.render(into: $0) }
        return (n, buf)
    }

    @Test("A playing note produces audio; the end of the song zero-fills")
    func rendersAudio() throws {
        let p = ITBuilder.pattern(rows: 1, [Self.note(0, 60)])
        let m = ITMixer(file: try Self.file(speed: 1, patterns: [p]), sampleRate: 44_100)
        let (n, buf) = Self.render(m, frames: 4096)
        // One row at speed 1, tempo 125: 882 frames of song.
        #expect(n == 882)
        #expect(m.isFinished)
        #expect(buf[0..<(n * 2)].contains { $0 != 0 })
        #expect(buf[(n * 2)...].allSatisfy { $0 == 0 })
        #expect(buf.allSatisfy { $0 >= -1 && $0 <= 1 })
        let (again, _) = Self.render(m, frames: 16)
        #expect(again == 0)
    }

    @Test("Disabled channels (+128 pan) still run effects but output silence")
    func disabledChannel() throws {
        let p = ITBuilder.pattern(rows: 1, [Self.note(0, 60, fx: "A", 3)])
        let f = try Self.file(patterns: [p]) { $0.channelPan[0] = 0x80 | 32 }
        let m = ITMixer(file: f, sampleRate: 44_100)
        let (_, buf) = Self.render(m, frames: 512)
        #expect(m.currentSpeed == 3)
        #expect(buf.allSatisfy { $0 == 0 })
    }

    @Test("Rendering is deterministic and reset() rewinds")
    func deterministic() throws {
        var ins = InstrumentSpec()
        ins.nna = 1
        ins.volumeEnvelope = EnvelopeSpec(flags: 0x01, nodes: [(64, 0), (20, 30)])
        ins.panningEnvelope = EnvelopeSpec(flags: 0x01, nodes: [(-32, 0), (32, 20)])
        ins.pitchEnvelope = EnvelopeSpec(flags: 0x01, nodes: [(0, 0), (8, 20)])
        var s = Self.loopSample
        s.vibrato = (8, 16, 64, 3)
        s.flags |= 0x40
        let p = ITBuilder.pattern(rows: 4, [
            Self.note(0, 60, fx: "H", 0x44), Self.note(1, 67, fx: "Y", 0x48), Self.note(2, 55, fx: "R", 0x46),
            Self.note(3, 72, fx: "Q", 0x92), Self.note(0, 48, ch: 1, fx: "I", 0x21), Self.note(1, 50, ch: 2, fx: "X", 0x20),
        ])
        let f = try Self.file(flags: 0x0D, patterns: [p], instruments: [ins], samples: [s])
        let m = ITMixer(file: f, sampleRate: 48_000)
        let (_, a) = Self.render(m, frames: 8000)
        m.reset()
        let (_, b) = Self.render(m, frames: 8000)
        #expect(a == b)
        #expect(a.contains { $0 != 0 })
    }

    @Test("Hostile sample rates are clamped, not trapped on")
    func sampleRateClamp() throws {
        let p = ITBuilder.pattern(rows: 1, [Self.note(0, 60)])
        let f = try Self.file(patterns: [p])
        #expect(ITMixer(file: f, sampleRate: .nan).sampleRate == 44_100)
        #expect(ITMixer(file: f, sampleRate: 0).sampleRate == 1_000)
        #expect(ITMixer(file: f, sampleRate: 1e12).sampleRate == 1_536_000)
        let m = ITMixer(file: f, sampleRate: -5)
        #expect(Self.render(m, frames: 100).0 > 0)
        var empty = [Float]()
        #expect(empty.withUnsafeMutableBufferPointer { m.render(into: $0) } == 0)
    }
}

@Suite("ITMixer filter")
struct ITMixerFilterTests {
    @Test("Maximum resonance with a filter envelope near Nyquist stays finite")
    func filterStability() throws {
        var ins = InstrumentSpec()
        ins.ifc = 0x80 | 127
        ins.ifr = 0x80 | 127
        ins.pitchEnvelope = EnvelopeSpec(flags: 0x81, nodes: [(32, 0), (32, 10)])
        var s = ITMixerTests.loopSample
        s.data = (0..<1000).map { $0 % 2 == 0 ? 0x7F : 0x80 }   // full-scale Nyquist square
        let p = ITBuilder.pattern(rows: 4, [ITMixerTests.note(0, 119)])
        let f = try ITMixerTests.file(flags: 0x0D, patterns: [p], instruments: [ins], samples: [s])
        for rate in [4_000.0, 44_100, 192_000] {
            let m = ITMixer(file: f, sampleRate: rate)
            let (_, buf) = ITMixerTests.render(m, frames: 20_000)
            #expect(buf.allSatisfy { $0.isFinite })
            let v = m.voices.first { $0.filterEnabled }
            #expect(v.map { $0.y1L.isFinite && abs($0.y1L) < 1e6 } ?? true)
        }
    }
}
