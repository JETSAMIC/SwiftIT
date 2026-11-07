/// ITMixerState.swift
///
/// Host-channel and virtual-voice state for ``ITMixer``, plus the LFO
/// waveform tables.

import Foundation

/// One of the 64 pattern ("host") channels. Holds everything that
/// persists across notes: effect memory, channel volume and pan, the
/// current note's volume and frequency, and per-tick modulation.
struct HostChannel {
    // Header defaults / persistent channel state.
    var channelVolume = 64          // 0...64
    var pan = 128                   // 0...256
    var surround = false
    var muted = false               // header "+128 disabled": effects run, output muted

    // Current note.
    var voice = -1                  // foreground voice index, -1 = none
    var noteVolume = 64             // 0...64
    var frequency = 0.0             // Hz, base (slides applied, no modulation)
    var portaTarget = 0.0           // Hz
    var lastInstrument = 0          // 1-based, 0 = none
    var lastNote = 60
    var cutoff = 127                // 0...127
    var resonance = 0               // 0...127
    var activeMacro = 0             // SFx

    // Row state.
    var effect: UInt8 = 0
    var param: UInt8 = 0
    var volumeCommand: ITVolumeCommand? = nil
    var noteCutTick = -1
    var noteDelayTick = -1
    var delayedCell: ITPattern.Cell? = nil
    var noteTriggeredThisRow = false

    // Effect memory.
    var memVolumeSlide: UInt8 = 0       // D / K / L
    var memPitchSlide: UInt8 = 0        // E / F (and G when linked)
    var memTonePorta: UInt8 = 0         // G
    var memVolumeColumn: UInt8 = 0      // volume column a...d
    var memChannelVolumeSlide: UInt8 = 0 // N
    var memOffset: UInt8 = 0            // O
    var highOffset = 0                  // SAx
    var memPanSlide: UInt8 = 0          // P
    var memRetrigger: UInt8 = 0         // Q
    var memTremor: UInt8 = 0            // I
    var memArpeggio: UInt8 = 0          // J
    var memSpecial: UInt8 = 0           // S
    var memTempo: UInt8 = 0             // T
    var memGlobalVolumeSlide: UInt8 = 0 // W

    var vibratoSpeed = 0
    var vibratoDepth = 0                // H: y*4, U: y
    var vibratoPosition = 0
    var vibratoWaveform = 0
    var tremoloSpeed = 0
    var tremoloDepth = 0
    var tremoloPosition = 0
    var tremoloWaveform = 0
    var panbrelloSpeed = 0
    var panbrelloDepth = 0
    var panbrelloPosition = 0
    var panbrelloWaveform = 0

    var tremorOn = false
    var tremorTime = 0
    var retriggerCount = 0

    var patternLoopStart = 0
    var patternLoopCount = 0

    // Per-tick modulation (reset at every row start).
    var vibratoOffset = 0               // 1/64 semitone
    var arpeggioOffset = 0              // semitones
    var tremoloOffset = 0               // volume units 0...64
    var panbrelloOffset = 0             // pan units 0...256
    var tremorMute = false
}

/// A playing (or background) voice: one sample being resampled.
struct Voice {
    var active = false
    var channel = -1                    // host channel it came from
    var isBackground = false
    var sample = -1                     // 0-based sample index
    var instrument = -1                 // 0-based instrument index, -1 in sample mode
    var note = 0                        // pattern note (for DCT)
    var newNoteAction: ITInstrument.NewNoteAction = .cut

    var position = 0.0
    var forward = true
    var keyOn = true
    var fading = false
    var fadeVolume = 1024

    var volumeEnvelopeOn = false
    var panningEnvelopeOn = false
    var pitchEnvelopeOn = false
    var volumeEnvelopeTick = 0
    var panningEnvelopeTick = 0
    var pitchEnvelopeTick = 0

    var autoVibratoPosition = 0
    var autoVibratoDepth = 0

    var volumeSwing = 0.0               // relative, -1...1
    var panOffset = 0                   // pitch-pan separation + random pan, 0...256 units

    // Snapshot of host-channel state (refreshed every tick while foreground).
    var noteVolume = 64
    var channelVolume = 64
    var pan = 128
    var surround = false
    var muted = false
    var frequency = 0.0
    var vibratoOffset = 0
    var arpeggioOffset = 0
    var tremoloOffset = 0
    var panbrelloOffset = 0
    var tremorMute = false
    var cutoff = 127
    var resonance = 0

    // Per-tick results consumed by the resampler.
    var gainLeft: Float = 0
    var gainRight: Float = 0
    var step = 0.0
    var loudness: Float = 0

    // Resonant low-pass filter (IT formula), one state per sample channel.
    var filterEnabled = false
    var filterKey = -1
    var fA: Float = 1
    var fB: Float = 0
    var fC: Float = 0
    var y1L: Float = 0
    var y2L: Float = 0
    var y1R: Float = 0
    var y2R: Float = 0
}

/// LFO waveforms shared by vibrato, tremolo, panbrello, and sample
/// auto-vibrato: 64 positions, values -64...64.
enum Waveforms {
    static let sine: [Int] = (0..<64).map { Int((sin(Double($0) * 2 * .pi / 64) * 64).rounded()) }
    static let rampDown: [Int] = (0..<64).map { 64 - $0 * 2 }
    static let square: [Int] = (0..<64).map { $0 < 32 ? 64 : -64 }

    /// Sample of waveform `type` (0 sine, 1 ramp down, 2 square,
    /// 3 random) at `position` (any integer; wrapped to 0...63).
    static func value(_ type: Int, _ position: Int, random: inout UInt32) -> Int {
        let p = position & 63
        switch type & 3 {
        case 1: return rampDown[p]
        case 2: return square[p]
        case 3:
            random ^= random << 13
            random ^= random >> 17
            random ^= random << 5
            return Int(random % 129) - 64
        default: return sine[p]
        }
    }
}
