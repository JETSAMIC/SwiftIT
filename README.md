# SwiftIT

Pure-Swift parser and PCM mixer for Impulse Tracker (`.IT`) modules. Zero external dependencies — Foundation only. Builds for iOS 17+, macOS 14+, tvOS 17+, watchOS 10+, and visionOS 1+.

SwiftIT is the third in a small family of tracker decoders maintained under [prestige-exe](https://github.com/prestige-exe), alongside [SwiftS3M](https://github.com/prestige-exe/SwiftS3M) (Scream Tracker 3) and [SwiftXM](https://github.com/prestige-exe/SwiftXM) (FastTracker II). The public shape is intentionally the same across all three so a host app can dispatch by file format without rewriting the audio bridge.

## A brief history

Impulse Tracker was written by Jeffrey Lim and released in 1995. It picked up where Scream Tracker 3 left off — more channels, more effects, smarter sample handling, real instrument abstraction with note-to-sample maps, and three independent envelopes (volume, panning, pitch) per voice. By 1997 it had become the de facto tracker for serious composers in the demoscene and the warez scene. The 2.14 release added sample compression and a per-voice filter, both of which kept the format competitive into the era of streaming MP3.

Lim shipped a full assembly source for the player along with the format spec, which is part of why the IT format has the best long-tail tooling support of any of the trackers — OpenMPT, Schism Tracker, libxmp, and Modplug all read IT faithfully.

## Format reference

The canonical spec is **ITTECH.TXT**, written by Jeffrey Lim and distributed with the IT 2.14 release. It's mirrored in multiple places — the cleanest current copies are:

- The [Schism Tracker source tree](https://github.com/schismtracker/schismtracker)
- The [OpenMPT source tree](https://github.com/OpenMPT/openmpt) (`soundlib/load_it.cpp` is the most readable reference implementation)

I've intentionally not bundled a copy of the spec text in this repo — the licensing on the document is informal at best, and the references above stay more current than anything I'd vendor.

## What ships

### Parser (`ITFile`)

- 192-byte IMPM header — orders, instruments, samples, patterns, flags, per-channel pan/volume
- Order list + instrument / sample / pattern parapointer tables
- Sample headers (`IMPS`) and sample data
  - **Uncompressed** 8/16-bit, signed/unsigned, big/little endian, delta-encoded
  - **IT 2.14 / 2.15 compressed** samples — the full variable-bit-width codec (8-bit and 16-bit, simple-delta and delta-of-delta variants)
  - Mono and stereo (stereo folds to mono on load)
  - Forward and ping-pong loops, sustain loops, sustain ping-pong
- New-format instruments (`IMPI`, IT 2.00+)
  - 120-entry note→sample keyboard table
  - Three 82-byte envelopes (volume / panning / pitch) with loop and sustain-loop semantics
  - NNA / DCT / DCA — honored by the mixer (see below)
  - Initial filter cutoff / resonance (IFC / IFR) — seeded onto the voice on note trigger
- Old-format instruments (IT 1.x, 554 bytes) — coerced into the new-format struct
- Bit-flag-compressed pattern stream with per-channel mask / note / instrument / volume / command memory

### Mixer (`ITMixer`)

- 128-slot voice pool (64 channel-owned + 64 ghost slots for NNA)
- Linear interpolation, sub-sample precision via Float position
- **Full effect set** (A..Z):
  - `Axx` set speed, `Bxx` position jump, `Cxx` pattern break
  - `Dxx` volume slide, `Exx` portamento down, `Fxx` portamento up
  - `Gxx` tone portamento, `Hxx` vibrato, `Jxx` arpeggio
  - `Kxx` vibrato + volslide, `Lxx` tone porta + volslide
  - `Mxx` set channel volume, `Oxx` sample offset
  - `Qxx` retrigger, `Rxx` tremolo
  - `Sxx` special group (S8x set pan, SCx note cut, SDx note delay)
  - `Txx` set tempo, `Uxx` fine vibrato
  - `Vxx` set global volume, `Xxx` set panning
  - `Yxx` panbrello (triangle LFO modulating pan)
  - `Zxx` filter cutoff / resonance
- **Full volume column**:
  - 0..64 set volume
  - 65..74 / 75..84 fine volume up / down (tick 0)
  - 85..94 / 95..104 volume slide up / down (per tick)
  - 105..114 / 115..124 pitch slide down / up (per tick)
  - 128..192 set pan
  - 193..202 tone portamento (a..j → fixed speed table)
  - 203..212 vibrato depth (a..j)
- **NNA / DCT / DCA** — the existing voice on a channel is moved into the ghost pool and handled per its instrument's NNA (Cut / Continue / Note Off / Note Fade) when a new note arrives. New triggers run a DCT scan across all active voices (Off / Note / Sample / Instrument) and apply the configured DCA (Cut / Note Off / Note Fade) to matches.
- **Resonant low-pass filter** — 2-pole biquad per voice, driven by the instrument's IFC/IFR and by `Zxx` at runtime. Pass-through when neither is in use, so silent songs don't pay for it.
- Volume envelope evaluation with loop + sustain-loop
- Per-instrument note-off fadeout
- End-of-song detection — Bxx back to a previously-played order trips `finished` instead of looping forever

## Status

v1 is feature-complete against ITTECH.TXT for the playback path — the README does not describe a roadmap because there isn't one. If you find a real-world IT file that misbehaves, that's a bug; please open an issue with the module attached.

Known shape-of-mixing tradeoffs (all intentional, not deferred work):

- Stereo samples fold to mono on load. Real IT mixers either double-voice or pan-split per channel; we don't, because almost every IT instrument in the wild is mono and folding keeps the voice budget honest.
- The resonant filter uses a single bilinear-transform biquad rather than IT's exact internal table. Output is close to OpenMPT's at typical cutoffs and noticeably softer at the extremes.
- Compressed-stereo samples (rare to nonexistent in practice) decode left channel only.

PRs welcome on the above; see `CONTRIBUTING.md` for the bar.

## Installation

```swift
// In Package.swift
dependencies: [
    .package(url: "https://github.com/prestige-exe/SwiftIT.git", from: "0.1.0")
]
```

## Usage

```swift
import SwiftIT
import Foundation

let data = try Data(contentsOf: someITFileURL)
let file = try ITFile(data: data)

print("\(file.songName) — \(file.orderCount) orders, \(file.instrumentCount) instruments")
print("Linear slides:", file.usesLinearSlides)

let mixer = ITMixer(file: file, sampleRate: 48_000)
let frames = 1024
let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
defer {
    buffer.deinitialize(count: frames * 2)
    buffer.deallocate()
}
_ = mixer.render(into: buffer, frames: frames)
// `buffer` now holds `frames` interleaved Float32 stereo samples.
```

## AVAudioEngine bridge

A minimal `AVAudioSourceNode` adapter — same shape that ships in the Relical app for SwiftS3M and SwiftXM. Drop into a class that owns an `AVAudioEngine` instance:

```swift
import AVFoundation
import SwiftIT

func attachMixer(_ mixer: ITMixer, to engine: AVAudioEngine) throws {
    let sampleRate = mixer.sampleRate
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 2,
        interleaved: false
    ) else { return }

    // Scratch buffer the audio thread renders into. Pre-allocated
    // so the render block never touches the allocator.
    let scratchFrames = 8192
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames * 2)
    scratch.initialize(repeating: 0, count: scratchFrames * 2)

    let node = AVAudioSourceNode(format: format) { _, _, frameCount, ablPointer in
        let n = Int(frameCount)
        let abl = UnsafeMutableAudioBufferListPointer(ablPointer)
        guard abl.count >= 2,
              let lRaw = abl[0].mData,
              let rRaw = abl[1].mData,
              n <= scratchFrames else { return noErr }

        _ = mixer.render(into: scratch, frames: n)
        let l = lRaw.assumingMemoryBound(to: Float.self)
        let r = rRaw.assumingMemoryBound(to: Float.self)
        for i in 0..<n {
            l[i] = scratch[i * 2]
            r[i] = scratch[i * 2 + 1]
        }
        return noErr
    }

    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    try engine.start()
}
```

`AVAudioSourceNode` requires non-interleaved output, so the bridge deinterleaves into the audio bus's L/R channels each render call. Connecting an interleaved format to the main mixer fails with `kAudioUnitErr_FormatNotSupported` (error `-10868`).

## Threading

`ITMixer` is `@unchecked Sendable`. Once you've handed it to the audio thread, that thread owns it exclusively — don't reach back from the main actor while playback is live. All the public mutating operations should happen during `init`.

## License

MIT. See `LICENSE`.

## Related projects

- [SwiftS3M](https://github.com/prestige-exe/SwiftS3M) — Scream Tracker 3 decoder. Same shape as this package.
- [SwiftXM](https://github.com/prestige-exe/SwiftXM) — FastTracker II decoder. Same shape as this package.
- [Relical](https://github.com/antisynthesis/relical) — iOS app for the 16colo.rs archive; uses all three decoders to play scene music alongside the artwork.
