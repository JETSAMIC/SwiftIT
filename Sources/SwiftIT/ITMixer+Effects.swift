/// ITMixer+Effects.swift
///
/// Row processing: note triggering (instrument / sample mode, NNA,
/// DCT/DCA), the volume column, and the `A`...`Z` effect commands.

import Foundation

// Effect command numbers (1 = A).
private enum Fx {
    static let a: UInt8 = 1, b: UInt8 = 2, c: UInt8 = 3, d: UInt8 = 4, e: UInt8 = 5
    static let f: UInt8 = 6, g: UInt8 = 7, h: UInt8 = 8, i: UInt8 = 9, j: UInt8 = 10
    static let k: UInt8 = 11, l: UInt8 = 12, m: UInt8 = 13, n: UInt8 = 14, o: UInt8 = 15
    static let p: UInt8 = 16, q: UInt8 = 17, r: UInt8 = 18, s: UInt8 = 19, t: UInt8 = 20
    static let u: UInt8 = 21, v: UInt8 = 22, w: UInt8 = 23, x: UInt8 = 24, y: UInt8 = 25
    static let z: UInt8 = 26
}

/// Volume-column tone portamento speeds for `g0`...`g9`.
let volumeColumnPortaSpeeds: [UInt8] = [0, 1, 4, 8, 16, 32, 64, 96, 128, 255]

extension ITMixer {

    // MARK: - Row entry

    func processRow(channel ch: Int, cell: ITPattern.Cell) {
        // Reset per-row modulation.
        channels[ch].vibratoOffset = 0
        channels[ch].arpeggioOffset = 0
        channels[ch].tremoloOffset = 0
        channels[ch].panbrelloOffset = 0
        channels[ch].tremorMute = false
        channels[ch].noteCutTick = -1
        channels[ch].noteDelayTick = -1
        channels[ch].delayedCell = nil
        channels[ch].noteTriggeredThisRow = false

        var effect = cell.effect
        var param = cell.effectParameter
        if effect > 26 { effect = 0 }
        if effect == Fx.s {
            if param == 0 { param = channels[ch].memSpecial } else { channels[ch].memSpecial = param }
        }
        channels[ch].effect = effect
        channels[ch].param = param
        channels[ch].volumeCommand = nil

        // SAx must be known before the note so Oxx can use it.
        if effect == Fx.s && param >> 4 == 0xA { channels[ch].highOffset = Int(param & 0x0F) }

        if effect == Fx.s && param >> 4 == 0xD {
            // Note delay: the note, instrument, and volume column wait.
            // A delay that never comes round within one repetition of the
            // row (speed + S6x ticks) drops the cell (tickdelay.it).
            channels[ch].noteDelayTick = max(1, Int(param & 0x0F))
            channels[ch].delayedCell = cell
        } else {
            triggerCell(channel: ch, cell: cell)
        }
        firstTickEffect(channel: ch)
    }

    /// First tick of an `SEx` repetition: per-row modulation restarts and
    /// the effect column runs its first-tick behaviour again. Notes and
    /// the volume column are not re-read (FineVolColSlide.it), and the
    /// row-structure commands (`SBx`, `S6x`, `SEx`) do not run twice.
    func repeatRow(channel ch: Int) {
        channels[ch].vibratoOffset = 0
        channels[ch].arpeggioOffset = 0
        channels[ch].tremoloOffset = 0
        channels[ch].tremorMute = false
        firstTickEffect(channel: ch, isRepeat: true)
    }

    /// Note / instrument / volume-column handling for one cell (on tick 0,
    /// or on the `SDx` tick).
    func triggerCell(channel ch: Int, cell: ITPattern.Cell) {
        let effect = channels[ch].effect
        channels[ch].volumeCommand = cell.volumeCommand
        var porta = effect == Fx.g || effect == Fx.l
        if case .tonePortamento? = cell.volumeCommand { porta = true }
        if cell.instrument != 0 { channels[ch].lastInstrument = Int(cell.instrument) }

        switch cell.note {
        case .note(let n)?:
            playNote(channel: ch, note: Int(n), instrumentGiven: cell.instrument != 0, porta: porta)
        case .off?:
            if let v = foregroundVoice(ch) { keyOff(voice: v) }
        case .cut?:
            if let v = foregroundVoice(ch) { voices[v].active = false }
            channels[ch].voice = -1
        case .fade?:
            if let v = foregroundVoice(ch) { startFade(voice: v) }
        case nil:
            if cell.instrument != 0, let v = foregroundVoice(ch) {
                // Instrument without note: restore the sample's default volume.
                let s = voices[v].sample
                if s >= 0 && s < file.samples.count {
                    channels[ch].noteVolume = Int(file.samples[s].defaultVolume)
                }
            }
        }

        if let command = cell.volumeCommand { volumeColumnFirstTick(channel: ch, command: command) }
    }

    /// Index of the channel's active foreground voice, if any.
    func foregroundVoice(_ ch: Int) -> Int? {
        let v = channels[ch].voice
        guard v >= 0, v < voices.count, voices[v].active,
              voices[v].channel == ch, !voices[v].isBackground else { return nil }
        return v
    }

    /// Frequency in Hz of `note` (C-5 = 60) for a sample's C5Speed.
    func noteFrequency(_ note: Int, c5Speed: UInt32) -> Double {
        Double(c5Speed) * pow(2.0, Double(note - 60) / 12.0)
    }

    // MARK: - Notes

    func playNote(channel ch: Int, note: Int, instrumentGiven: Bool, porta: Bool) {
        let number = channels[ch].lastInstrument
        guard number > 0 else { return }

        // Resolve instrument and sample.
        var instrumentIndex = -1
        var sampleIndex: Int
        var playedNote = note
        if instrumentMode {
            instrumentIndex = number - 1
            guard instrumentIndex < file.instruments.count else { return }
            let entry = file.instruments[instrumentIndex].keyboard[min(max(note, 0), 119)]
            guard entry.sample > 0 else { return }
            sampleIndex = Int(entry.sample) - 1
            playedNote = Int(entry.note)
        } else {
            sampleIndex = number - 1
        }
        guard sampleIndex < file.samples.count, !file.samples[sampleIndex].pcm.isEmpty else { return }
        let sample = file.samples[sampleIndex]
        let frequency = noteFrequency(playedNote, c5Speed: sample.c5Speed)
        channels[ch].lastNote = note

        // Tone portamento: retarget the playing voice instead of triggering.
        if porta, let fg = foregroundVoice(ch) {
            channels[ch].portaTarget = frequency
            if instrumentGiven {
                channels[ch].noteVolume = Int(sample.defaultVolume)
                if linkedPortamento {
                    voices[fg].volumeEnvelopeTick = 0
                    voices[fg].panningEnvelopeTick = 0
                    voices[fg].pitchEnvelopeTick = 0
                }
            }
            return
        }

        let instrument: ITInstrument? = instrumentIndex >= 0 ? file.instruments[instrumentIndex] : nil

        // Channel state picked up by the new note.
        if instrumentGiven { channels[ch].noteVolume = Int(sample.defaultVolume) }
        if let pan = instrument?.defaultPan {
            channels[ch].pan = Int(pan) * 4
            channels[ch].surround = false
        }
        if let pan = sample.defaultPan {
            channels[ch].pan = Int(pan) * 4
            channels[ch].surround = false
        }
        if let cutoff = instrument?.initialFilterCutoff { channels[ch].cutoff = Int(cutoff) }
        if let resonance = instrument?.initialFilterResonance { channels[ch].resonance = Int(resonance) }

        // Duplicate check, then the old voice's New Note Action.
        let previous = foregroundVoice(ch)
        var carryFrom: Voice? = nil
        if let p = previous, voices[p].instrument == instrumentIndex { carryFrom = voices[p] }
        if let inst = instrument {
            duplicateCheck(channel: ch, instrument: instrumentIndex, inst: inst, note: note, sample: sampleIndex)
        }
        var slot = -1
        if let p = previous, voices[p].active {
            if instrumentMode {
                switch voices[p].newNoteAction {
                case .cut:
                    voices[p].active = false
                    slot = p
                case .continue:
                    voices[p].isBackground = true
                case .noteOff:
                    voices[p].isBackground = true
                    keyOff(voice: p)
                case .noteFade:
                    voices[p].isBackground = true
                    startFade(voice: p)
                }
            } else {
                voices[p].active = false
                slot = p
            }
        }
        if slot < 0 { slot = allocateVoice() }

        var v = Voice()
        v.active = true
        v.channel = ch
        v.sample = sampleIndex
        v.instrument = instrumentIndex
        v.note = note
        v.newNoteAction = instrument?.newNoteAction ?? .cut
        if let inst = instrument {
            v.volumeEnvelopeOn = inst.volumeEnvelope.isEnabled
            v.panningEnvelopeOn = inst.panningEnvelope.isEnabled
            v.pitchEnvelopeOn = inst.pitchEnvelope.isEnabled
            if let c = carryFrom {
                if inst.volumeEnvelope.carry { v.volumeEnvelopeTick = c.volumeEnvelopeTick }
                if inst.panningEnvelope.carry { v.panningEnvelopeTick = c.panningEnvelopeTick }
                if inst.pitchEnvelope.carry { v.pitchEnvelopeTick = c.pitchEnvelopeTick }
            }
            // Pitch-pan separation and random variations.
            var panOffset = (note - Int(inst.pitchPanCenter)) * Int(inst.pitchPanSeparation) / 2
            if inst.randomPan > 0 { panOffset += Int(nextRandom() * Double(inst.randomPan) * 4) }
            v.panOffset = panOffset
            if inst.randomVolume > 0 { v.volumeSwing = nextRandom() * Double(inst.randomVolume) / 100 }
        }

        // Sample offset (Oxx, with SAx high byte).
        if channels[ch].effect == Fx.o {
            let p = channels[ch].param
            if p != 0 { channels[ch].memOffset = p }
            let offset = (channels[ch].highOffset << 16) | (Int(channels[ch].memOffset) << 8)
            if offset < sample.length {
                v.position = Double(offset)
            } else if oldEffects {
                v.position = Double(max(sample.length - 1, 0))
            }
        }

        voices[slot] = v
        channels[ch].voice = slot
        channels[ch].frequency = frequency
        channels[ch].portaTarget = frequency
        channels[ch].noteTriggeredThisRow = true
        channels[ch].retriggerCount = 0
    }

    /// IT duplicate check: voices from this host channel playing the same
    /// instrument are matched by the instrument's DCT and receive its DCA.
    func duplicateCheck(channel ch: Int, instrument index: Int, inst: ITInstrument, note: Int, sample: Int) {
        guard inst.duplicateCheckType != .off else { return }
        for i in voices.indices where voices[i].active && voices[i].channel == ch && voices[i].instrument == index {
            let match: Bool
            switch inst.duplicateCheckType {
            case .off: match = false
            case .note: match = voices[i].note == note
            case .sample: match = voices[i].sample == sample
            case .instrument: match = true
            }
            guard match else { continue }
            switch inst.duplicateCheckAction {
            case .cut: voices[i].active = false
            case .noteOff: keyOff(voice: i)
            case .noteFade: startFade(voice: i)
            }
        }
    }

    /// A free voice, or the quietest background voice, or the quietest voice.
    func allocateVoice() -> Int {
        var best = -1
        var bestLoudness = Float.infinity
        var bestIsBackground = false
        for i in voices.indices {
            if !voices[i].active { return i }
            let bg = voices[i].isBackground
            if bg && !bestIsBackground {
                best = i
                bestLoudness = voices[i].loudness
                bestIsBackground = true
            } else if bg == bestIsBackground && voices[i].loudness < bestLoudness {
                best = i
                bestLoudness = voices[i].loudness
            }
        }
        if best >= 0 {
            let ch = voices[best].channel
            if ch >= 0 && ch < 64 && channels[ch].voice == best { channels[ch].voice = -1 }
        }
        return max(best, 0)
    }

    /// Note off: release sustain loops; in instrument mode, start the
    /// fadeout when there is no volume envelope or it loops.
    func keyOff(voice i: Int) {
        voices[i].keyOn = false
        guard instrumentMode, voices[i].instrument >= 0, voices[i].instrument < file.instruments.count else { return }
        let env = file.instruments[voices[i].instrument].volumeEnvelope
        if !voices[i].volumeEnvelopeOn || env.hasLoop { voices[i].fading = true }
    }

    /// Note fade. Sample mode has no fadeout, so the note is cut.
    func startFade(voice i: Int) {
        if instrumentMode && voices[i].instrument >= 0 {
            voices[i].fading = true
        } else {
            voices[i].active = false
        }
    }

    // MARK: - Volume column

    func volumeColumnFirstTick(channel ch: Int, command: ITVolumeCommand) {
        switch command {
        case .volume(let v):
            channels[ch].noteVolume = Int(v)
        case .fineVolumeUp(let x):
            let p = volumeColumnMemory(ch, x)
            channels[ch].noteVolume = min(channels[ch].noteVolume + p, 64)
        case .fineVolumeDown(let x):
            let p = volumeColumnMemory(ch, x)
            channels[ch].noteVolume = max(channels[ch].noteVolume - p, 0)
        case .volumeSlideUp(let x), .volumeSlideDown(let x):
            _ = volumeColumnMemory(ch, x)
        case .pitchSlideDown(let x), .pitchSlideUp(let x):
            if x != 0 { setPitchSlideMemory(ch, x * 4) }
        case .panning(let p):
            channels[ch].pan = Int(p) * 4
            channels[ch].surround = false
        case .tonePortamento(let x):
            if x != 0 { setTonePortaMemory(ch, volumeColumnPortaSpeeds[Int(x)]) }
        case .vibratoDepth(let x):
            if x != 0 { channels[ch].vibratoDepth = Int(x) * 4 }
            if !oldEffects { vibrato(ch) }
        }
    }

    func volumeColumnMemory(_ ch: Int, _ x: UInt8) -> Int {
        if x != 0 { channels[ch].memVolumeColumn = x }
        return Int(channels[ch].memVolumeColumn)
    }

    func volumeColumnTick(channel ch: Int) {
        guard let command = channels[ch].volumeCommand else { return }
        switch command {
        case .volumeSlideUp:
            channels[ch].noteVolume = min(channels[ch].noteVolume + Int(channels[ch].memVolumeColumn), 64)
        case .volumeSlideDown:
            channels[ch].noteVolume = max(channels[ch].noteVolume - Int(channels[ch].memVolumeColumn), 0)
        case .pitchSlideDown:
            let p = pitchSlideMemory(ch)
            if p < 0xE0 { slideFrequency(ch, units: -4 * Int(p)) }
        case .pitchSlideUp:
            let p = pitchSlideMemory(ch)
            if p < 0xE0 { slideFrequency(ch, units: 4 * Int(p)) }
        case .tonePortamento:
            tonePortamento(ch)
        case .vibratoDepth:
            vibrato(ch)
        default:
            break
        }
    }

    // MARK: - Memory helpers

    func setPitchSlideMemory(_ ch: Int, _ p: UInt8) {
        channels[ch].memPitchSlide = p
        if linkedPortamento { channels[ch].memTonePorta = p }
    }

    func pitchSlideMemory(_ ch: Int) -> UInt8 { channels[ch].memPitchSlide }

    func setTonePortaMemory(_ ch: Int, _ p: UInt8) {
        channels[ch].memTonePorta = p
        if linkedPortamento { channels[ch].memPitchSlide = p }
    }

    /// Resolve a `D`-style slide parameter into a signed delta for this
    /// tick. `0x0F`/`0xF0` style: `x0` up, `0y` down every non-first
    /// tick; `xF` fine up, `Fy` fine down on the first tick; any other
    /// combination does nothing (IT ignores it).
    func slideDelta(_ param: UInt8, firstTick: Bool) -> Int {
        let hi = Int(param >> 4), lo = Int(param & 0x0F)
        if lo == 0 { return firstTick ? 0 : hi }
        if hi == 0 { return firstTick ? 0 : -lo }
        if lo == 0x0F { return firstTick ? hi : 0 }
        if hi == 0x0F { return firstTick ? -lo : 0 }
        return 0
    }

    // MARK: - Pitch

    /// Slide the channel frequency by `units` (positive = up). Linear
    /// mode: 1 unit = 1/768 octave. Amiga mode: 1 unit = 1 period step
    /// on the x4 period scale.
    func slideFrequency(_ ch: Int, units: Int) {
        guard units != 0 else { return }
        var f = channels[ch].frequency
        guard f > 0 else { return }
        if linearSlides {
            f *= pow(2.0, Double(units) / 768.0)
        } else {
            let period = max(Self.amigaClock / f - Double(units), 1)
            f = Self.amigaClock / period
        }
        channels[ch].frequency = min(max(f, 1), 10_000_000)
    }

    func portamento(_ ch: Int, up: Bool, firstTick: Bool) {
        let p = Int(pitchSlideMemory(ch))
        var units = 0
        if p >= 0xF0 {
            if firstTick { units = 4 * (p & 0x0F) }
        } else if p >= 0xE0 {
            if firstTick { units = p & 0x0F }
        } else if !firstTick {
            units = 4 * p
        }
        slideFrequency(ch, units: up ? units : -units)
    }

    func tonePortamento(_ ch: Int) {
        let target = channels[ch].portaTarget
        var f = channels[ch].frequency
        guard target > 0, f > 0, f != target else { return }
        let units = 4 * Double(channels[ch].memTonePorta)
        if linearSlides {
            let factor = pow(2.0, units / 768.0)
            f = f < target ? min(f * factor, target) : max(f / factor, target)
        } else {
            let p = Self.amigaClock / f
            let tp = Self.amigaClock / target
            let np = p > tp ? max(p - units, tp) : min(p + units, tp)
            f = Self.amigaClock / max(np, 1)
        }
        channels[ch].frequency = f
    }

    func vibrato(_ ch: Int) {
        let c = channels[ch]
        let value = Waveforms.value(c.vibratoWaveform, c.vibratoPosition, random: &random)
        let shift = oldEffects ? 5 : 6
        channels[ch].vibratoOffset = (value * c.vibratoDepth) >> shift
        channels[ch].vibratoPosition = (c.vibratoPosition + c.vibratoSpeed) & 63
    }

    func setVibratoMemory(_ ch: Int, _ p: UInt8, fine: Bool) {
        if p >> 4 != 0 { channels[ch].vibratoSpeed = Int(p >> 4) }
        if p & 0x0F != 0 { channels[ch].vibratoDepth = Int(p & 0x0F) * (fine ? 1 : 4) }
    }

    // MARK: - Volume / pan helpers

    func volumeSlide(_ ch: Int, firstTick: Bool) {
        let d = slideDelta(channels[ch].memVolumeSlide, firstTick: firstTick)
        channels[ch].noteVolume = min(max(channels[ch].noteVolume + d, 0), 64)
    }

    func tremolo(_ ch: Int) {
        let c = channels[ch]
        let value = Waveforms.value(c.tremoloWaveform, c.tremoloPosition, random: &random)
        channels[ch].tremoloOffset = (value * c.tremoloDepth) >> 5
        channels[ch].tremoloPosition = (c.tremoloPosition + c.tremoloSpeed) & 63
    }

    func panbrello(_ ch: Int) {
        let c = channels[ch]
        let value = Waveforms.value(c.panbrelloWaveform, c.panbrelloPosition, random: &random)
        channels[ch].panbrelloOffset = (value * c.panbrelloDepth) >> 3
        channels[ch].panbrelloPosition = (c.panbrelloPosition + c.panbrelloSpeed) & 63
    }

    func tremor(_ ch: Int) {
        let p = channels[ch].memTremor
        var on = Int(p >> 4), off = Int(p & 0x0F)
        if oldEffects { on += 1; off += 1 } else { on = max(on, 1); off = max(off, 1) }
        if channels[ch].tremorTime <= 0 {
            channels[ch].tremorOn.toggle()
            channels[ch].tremorTime = channels[ch].tremorOn ? on : off
        }
        channels[ch].tremorTime -= 1
        channels[ch].tremorMute = !channels[ch].tremorOn
    }

    func retrigger(_ ch: Int) {
        let p = channels[ch].memRetrigger
        let interval = max(1, Int(p & 0x0F))
        channels[ch].retriggerCount += 1
        guard channels[ch].retriggerCount >= interval else { return }
        channels[ch].retriggerCount = 0
        if tick == 0 && channels[ch].noteTriggeredThisRow { return }
        guard let v = foregroundVoice(ch) else { return }
        voices[v].position = 0
        voices[v].forward = true
        var vol = channels[ch].noteVolume
        switch p >> 4 {
        case 1: vol -= 1
        case 2: vol -= 2
        case 3: vol -= 4
        case 4: vol -= 8
        case 5: vol -= 16
        case 6: vol = vol * 2 / 3
        case 7: vol /= 2
        case 9: vol += 1
        case 0xA: vol += 2
        case 0xB: vol += 4
        case 0xC: vol += 8
        case 0xD: vol += 16
        case 0xE: vol = vol * 3 / 2
        case 0xF: vol *= 2
        default: break
        }
        channels[ch].noteVolume = min(max(vol, 0), 64)
    }

    // MARK: - First tick

    func firstTickEffect(channel ch: Int, isRepeat: Bool = false) {
        let effect = channels[ch].effect
        let p = channels[ch].param
        switch effect {
        case Fx.a:
            if p > 0 { speed = Int(p) }
        case Fx.b:
            guard !isRepeat else { break }
            jumpOrder = Int(p)
            // A Bxx to the right of a looping SBx cancels the loop; one to
            // its left does not (LoopBreak.it, sbx-priority.it).
            loopRow = nil
        case Fx.c:
            guard !isRepeat else { break }
            breakRow = Int(p)
        case Fx.d:
            if p != 0 { channels[ch].memVolumeSlide = p }
            volumeSlide(ch, firstTick: true)
        case Fx.e, Fx.f:
            if p != 0 { setPitchSlideMemory(ch, p) }
            portamento(ch, up: effect == Fx.f, firstTick: true)
        case Fx.g:
            if p != 0 { setTonePortaMemory(ch, p) }
        case Fx.h, Fx.u:
            setVibratoMemory(ch, p, fine: effect == Fx.u)
            if !oldEffects { vibrato(ch) }
        case Fx.i:
            if p != 0 { channels[ch].memTremor = p }
            tremor(ch)
        case Fx.j:
            if p != 0 { channels[ch].memArpeggio = p }
        case Fx.k:
            if p != 0 { channels[ch].memVolumeSlide = p }
            if !oldEffects { vibrato(ch) }
            volumeSlide(ch, firstTick: true)
        case Fx.l:
            if p != 0 { channels[ch].memVolumeSlide = p }
            volumeSlide(ch, firstTick: true)
        case Fx.m:
            if p <= 64 { channels[ch].channelVolume = Int(p) }
        case Fx.n:
            if p != 0 { channels[ch].memChannelVolumeSlide = p }
            let d = slideDelta(channels[ch].memChannelVolumeSlide, firstTick: true)
            channels[ch].channelVolume = min(max(channels[ch].channelVolume + d, 0), 64)
        case Fx.o:
            if p != 0 { channels[ch].memOffset = p }
        case Fx.p:
            if p != 0 { channels[ch].memPanSlide = p }
            panSlide(ch, firstTick: true)
        case Fx.q:
            if p & 0xF0 != 0 || p & 0x0F != 0 {
                var m = channels[ch].memRetrigger
                if p & 0xF0 != 0 { m = (m & 0x0F) | (p & 0xF0) }
                if p & 0x0F != 0 { m = (m & 0xF0) | (p & 0x0F) }
                channels[ch].memRetrigger = m
            }
            retrigger(ch)
        case Fx.r:
            if p >> 4 != 0 { channels[ch].tremoloSpeed = Int(p >> 4) }
            if p & 0x0F != 0 { channels[ch].tremoloDepth = Int(p & 0x0F) }
            if !oldEffects { tremolo(ch) }
        case Fx.s:
            let rowStructure = [0x6, 0xB, 0xE].contains(p >> 4)
            if !(isRepeat && rowStructure) { specialFirstTick(ch, p) }
        case Fx.t:
            if p >= 0x20 {
                tempo = Int(p)
            } else if p != 0 {
                channels[ch].memTempo = p
            }
        case Fx.v:
            if p <= 0x80 { globalVolume = Int(p) }
        case Fx.w:
            if p != 0 { channels[ch].memGlobalVolumeSlide = p }
            let d = slideDelta(channels[ch].memGlobalVolumeSlide, firstTick: true)
            globalVolume = min(max(globalVolume + d, 0), 128)
        case Fx.x:
            channels[ch].pan = Int(p) == 255 ? 256 : Int(p)
            channels[ch].surround = false
        case Fx.y:
            if p >> 4 != 0 { channels[ch].panbrelloSpeed = Int(p >> 4) }
            if p & 0x0F != 0 { channels[ch].panbrelloDepth = Int(p & 0x0F) }
            panbrello(ch)
        case Fx.z:
            midiMacro(ch, p)
        default:
            break
        }
    }

    func panSlide(_ ch: Int, firstTick: Bool) {
        // P0x right, Px0 left, PFx fine right, PxF fine left: the mirror
        // image of Dxx, in 0...64 pan units.
        let d = -slideDelta(channels[ch].memPanSlide, firstTick: firstTick)
        guard d != 0 else { return }
        channels[ch].pan = min(max(channels[ch].pan + d * 4, 0), 256)
        channels[ch].surround = false
    }

    func specialFirstTick(_ ch: Int, _ p: UInt8) {
        let x = Int(p & 0x0F)
        switch p >> 4 {
        case 0x3: channels[ch].vibratoWaveform = x & 3
        case 0x4: channels[ch].tremoloWaveform = x & 3
        case 0x5: channels[ch].panbrelloWaveform = x & 3
        case 0x6: fineDelay += x
        case 0x7: instrumentControl(ch, x)
        case 0x8:
            channels[ch].pan = min((x * 256 + 7) / 15, 256)
            channels[ch].surround = false
        case 0x9:
            if x == 0 { channels[ch].surround = false }
            if x == 1 { channels[ch].surround = true }
        case 0xA: channels[ch].highOffset = x
        case 0xB: patternLoop(ch, x)
        case 0xC: channels[ch].noteCutTick = max(1, x)
        case 0xE:
            if !patternDelaySet {
                patternDelay = x
                patternDelaySet = true
            }
        case 0xF: channels[ch].activeMacro = x
        default: break   // S0x, S1x, S2x, SDx (handled at row entry)
        }
    }

    func patternLoop(_ ch: Int, _ x: Int) {
        if x == 0 {
            channels[ch].patternLoopStart = row
            return
        }
        if channels[ch].patternLoopCount == 0 {
            channels[ch].patternLoopCount = x
            loopRow = channels[ch].patternLoopStart
        } else {
            channels[ch].patternLoopCount -= 1
            if channels[ch].patternLoopCount > 0 {
                loopRow = channels[ch].patternLoopStart
            } else {
                // IT quirk: after a loop completes, the next SBx loops
                // back to the row after this one.
                channels[ch].patternLoopStart = row + 1
            }
        }
    }

    /// S70...S7C.
    func instrumentControl(_ ch: Int, _ x: Int) {
        switch x {
        case 0, 1, 2:
            for i in voices.indices where voices[i].active && voices[i].channel == ch && voices[i].isBackground {
                switch x {
                case 0: voices[i].active = false
                case 1: keyOff(voice: i)
                default: startFade(voice: i)
                }
            }
        case 3...6:
            if let v = foregroundVoice(ch) {
                voices[v].newNoteAction = ITInstrument.NewNoteAction(rawValue: UInt8(x - 3)) ?? .cut
            }
        case 7...12:
            if let v = foregroundVoice(ch) {
                let on = x % 2 == 0
                switch x {
                case 7, 8: voices[v].volumeEnvelopeOn = on
                case 9, 10: voices[v].panningEnvelopeOn = on
                default: voices[v].pitchEnvelopeOn = on
                }
            }
        default:
            break
        }
    }

    /// `Zxx`: run parametered macro `SFx` (`Z00`...`Z7F`) or fixed macro
    /// `xx - 0x80` (`Z80`...`ZFF`). In both cases `z` inserts the raw
    /// command byte, and every filter message in the macro is applied.
    func midiMacro(_ ch: Int, _ p: UInt8) {
        let macro = p < 0x80 ? midi.parametered[channels[ch].activeMacro & 15] : midi.fixed[Int(p) - 0x80]
        for action in ITMIDIConfiguration.filterActions(macro: macro, parameter: Int(p)) {
            switch action {
            case .cutoff(let value): channels[ch].cutoff = value
            case .resonance(let value): channels[ch].resonance = value
            case .reset:
                channels[ch].cutoff = 127
                channels[ch].resonance = 0
            }
        }
    }

    // MARK: - Other ticks

    func runTick(channel ch: Int) {
        // SDx, SCx, and Jxx count ticks from the start of each SEx
        // repetition (PatternDelay-NoteDelay.it, JxxTicks.it), so a
        // delayed note retriggers on every repetition.
        let local = tick % repeatTicks
        var triggeredNow = false
        if local == channels[ch].noteDelayTick, let cell = channels[ch].delayedCell {
            triggerCell(channel: ch, cell: cell)
            triggeredNow = true
        }
        if local == channels[ch].noteCutTick {
            if let v = foregroundVoice(ch) { voices[v].active = false }
            channels[ch].voice = -1
        }

        // The delayed cell's tick is its first tick: the volume column
        // already ran its first-tick part in triggerCell.
        if !triggeredNow { volumeColumnTick(channel: ch) }

        let p = channels[ch].param
        switch channels[ch].effect {
        case Fx.d:
            volumeSlide(ch, firstTick: false)
        case Fx.e:
            portamento(ch, up: false, firstTick: false)
        case Fx.f:
            portamento(ch, up: true, firstTick: false)
        case Fx.g:
            tonePortamento(ch)
        case Fx.h, Fx.u:
            vibrato(ch)
        case Fx.i:
            tremor(ch)
        case Fx.j:
            let m = channels[ch].memArpeggio
            switch local % 3 {
            case 1: channels[ch].arpeggioOffset = Int(m >> 4)
            case 2: channels[ch].arpeggioOffset = Int(m & 0x0F)
            default: channels[ch].arpeggioOffset = 0
            }
        case Fx.k:
            vibrato(ch)
            volumeSlide(ch, firstTick: false)
        case Fx.l:
            tonePortamento(ch)
            volumeSlide(ch, firstTick: false)
        case Fx.n:
            let d = slideDelta(channels[ch].memChannelVolumeSlide, firstTick: false)
            channels[ch].channelVolume = min(max(channels[ch].channelVolume + d, 0), 64)
        case Fx.p:
            panSlide(ch, firstTick: false)
        case Fx.q:
            retrigger(ch)
        case Fx.r:
            tremolo(ch)
        case Fx.t:
            if p < 0x20 {
                let m = channels[ch].memTempo
                let x = Int(m & 0x0F)
                if m >> 4 == 0 { tempo = max(tempo - x, 32) }
                if m >> 4 == 1 { tempo = min(tempo + x, 255) }
            }
        case Fx.w:
            let d = slideDelta(channels[ch].memGlobalVolumeSlide, firstTick: false)
            globalVolume = min(max(globalVolume + d, 0), 128)
        case Fx.y:
            panbrello(ch)
        default:
            break
        }
    }
}
