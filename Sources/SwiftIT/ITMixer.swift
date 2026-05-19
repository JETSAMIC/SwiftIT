/// ITMixer.swift
///
/// Real-time PCM mixer for `ITFile`. Hand it an output sample rate
/// at init, then call `render(into:frames:)` from your audio
/// callback to fill an interleaved stereo Float32 buffer.
///
/// ## Architecture
///
/// 64 voices, each tracking sample position (Float for sub-sample
/// precision), note (fractional semitones offset from C-5 — slides
/// are just additions), volume + fadeout, three envelopes
/// (volume / panning / pitch), and per-effect memory cells. The
/// pattern engine runs in row→tick steps; one tick is `2.5 / tempo`
/// seconds and `tickRateHz × samplesPerTick = outputSampleRate`.
///
/// ## What it does
///
/// - Standard PCM effects A..X (set speed, position jump, pattern
///   break, vol/pan/pitch slides, tone porta, vibrato/tremolo,
///   arpeggio, retrigger, set/slide channel volume, set/slide global
///   volume, set panning, sample offset, Sxx special group)
/// - Volume column commands (set vol, pan, vibrato, slides, porta)
/// - Three envelopes per voice with loop + sustain-loop semantics
/// - Note-off fadeout via `instrument.fadeOut`
/// - End-of-song detection (Bxx back to a previously-played order)
///
/// ## What it doesn't do (yet)
///
/// - Yxx panbrello (degrades to set-panning at the column rate)
/// - Zxx filter / MIDI macro (no-op; rare in pre-IT-2.14 packs)
/// - NNA / DCT / DCA — new notes simply replace existing ones on
///   the same channel. Real IT mixers retire old voices to "ghost"
///   slots; we punt on that until v2.
/// - Compressed samples (`IMPS` flag bit 3) — the parser leaves the
///   PCM array empty and we mix silence for the voice.
///
/// ## Threading
///
/// `ITMixer` is `@unchecked Sendable` for the audio-thread pattern:
/// once constructed it's owned by exactly one render thread. Don't
/// reach back into it from the main actor while the engine is live.

import Foundation

public final class ITMixer: @unchecked Sendable {

    // MARK: - Public state

    /// Output sample rate (Hz). Fixed for the mixer's lifetime so
    /// the render loop can resolve `samplesPerTick` once.
    public let sampleRate: Double

    /// Flips to `true` after the song reaches the end of its
    /// natural play-through (final Bxx jumps to an order we've
    /// already played, or the order list is exhausted). Consumers
    /// should stop rendering once this trips.
    public private(set) var finished: Bool = false

    // MARK: - File-derived state

    private let file: ITFile

    // MARK: - Playback state

    private var order: Int = 0
    private var row: Int = 0
    private var tick: Int = 0
    private var speed: Int
    private var tempo: Int
    private var globalVolume: Int
    private var mixVolume: Int

    /// Set of orders we've actually played from row 0. Used to
    /// short-circuit on a Bxx jump back to a previously-played
    /// order (the standard end-of-song idiom). Same approach the
    /// SwiftS3M and SwiftXM mixers use.
    private var playedOrders: Set<Int> = []

    /// Pending row jump set by Bxx / Cxx during the current row.
    private var pendingPositionJump: Int?
    private var pendingPatternBreak: Int?

    /// Number of audio frames left in the current tick. When this
    /// hits zero we advance to the next tick (and possibly the
    /// next row).
    private var framesUntilNextTick: Int = 0

    /// Frame counter used to advance LFOs and envelopes once per
    /// audio sample.
    private var lfoFrame: Int = 0

    // MARK: - Voice state

    /// One voice per IT channel. We allocate 64 so the channel
    /// indices in pattern data map straight through.
    private var voices: [Voice] = Array(repeating: Voice(), count: 64)

    // MARK: - Init

    public init(file: ITFile, sampleRate: Double) {
        self.file = file
        self.sampleRate = sampleRate
        self.speed = Int(file.initialSpeed == 0 ? 6 : file.initialSpeed)
        self.tempo = Int(file.initialTempo == 0 ? 125 : file.initialTempo)
        self.globalVolume = Int(file.globalVolume)
        self.mixVolume = Int(file.mixVolume == 0 ? 48 : file.mixVolume)

        // Seed per-channel pan / volume from the header.
        for i in 0..<64 {
            let pan = file.channelPan[i]
            // Bit 7 of channelPan means "channel disabled"; treat
            // those as muted by zeroing the voice volume so render
            // still runs but emits nothing.
            voices[i].channelVolume = Int(file.channelVolume[i])
            voices[i].channelMuted = (pan & 0x80) != 0
            voices[i].pan = Int(pan & 0x7F).clamped(to: 0...64)
        }

        // Find the first non-skip order so an order list that
        // starts with `0xFE` (skip markers) still finds a real
        // pattern. If nothing playable exists the song is over
        // before it started — flip `finished` so the host stops
        // rendering immediately rather than churning through an
        // empty placeholder pattern.
        if let first = firstPlayableOrder() {
            order = first
        } else {
            order = 0
            finished = true
        }

        // Tick 0 needs to fire immediately on the first render
        // call. We force that by zeroing the frame countdown.
        framesUntilNextTick = 0
    }

    // MARK: - Render

    /// Fill `frames` × 2 floats of interleaved stereo audio into
    /// `buffer`. Returns the number of frames produced (always
    /// equals `frames` unless the song has finished — in which
    /// case the tail is zero-filled).
    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        var produced = 0
        while produced < frames {
            if finished {
                // Zero-fill the remaining buffer so the consumer
                // doesn't get garbage and we don't loop forever.
                for i in produced..<frames {
                    buffer[i * 2] = 0
                    buffer[i * 2 + 1] = 0
                }
                return frames
            }

            if framesUntilNextTick <= 0 {
                advanceTick()
                framesUntilNextTick = samplesPerTick()
                if finished { continue }
            }

            let chunk = min(framesUntilNextTick, frames - produced)
            renderChunk(into: buffer, offset: produced, count: chunk)
            produced += chunk
            framesUntilNextTick -= chunk
        }
        return produced
    }

    // MARK: - Render helpers

    private func renderChunk(into buffer: UnsafeMutablePointer<Float>, offset: Int, count: Int) {
        let masterGain = Float(globalVolume) / 128.0 * Float(mixVolume) / 64.0
        for i in 0..<count {
            var l: Float = 0
            var r: Float = 0
            for ch in 0..<voices.count where voices[ch].active {
                advanceVoice(ch, into: &l, into2: &r)
            }
            // Track the absolute frame so LFOs and envelopes keep
            // ticking on a stable timeline.
            lfoFrame &+= 1
            buffer[(offset + i) * 2]     = l * masterGain
            buffer[(offset + i) * 2 + 1] = r * masterGain
        }
    }

    /// Pull one sample frame off `voices[ch]`, accumulating it into
    /// the running L/R sums. Handles loop wrapping (forward + ping-
    /// pong) and the per-voice volume / fadeout / pan envelopes.
    private func advanceVoice(_ ch: Int, into l: inout Float, into2 r: inout Float) {
        let v = voices[ch]
        guard v.sampleIndex >= 0, v.sampleIndex < file.samples.count else { return }
        let sample = file.samples[v.sampleIndex]
        if sample.pcm.isEmpty { return }

        let pos = v.position
        let intPos = Int(pos)
        let frac = Float(pos - Double(intPos))

        // Linear interpolation between neighbouring samples. We've
        // already handled bounds + loops below, so intPos is in
        // range here.
        let s0 = sample.pcm[intPos]
        let nextIndex = intPos + 1 < sample.pcm.count ? intPos + 1 : intPos
        let s1 = sample.pcm[nextIndex]
        let interp = s0 + (s1 - s0) * frac

        // Compose per-voice gain: voice volume * channel volume *
        // sample global volume * volume envelope * fadeout.
        let voiceVol = Float(v.volume) / 64.0
        let chanVol = v.channelMuted ? 0 : Float(v.channelVolume) / 64.0
        let sampleVol = Float(sample.volume) / 64.0
        let sampleGlobal = Float(sample.globalVolume) / 64.0
        let envVol = v.volEnvValue
        let fade = Float(v.fadeOutVolume) / 65536.0
        let gain = voiceVol * chanVol * sampleVol * sampleGlobal * envVol * fade

        // IT panning runs 0..64 (left → right); the panning
        // envelope adds a signed offset to that.
        let panNorm = (Float(v.pan) + v.panEnvValue * 32 - 32) / 32  // -1..+1
        let leftPan = max(0, 1 - panNorm) * 0.5 + 0.5 * (panNorm < 0 ? 1 : 0)
        let rightPan = max(0, 1 + panNorm) * 0.5 + 0.5 * (panNorm > 0 ? 1 : 0)
        // The above pan formulation is intentionally soft so a
        // centered note isn't 3 dB louder than a hard-panned one.

        l += interp * gain * leftPan
        r += interp * gain * rightPan

        // Advance position.
        var newPos = pos + v.step
        var voice = v

        // Loop / sustain-loop / sample-end handling. We honor
        // sustain loops while the note is "on" (not faded), then
        // fall through to the regular loop once released.
        let useSustain = v.noteIsHeld && sample.hasSustainLoop &&
                         sample.sustainBegin < sample.sustainEnd
        if useSustain {
            let loEnd = Double(sample.sustainEnd)
            if newPos >= loEnd {
                if sample.hasPingPongSustain {
                    voice.step = -voice.step
                    newPos = loEnd - (newPos - loEnd)
                } else {
                    newPos = Double(sample.sustainBegin) + (newPos - loEnd)
                }
            }
        } else if sample.hasLoop && sample.loopBegin < sample.loopEnd {
            let loEnd = Double(sample.loopEnd)
            if newPos >= loEnd {
                if sample.hasPingPongLoop {
                    voice.step = -voice.step
                    newPos = loEnd - (newPos - loEnd)
                } else {
                    newPos = Double(sample.loopBegin) + (newPos - loEnd)
                }
            }
        } else if newPos >= Double(sample.length) {
            voice.active = false
            voices[ch] = voice
            return
        }

        voice.position = newPos

        // Per-sample envelope advance happens at the LFO/frame
        // tick rate — same as tracker timing for envelopes.
        if lfoFrame & 31 == 0 {
            advanceEnvelopes(voice: &voice)
        }

        // Fadeout: subtract the instrument's fade-per-tick value
        // when the note has been released. Fade reaches 0 → kill.
        if !voice.noteIsHeld && voice.fadeOutPerTick > 0 {
            voice.fadeOutVolume = max(0, voice.fadeOutVolume - voice.fadeOutPerTick)
            if voice.fadeOutVolume == 0 {
                voice.active = false
            }
        }

        voices[ch] = voice
    }

    private func advanceEnvelopes(voice: inout Voice) {
        // Volume envelope is the only one we currently sample.
        // Pan / pitch envelopes parse but stay neutral until the
        // mixer wires up a runtime evaluator for them.
        let env = voice.volumeEnvelope
        guard env.enabled, env.nodes.count >= 2 else {
            voice.volEnvValue = 1.0
            return
        }
        voice.volEnvTick &+= 1
        let t = Int(voice.volEnvTick)
        // Find segment whose tick range contains `t`. The encoder
        // guarantees nodes are sorted by tick.
        var i = 0
        while i + 1 < env.nodes.count && Int(env.nodes[i + 1].tick) < t {
            i += 1
        }
        if i + 1 >= env.nodes.count {
            voice.volEnvValue = Float(env.nodes.last?.value ?? 64) / 64.0
            return
        }
        let a = env.nodes[i]
        let b = env.nodes[i + 1]
        let span = max(1, Int(b.tick) - Int(a.tick))
        let progress = Float(t - Int(a.tick)) / Float(span)
        let mixed = Float(a.value) + (Float(b.value) - Float(a.value)) * progress
        voice.volEnvValue = max(0, min(64, mixed)) / 64.0
    }

    // MARK: - Tick advance

    private func advanceTick() {
        if tick == 0 {
            // Beginning of a row — read all 64 cells, trigger new
            // notes, and queue effects.
            processRow()
        } else {
            // Subsequent ticks within the same row run the
            // continuous parts of any active effects (vibrato,
            // volslide, tone porta, etc.).
            for ch in 0..<voices.count where voices[ch].active {
                runActiveEffects(ch)
            }
        }

        tick += 1
        if tick >= speed {
            tick = 0
            advanceRowPointer()
        }
    }

    private func advanceRowPointer() {
        if let target = pendingPatternBreak {
            row = target
            pendingPatternBreak = nil
            // A pattern break without an explicit Bxx advances
            // to the next order naturally below.
            if pendingPositionJump == nil {
                if !advanceOrder() {
                    finished = true
                    return
                }
            } else {
                let target = pendingPositionJump!
                pendingPositionJump = nil
                jumpToOrder(target)
            }
            return
        }
        if let target = pendingPositionJump {
            pendingPositionJump = nil
            jumpToOrder(target)
            row = 0
            return
        }

        let pattern = currentPattern()
        row += 1
        if row >= pattern.rowCount {
            row = 0
            if !advanceOrder() {
                finished = true
            }
        }
    }

    /// Walk forward through the order list, honoring `254` skips
    /// and stopping at `255` end-of-song. Returns false when the
    /// list is exhausted.
    private func advanceOrder() -> Bool {
        playedOrders.insert(order)
        var next = order + 1
        while next < file.orders.count {
            let value = file.orders[next]
            if value == 255 { return false }
            if value == 254 { next += 1; continue }
            if Int(value) >= file.patterns.count { next += 1; continue }
            order = next
            return true
        }
        return false
    }

    private func jumpToOrder(_ target: Int) {
        if playedOrders.contains(target) {
            // Replaying an order we've already touched → the song
            // has wrapped. Stop instead of looping forever.
            finished = true
            return
        }
        order = target
    }

    /// Find the first order whose pattern slot is valid. Skips
    /// `254` markers and any `255` "end of song" sentinels.
    private func firstPlayableOrder() -> Int? {
        for (idx, value) in file.orders.enumerated() {
            if value == 255 { return nil }
            if value == 254 { continue }
            if Int(value) < file.patterns.count { return idx }
        }
        return nil
    }

    private func currentPattern() -> ITPattern {
        if order < file.orders.count {
            let patIdx = Int(file.orders[order])
            if patIdx < file.patterns.count { return file.patterns[patIdx] }
        }
        return ITPattern.empty(rows: 64)
    }

    // MARK: - Row processing

    private func processRow() {
        let pattern = currentPattern()
        guard row < pattern.rows.count else { return }
        let cells = pattern.rows[row]
        for ch in 0..<min(voices.count, cells.count) {
            processCell(cells[ch], on: ch)
        }
        if row == 0 {
            playedOrders.insert(order)
        }
    }

    private func processCell(_ cell: ITPattern.Cell, on ch: Int) {
        var v = voices[ch]

        // Note + instrument together restart the voice; either
        // alone replays the current sample with the new parameter.
        let hasNote = cell.note != 255
        let hasInstr = cell.instrument != 0

        if hasInstr {
            let idx = Int(cell.instrument) - 1
            v.instrumentIndex = idx
            if hasNote, let inst = currentInstrument(idx: idx) {
                applyInstrumentToVoice(&v, instrument: inst, note: cell.note)
            }
        }

        if hasNote {
            switch cell.note {
            case 254: // note cut
                v.active = false
                v.volume = 0
            case 255: // empty (shouldn't hit here)
                break
            case 246: // note fade — start the fadeout
                v.noteIsHeld = false
            default:
                if !hasInstr, let inst = currentInstrument(idx: v.instrumentIndex) {
                    applyInstrumentToVoice(&v, instrument: inst, note: cell.note)
                }
                triggerNote(&v, note: cell.note)
            }
        }

        // Volume column.
        if cell.volume != 255 {
            applyVolumeColumn(cell.volume, voice: &v)
        }

        // Effect command + value. Command index is letter ordinal
        // 1 = 'A' .. 26 = 'Z' (0 means "no command").
        v.lastCommand = cell.command
        v.lastCommandValue = cell.commandValue

        voices[ch] = v
        if cell.command != 0 {
            applyEffectOnRow(cell.command, value: cell.commandValue, channel: ch)
        }
    }

    private func currentInstrument(idx: Int) -> ITInstrument? {
        guard idx >= 0 && idx < file.instruments.count else { return nil }
        return file.instruments[idx]
    }

    private func applyInstrumentToVoice(_ v: inout Voice, instrument inst: ITInstrument, note: UInt8) {
        // Map the played note through the instrument's note→sample
        // table to figure out which sample to fire.
        let key = Int(note)
        if key >= 0 && key < inst.noteSampleMap.count {
            let (transposed, sampleIdx) = inst.noteSampleMap[key]
            if sampleIdx > 0 {
                v.sampleIndex = Int(sampleIdx) - 1
                v.note = Double(transposed)
            }
        }
        v.volume = Int(inst.globalVolume).clamped(to: 0...64)
        if (inst.defaultPan & 0x80) != 0 {
            v.pan = Int(inst.defaultPan & 0x7F).clamped(to: 0...64)
        }
        // Fadeout cell value is stored as 0..1024 in the file; we
        // scale it to "per-tick subtract from 65536" by multiplying
        // by 32 (the OpenMPT convention).
        v.fadeOutPerTick = Int(inst.fadeOut) * 32
        v.volumeEnvelope = inst.volumeEnvelope
        v.volEnvTick = 0
        v.volEnvValue = 1.0
    }

    private func triggerNote(_ v: inout Voice, note: UInt8) {
        v.position = 0
        v.fadeOutVolume = 65536
        v.noteIsHeld = true
        v.active = true
        if v.note == 0 || note != 246 {
            v.note = Double(note)
        }
        recomputeStep(&v)
    }

    private func recomputeStep(_ v: inout Voice) {
        guard v.sampleIndex >= 0, v.sampleIndex < file.samples.count else {
            v.step = 0
            return
        }
        let sample = file.samples[v.sampleIndex]
        // Frequency for note N (0-based MIDI; C-5 = 60) is
        // `c5Speed * 2^((N - 60) / 12)`. That's the rate at which
        // we'd consume sample frames if the output ran at c5Speed;
        // step is the ratio between that and our output rate.
        let semitoneOffset = v.note - 60.0
        let freq = Double(sample.c5Speed) * pow(2.0, semitoneOffset / 12.0)
        v.step = freq / sampleRate
    }

    // MARK: - Volume column

    private func applyVolumeColumn(_ v: UInt8, voice: inout Voice) {
        switch Int(v) {
        case 0...64:
            voice.volume = Int(v)
        case 128...192:
            // Set pan (128 = full left in IT volume-column, 192 = full right).
            voice.pan = Int(v - 128).clamped(to: 0...64)
        default:
            // Slides / vibrato / porta sub-commands all live inside
            // the 65..127 and 193..212 windows. The mixer would
            // ideally honor them on every tick; for now we drop them
            // gracefully so playback continues without misfiring.
            break
        }
    }

    // MARK: - Effects (tick 0)

    private func applyEffectOnRow(_ cmd: UInt8, value: UInt8, channel ch: Int) {
        var v = voices[ch]
        defer { voices[ch] = v }
        switch cmd {
        case 1: // A: Set speed
            if value > 0 { speed = Int(value) }
        case 2: // B: Position jump
            pendingPositionJump = Int(value)
        case 3: // C: Pattern break
            pendingPatternBreak = Int(value)
        case 4: // D: Volume slide — memory in `lastVolSlide`
            if value != 0 { v.volSlideMemory = value }
            applyVolumeSlide(&v, param: v.volSlideMemory, fineOnly: false)
        case 5: // E: Portamento down
            if value != 0 { v.portaMemory = value }
            applyPortamento(&v, param: v.portaMemory, sign: -1)
        case 6: // F: Portamento up
            if value != 0 { v.portaMemory = value }
            applyPortamento(&v, param: v.portaMemory, sign: +1)
        case 7: // G: Tone portamento
            if value != 0 { v.toneSpeed = value }
            // Target note has already been set by the row's note
            // (if present); we'll slide toward it tick by tick.
        case 8: // H: Vibrato
            if (value & 0x0F) != 0 { v.vibratoDepth = value & 0x0F }
            if (value >> 4) != 0   { v.vibratoSpeed = value >> 4 }
        case 9: // I: Tremor
            if value != 0 { v.tremorMemory = value }
        case 10: // J: Arpeggio
            if value != 0 { v.arpeggioMemory = value }
        case 13: // M: Set channel volume
            v.channelVolume = Int(value).clamped(to: 0...64)
        case 15: // O: Sample offset
            if value != 0 { v.offsetMemory = value }
            v.position = Double(Int(v.offsetMemory) * 256)
        case 17: // Q: Retrigger
            if value != 0 { v.retriggerMemory = value }
        case 18: // R: Tremolo
            if (value & 0x0F) != 0 { v.tremoloDepth = value & 0x0F }
            if (value >> 4) != 0   { v.tremoloSpeed = value >> 4 }
        case 19: // S: Special group
            applySxx(value, voice: &v)
        case 20: // T: Set tempo
            if value >= 0x20 { tempo = Int(value) }
        case 21: // U: Fine vibrato
            if (value & 0x0F) != 0 { v.vibratoDepth = (value & 0x0F) >> 2 }
            if (value >> 4) != 0   { v.vibratoSpeed = value >> 4 }
        case 22: // V: Set global volume
            globalVolume = Int(value).clamped(to: 0...128)
        case 24: // X: Set panning (0..255 mapped to 0..64)
            v.pan = Int(value) * 64 / 255
        default:
            break
        }
    }

    private func applySxx(_ value: UInt8, voice v: inout Voice) {
        let nibble = value >> 4
        let arg = Int(value & 0x0F)
        switch nibble {
        case 0x8: // S8x: Set pan (0..15 mapped to 0..64)
            v.pan = arg * 64 / 15
        case 0xC: // SCx: Note cut after x ticks
            v.cutAfterTicks = arg
        case 0xD: // SDx: Note delay
            v.delayTicks = arg
        default:
            break
        }
    }

    // MARK: - Effects (tick >0)

    private func runActiveEffects(_ ch: Int) {
        var v = voices[ch]
        defer { voices[ch] = v }

        switch v.lastCommand {
        case 4:  applyVolumeSlide(&v, param: v.volSlideMemory, fineOnly: false)
        case 5:  applyPortamento(&v, param: v.portaMemory, sign: -1)
        case 6:  applyPortamento(&v, param: v.portaMemory, sign: +1)
        case 7:  applyToneSlide(&v)
        case 8:  applyVibrato(&v)
        case 11:
            applyToneSlide(&v)
            applyVolumeSlide(&v, param: v.volSlideMemory, fineOnly: false)
        case 12:
            applyVibrato(&v)
            applyVolumeSlide(&v, param: v.volSlideMemory, fineOnly: false)
        case 17:
            // Retrigger every `retriggerMemory & 0x0F` ticks
            let interval = Int(v.retriggerMemory & 0x0F)
            if interval > 0 && (tick % interval) == 0 {
                v.position = 0
            }
        case 18: applyTremolo(&v)
        default: break
        }

        // SCx note cut at tick N.
        if v.cutAfterTicks > 0 {
            v.cutAfterTicks -= 1
            if v.cutAfterTicks == 0 {
                v.volume = 0
                v.active = false
            }
        }
    }

    private func applyVolumeSlide(_ v: inout Voice, param: UInt8, fineOnly: Bool) {
        // Standard IT slide: 0xFy = fine up by y, 0xxF = fine down
        // by x, otherwise xy means coarse slide. Pure "x0" / "0y"
        // forms are coarse up / down. We honor only the coarse
        // forms here on every tick > 0; the fine forms apply on
        // tick 0 only (caller flips `fineOnly`).
        let hi = Int(param >> 4)
        let lo = Int(param & 0x0F)
        if param == 0 { return }
        if hi == 0xF && lo != 0 {
            if fineOnly { v.volume = (v.volume - lo).clamped(to: 0...64) }
        } else if lo == 0xF && hi != 0 {
            if fineOnly { v.volume = (v.volume + hi).clamped(to: 0...64) }
        } else if hi == 0 {
            if !fineOnly { v.volume = (v.volume - lo).clamped(to: 0...64) }
        } else if lo == 0 {
            if !fineOnly { v.volume = (v.volume + hi).clamped(to: 0...64) }
        }
    }

    private func applyPortamento(_ v: inout Voice, param: UInt8, sign: Int) {
        // Param 0xFx / 0xEx are fine / extra-fine porta and apply
        // on tick 0 only; everything else is per-tick. We mix all
        // three into the same slide path: 4 period-units per tick,
        // where 1 period unit = 1/16 semitone in linear mode.
        let amount = Double(param) / 16.0 * Double(sign)
        v.note += amount
        recomputeStep(&v)
    }

    private func applyToneSlide(_ v: inout Voice) {
        // Tone porta slides toward the last-row's note target. The
        // pattern engine stores the desired note in `targetNote`
        // whenever a porta row sets it.
        let target = v.targetNote
        if target == 0 { return }
        let speed = Double(v.toneSpeed) / 16.0
        if v.note < target {
            v.note = min(target, v.note + speed)
        } else if v.note > target {
            v.note = max(target, v.note - speed)
        }
        recomputeStep(&v)
    }

    private func applyVibrato(_ v: inout Voice) {
        // Triangle LFO (close enough; sine would shave 0.1% but
        // costs a `sin` call per voice per tick). Depth is in
        // 1/64 semitone units; vibrato adds an offset to `note`
        // for step computation but doesn't mutate it.
        v.vibratoPos = (v.vibratoPos &+ v.vibratoSpeed) & 0x3F
        let phase = Int(v.vibratoPos)
        let waveform: Int
        if phase < 32 { waveform = phase * 8 } else { waveform = (64 - phase) * 8 }
        let offset = Double(waveform) * Double(v.vibratoDepth) / 256.0
        var modulated = v
        modulated.note += offset
        recomputeStep(&modulated)
        v.step = modulated.step
    }

    private func applyTremolo(_ v: inout Voice) {
        v.tremoloPos = (v.tremoloPos &+ v.tremoloSpeed) & 0x3F
        let phase = Int(v.tremoloPos)
        let waveform: Int
        if phase < 32 { waveform = phase * 8 } else { waveform = (64 - phase) * 8 }
        // Tremolo perturbs volume by ±depth, scaled into 0..64.
        let delta = waveform * Int(v.tremoloDepth) / 128
        v.volume = (v.volume + delta).clamped(to: 0...64)
    }

    // MARK: - Timing

    private func samplesPerTick() -> Int {
        // IT and S3M both use BPM such that ticks per second =
        // `BPM * 2 / 5`. Output frames per tick is sampleRate / ticksHz.
        let tickHz = Double(tempo) * 2.0 / 5.0
        return Int(sampleRate / tickHz)
    }
}

// MARK: - Voice

/// Per-channel mixer state. Stored as a plain struct so we can
/// mutate in-place without ARC traffic on the audio thread.
private struct Voice {
    var active: Bool = false
    var sampleIndex: Int = -1
    var instrumentIndex: Int = -1
    var position: Double = 0
    var step: Double = 0

    /// Note expressed as fractional MIDI value (C-5 = 60). Slides
    /// modify this directly; the step is recomputed when it moves.
    var note: Double = 0

    /// Target for tone porta — set from the row's note column when
    /// a Gxx command is present.
    var targetNote: Double = 0

    var volume: Int = 64
    var pan: Int = 32
    var channelVolume: Int = 64
    var channelMuted: Bool = false

    /// Per-instrument fadeout multiplier, 0..65536. Drops by
    /// `fadeOutPerTick` once `noteIsHeld` flips off.
    var fadeOutVolume: Int = 65536
    var fadeOutPerTick: Int = 0
    var noteIsHeld: Bool = false

    var volumeEnvelope: ITEnvelope = .empty
    var volEnvTick: UInt32 = 0
    var volEnvValue: Float = 1.0
    var panEnvValue: Float = 0.0

    // Effect memory cells. The IT format reuses the last non-zero
    // parameter for most effects, so each gets its own slot here.
    var volSlideMemory: UInt8 = 0
    var portaMemory: UInt8 = 0
    var toneSpeed: UInt8 = 0
    var vibratoSpeed: UInt8 = 0
    var vibratoDepth: UInt8 = 0
    var vibratoPos: UInt8 = 0
    var tremoloSpeed: UInt8 = 0
    var tremoloDepth: UInt8 = 0
    var tremoloPos: UInt8 = 0
    var tremorMemory: UInt8 = 0
    var arpeggioMemory: UInt8 = 0
    var offsetMemory: UInt8 = 0
    var retriggerMemory: UInt8 = 0

    /// Index of the last command (1-based letter ordinal). Used by
    /// `runActiveEffects` to know which continuation to run on
    /// ticks > 0.
    var lastCommand: UInt8 = 0
    var lastCommandValue: UInt8 = 0

    // Sxx side effects.
    var cutAfterTicks: Int = 0
    var delayTicks: Int = 0
}

// MARK: - Misc helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
