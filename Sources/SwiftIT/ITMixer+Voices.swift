/// ITMixer+Voices.swift
///
/// Per-tick voice update (envelopes, fadeout, auto-vibrato, final
/// volume / pan / pitch / filter) and the resampling inner loop.

import Foundation

extension ITMixer {

    // MARK: - Per tick

    func updateVoices() {
        for i in voices.indices where voices[i].active {
            updateVoice(i)
        }
    }

    /// Advance an envelope position by one tick, honoring sustain loop
    /// (while the key is held) or the regular loop. Returns the new tick
    /// and whether the envelope has run past its last node.
    func advanceEnvelope(_ env: ITEnvelope, tick: Int, keyOn: Bool) -> (Int, Bool) {
        guard let last = env.nodes.last else { return (tick, true) }
        var t = tick + 1
        if env.hasSustainLoop && keyOn {
            let end = Int(env.nodes[env.sustainEnd].tick)
            if t > end { t = Int(env.nodes[env.sustainStart].tick) }
            return (t, false)
        }
        if env.hasLoop {
            let end = Int(env.nodes[env.loopEnd].tick)
            if t > end { t = Int(env.nodes[env.loopStart].tick) }
            return (t, false)
        }
        if t > Int(last.tick) { return (Int(last.tick) + 1, true) }
        return (t, false)
    }

    func updateVoice(_ i: Int) {
        var v = voices[i]

        // Foreground voices follow their host channel.
        if v.channel >= 0 && v.channel < 64 && !v.isBackground && channels[v.channel].voice == i {
            let c = channels[v.channel]
            v.noteVolume = c.noteVolume
            v.channelVolume = c.channelVolume
            v.pan = c.pan
            v.surround = c.surround
            v.muted = c.muted
            v.frequency = c.frequency
            v.vibratoOffset = c.vibratoOffset
            v.arpeggioOffset = c.arpeggioOffset
            v.tremoloOffset = c.tremoloOffset
            v.panbrelloOffset = c.panbrelloOffset
            v.tremorMute = c.tremorMute
            v.cutoff = c.cutoff
            v.resonance = c.resonance
        }

        guard v.sample >= 0 && v.sample < file.samples.count else {
            voices[i].active = false
            return
        }
        let sample = file.samples[v.sample]
        let instrument: ITInstrument? = instrumentMode && v.instrument >= 0 && v.instrument < file.instruments.count
            ? file.instruments[v.instrument] : nil

        var volumeEnvelope = 1.0
        var panEnvelope = 0.0
        var pitchEnvelope = 0.0
        var filterEnvelope: Double? = nil

        if let inst = instrument {
            let ve = inst.volumeEnvelope
            if v.volumeEnvelopeOn && ve.isEnabled {
                volumeEnvelope = ve.value(atTick: v.volumeEnvelopeTick) / 64
                let (t, ended) = advanceEnvelope(ve, tick: v.volumeEnvelopeTick, keyOn: v.keyOn)
                v.volumeEnvelopeTick = t
                if ended {
                    v.fading = true
                    if ve.nodes.last?.value == 0 { v.active = false }
                }
            }
            let pe = inst.panningEnvelope
            if v.panningEnvelopeOn && pe.isEnabled {
                panEnvelope = pe.value(atTick: v.panningEnvelopeTick)
                v.panningEnvelopeTick = advanceEnvelope(pe, tick: v.panningEnvelopeTick, keyOn: v.keyOn).0
            }
            let te = inst.pitchEnvelope
            if v.pitchEnvelopeOn && te.isEnabled {
                let value = te.value(atTick: v.pitchEnvelopeTick)
                if te.isFilter { filterEnvelope = value } else { pitchEnvelope = value }
                v.pitchEnvelopeTick = advanceEnvelope(te, tick: v.pitchEnvelopeTick, keyOn: v.keyOn).0
            }
            if v.fading {
                v.fadeVolume -= Int(inst.fadeOut)
                if v.fadeVolume <= 0 {
                    v.fadeVolume = 0
                    v.active = false
                }
            }
        }

        // Sample auto-vibrato.
        var autoVibrato = 0
        let av = sample.autoVibrato
        if av.depth > 0 {
            v.autoVibratoDepth = min(v.autoVibratoDepth + Int(av.rate), Int(av.depth) << 8)
            let value = Waveforms.value(Int(av.waveform.rawValue), v.autoVibratoPosition >> 2, random: &random)
            autoVibrato = (value * (v.autoVibratoDepth >> 8)) >> 6
            v.autoVibratoPosition = (v.autoVibratoPosition + Int(av.speed)) & 0xFF
        }

        // Volume.
        let noteVolume = Double(min(max(v.noteVolume + v.tremoloOffset, 0), 64)) / 64
        var volume = noteVolume
            * Double(sample.globalVolume) / 64
            * Double(instrument?.globalVolume ?? 128) / 128
            * Double(v.channelVolume) / 64
            * volumeEnvelope
            * Double(v.fadeVolume) / 1024
            * Double(globalVolume) / 128
            * (1 + v.volumeSwing)
        if v.tremorMute || v.muted || !v.active { volume = 0 }
        volume = min(max(volume, 0), 1)

        // Panning (0...256).
        var pan = Double(min(max(v.pan + v.panbrelloOffset + v.panOffset, 0), 256))
        if panEnvelope != 0 {
            pan += panEnvelope * (128 - abs(pan - 128)) / 32
        }
        pan = 128 + (pan - 128) * Double(separation) / 128
        if !stereoOutput { pan = 128 }
        pan = min(max(pan, 0), 256)

        let gain = Float(volume) * mixGain
        if v.surround && stereoOutput {
            v.gainLeft = gain * 0.5
            v.gainRight = -gain * 0.5
        } else {
            v.gainLeft = gain * Float((256 - pan) / 256)
            v.gainRight = gain * Float(pan / 256)
        }
        v.loudness = gain

        // Pitch.
        let octaves = Double(v.vibratoOffset + autoVibrato) / 768
            + Double(v.arpeggioOffset) / 12
            + pitchEnvelope / 24
        let frequency = v.frequency * pow(2.0, octaves)
        let step = frequency / sampleRate
        v.step = step.isFinite ? min(max(step, 0), 1_048_576) : 0

        // Filter.
        let filterActive = v.cutoff < 127 || v.resonance > 0 || filterEnvelope != nil
        if filterActive {
            let envMod = Int(((filterEnvelope ?? 0) + 32) * 8)   // 0...512, 256 = neutral
            let key = (v.cutoff << 20) | (v.resonance << 12) | envMod
            if !v.filterEnabled || key != v.filterKey {
                if !v.filterEnabled {
                    v.y1L = 0; v.y2L = 0; v.y1R = 0; v.y2R = 0
                }
                setFilter(&v, cutoff: v.cutoff, resonance: v.resonance, envelopeModifier: envMod)
                v.filterKey = key
            }
            v.filterEnabled = true
        } else {
            v.filterEnabled = false
        }

        voices[i] = v
    }

    /// Impulse Tracker's two-pole resonant low-pass (as documented by
    /// Jeffrey Lim and reproduced in Schism Tracker / OpenMPT):
    ///
    ///     fc   = 110 * 2^(0.25 + cutoff * (mod + 256) / (24 * 512))   Hz
    ///     damp = 10^(-(24 / 128) * resonance / 20)
    ///     r    = sampleRate / (2 * pi * fc)
    ///     d    = damp * r + damp - 1,  e = r * r
    ///     y[n] = x * 1/(1+d+e) + y[n-1] * (d+2e)/(1+d+e) - y[n-2] * e/(1+d+e)
    func setFilter(_ v: inout Voice, cutoff: Int, resonance: Int, envelopeModifier: Int) {
        let scaled = Double(cutoff * (envelopeModifier + 256)) / (24 * 512)
        var fc = 110 * pow(2.0, 0.25 + scaled)
        fc = min(max(fc, 120), min(20_000, sampleRate * 0.5))
        let damp = pow(10.0, -(24.0 / 128.0) * Double(resonance) / 20)
        let r = sampleRate / (2 * Double.pi * fc)
        let d = damp * r + damp - 1
        let e = r * r
        let denominator = 1 + d + e
        v.fA = Float(1 / denominator)
        v.fB = Float((d + e + e) / denominator)
        v.fC = Float(-e / denominator)
    }

    // MARK: - Mixing

    func mix(into out: UnsafeMutablePointer<Float>, frames: Int) {
        mixLeft.withUnsafeMutableBufferPointer { l in
            mixRight.withUnsafeMutableBufferPointer { r in
                for f in 0..<frames {
                    l[f] = 0
                    r[f] = 0
                }
                for i in voices.indices where voices[i].active {
                    renderVoice(i, left: l, right: r, frames: frames)
                }
                for f in 0..<frames {
                    out[f * 2] = min(max(l[f], -1), 1)
                    out[f * 2 + 1] = min(max(r[f], -1), 1)
                }
            }
        }
    }

    func renderVoice(_ i: Int, left: UnsafeMutableBufferPointer<Float>, right: UnsafeMutableBufferPointer<Float>, frames: Int) {
        var v = voices[i]
        guard v.sample >= 0 && v.sample < file.samples.count else {
            voices[i].active = false
            return
        }
        let sample = file.samples[v.sample]
        let length = sample.pcm.count
        guard length > 0, v.position.isFinite else {
            voices[i].active = false
            return
        }

        // Pick the active loop: sustain while the key is held, then the
        // regular loop.
        let loop: ITSample.Loop? = (v.keyOn ? sample.sustainLoop : nil) ?? sample.loop
        let gainL = v.gainLeft
        let gainR = v.gainRight
        let step = v.step
        let scale: Float = 1.0 / 32768
        let filter = v.filterEnabled
        let rightPCM = sample.pcmRight

        sample.pcm.withUnsafeBufferPointer { pcmL in
            (rightPCM ?? sample.pcm).withUnsafeBufferPointer { pcmR in
                let stereo = rightPCM != nil
                for f in 0..<frames {
                    var index = Int(v.position)
                    if index >= length { index = length - 1 }
                    if index < 0 { index = 0 }
                    let frac = Float(v.position - Double(index))
                    var next = index + 1
                    if let lp = loop, !lp.isPingPong, next >= lp.end { next = lp.start }
                    if next >= length { next = length - 1 }

                    let a = Float(pcmL[index]), b = Float(pcmL[next])
                    var sl = (a + (b - a) * frac) * scale
                    var sr = sl
                    if stereo {
                        let c = Float(pcmR[index]), d = Float(pcmR[next])
                        sr = (c + (d - c) * frac) * scale
                    }
                    if filter {
                        let yl = sl * v.fA + v.y1L * v.fB + v.y2L * v.fC
                        v.y2L = v.y1L
                        v.y1L = yl
                        sl = yl
                        if stereo {
                            let yr = sr * v.fA + v.y1R * v.fB + v.y2R * v.fC
                            v.y2R = v.y1R
                            v.y1R = yr
                            sr = yr
                        } else {
                            sr = yl
                        }
                    }
                    left[f] += sl * gainL
                    right[f] += sr * gainR

                    // Advance and wrap.
                    if v.forward { v.position += step } else { v.position -= step }
                    if let lp = loop {
                        let start = Double(lp.start), end = Double(lp.end)
                        let span = end - start
                        if v.forward && v.position >= end {
                            if lp.isPingPong {
                                let over = (v.position - end).truncatingRemainder(dividingBy: 2 * span)
                                if over < span {
                                    v.position = max(end - over - 1e-9, start)
                                    v.forward = false
                                } else {
                                    v.position = start + (over - span)
                                }
                            } else {
                                v.position = start + (v.position - start).truncatingRemainder(dividingBy: span)
                            }
                        } else if !v.forward && v.position < start {
                            let over = (start - v.position).truncatingRemainder(dividingBy: 2 * span)
                            if over < span {
                                v.position = start + over
                                v.forward = true
                            } else {
                                v.position = max(end - (over - span) - 1e-9, start)
                            }
                        }
                    } else if v.position >= Double(length) || v.position < 0 {
                        v.active = false
                        break
                    }
                }
            }
        }
        voices[i] = v
    }
}
