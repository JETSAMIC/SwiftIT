# SwiftIT

Pure-Swift parser and software mixer for Impulse Tracker (`.it`) modules, with no dependencies beyond Foundation.

## Requirements

- iOS 17+, iPadOS 17+, macOS 14+, tvOS 17+, watchOS 10+, visionOS 1+ (verified against the 27.3 SDKs)
- Swift 6.0+ / Xcode 16+

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/JETSAMIC/SwiftIT.git", from: "0.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: ["SwiftIT"])
]
```

## Quick start

```swift
import Foundation
import SwiftIT

let module = try ITFile(data: Data(contentsOf: url))
print("\(module.songName): \(module.orders.count) orders, \(module.instruments.count) instruments")
print("Linear slides:", module.usesLinearSlides)

let mixer = ITMixer(file: module, sampleRate: 48_000)
var buffer = [Float](repeating: 0, count: 2 * 1024)        // interleaved L R L R ...
while !mixer.isFinished {
    let frames = buffer.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
    // `frames` stereo frames of song audio are in `buffer`; the rest is silence.
    _ = frames
}
```

`ITFile(data:)` throws an `ITError` for malformed input. By default the mixer finishes when the order list ends, or when playback would loop back to a row it has already played. Pass `ITMixer.Options(loopsSong: true)` to play forever, as Impulse Tracker does.

The full API is documented in the DocC catalog (`Sources/SwiftIT/SwiftIT.docc`). The format and its playback semantics are documented in [`Reference/IT-Format.md`](Reference/IT-Format.md).

## Spec coverage

| Feature | Status |
|---|---|
| `IMPM` header, flags, special flags, row highlights | Supported |
| Order list (254 skip, 255 end, missing patterns = 64 empty rows) | Supported |
| Song message (CP437; CR, LF, or CR LF line breaks) | Supported |
| Edit history | Skipped (located and validated against the parapointers, not surfaced) |
| Embedded MIDI macro configuration | Parsed; only the internal filter messages (`F0F000xx` / `F0F001xx`, `FA`/`FC`/`FF` reset) are interpreted |
| New-format instruments (`Cmwt >= 0x200`) | Supported |
| Old-format IT 1.x instruments (`Cmwt < 0x200`) | Supported (converted to the new shape) |
| Volume / panning / pitch envelopes, loop, sustain loop | Supported |
| Filter envelope (pitch envelope bit 7) | Supported (OpenMPT modifier range) |
| Envelope carry (bit 3, Schism/OpenMPT extension) | Supported |
| Sample headers, loops, sustain loops, ping-pong | Supported |
| 8/16-bit, signed/unsigned, big-endian, delta PCM | Supported |
| Stereo samples (split L/R) | Supported (played in stereo) |
| IT 2.14 / 2.15 compressed samples, 8 and 16 bit, mono and stereo | Supported |
| ModPlug ADPCM, PTM byte-delta samples | Supported |
| 12-bit TX-Wave samples (`Cvt` bit 4) | Unsupported (decoded as plain PCM, as in OpenMPT) |
| Pattern packing with mask / value memory | Supported |
| Instrument mode, keyboard table, sample mode | Supported |
| NNA (cut / continue / off / fade), DCT / DCA, S70-S76 | Supported (256 voices) |
| Linear and Amiga slides | Supported |
| Effects A-Z incl. S-commands, effect memory sharing | Supported, with the exceptions below |
| S1x glissando, S2x finetune, S0x | Ignored |
| SEx / S6x row delays | Supported (each repetition replays first-tick effects; S6x adds to every repetition) |
| Zxx / SFx MIDI macros | Partial: filter cutoff/resonance (all messages in a macro), no MIDI output |
| Volume column (all commands, separate memory) | Supported |
| Resonant filter (IFC / IFR / Zxx) | Supported (IT formula) |
| Auto-vibrato, pitch-pan separation, random volume/pan | Supported (approximate depth scaling) |
| Old effects (flag bit 4) | Supported, except envelope resets by lone instrument numbers |
| Compatible Gxx (flag bit 5) | Partial: memory link and envelope retrigger; no sample-change frequency rescale |
| Smaller IT quirks captured by OpenMPT test cases | Partial; the [reference's implementation-status table](Reference/IT-Format.md#9-implementation-status) lists what isn't modelled |
| MIDI pitch controller (flag bit 6), MIDI output | Unsupported |
| OpenMPT extension chunks (`XTPM`, `STPM`, plugins) | Unsupported (ignored) |

## Robustness

`ITFile` is built to read untrusted input:

- **Errors, not crashes.** Every read is bounds-checked. Structural damage throws a typed `ITError`: truncated tables, parapointers past the end of the file, missing `IMPI`/`IMPS` signatures, and invalid patterns. Sample data that ends early is decoded partially and flagged with `ITSample.isTruncated`.
- **Bounded memory.** Decoded sample frames are capped relative to file size, and pattern cells at 8 Mi. Shared parapointers are decoded once. The decompressor never trusts the declared length when allocating.
- **Bounded playback.** No song renders forever unless you ask for it (`loopsSong`).
- **Tested.** The test suite parses every truncation of a feature-rich fixture, plus a few thousand seeded random mutations.

## Limitations

- The mixer uses linear interpolation without volume ramping, so abrupt volume changes can click.
- Tremolo, panbrello, auto-vibrato depth scaling, and the filter-envelope range follow OpenMPT's documented behaviour. They aren't bit-exact to Impulse Tracker.
- Vibrato in Amiga-slide mode is applied as a linear pitch offset.
- Output is clamped to ±1. The mix level is `MV / 128` per full-volume voice.
- `ITMixer` isn't internally synchronized. Hand it to one thread (for example, the audio render thread) and use it only from there.

## AVAudioEngine bridge

`AVAudioSourceNode` wants non-interleaved buffers, so this bridge renders into a pre-allocated interleaved scratch buffer and then de-interleaves it:

```swift
import AVFoundation
import SwiftIT

func attach(_ mixer: ITMixer, to engine: AVAudioEngine) throws {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: mixer.sampleRate, channels: 2) else { return }
    let capacity = 8192
    let scratch = UnsafeMutablePointer<Float>.allocate(capacity: capacity * 2)
    scratch.initialize(repeating: 0, count: capacity * 2)

    let node = AVAudioSourceNode(format: format) { _, _, frameCount, list in
        let n = min(Int(frameCount), capacity)
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count >= 2,
              let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        mixer.render(into: scratch, frames: n)
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

## Background

Jeffrey Lim released Impulse Tracker in 1995. It added instruments with note-to-sample maps, three envelopes per instrument, New Note Actions with background voices, a resonant filter, and (in 2.14) lossless sample compression. Lim documented the format in ITTECH.TXT, which remains the canonical reference.

## References

- Jeffrey Lim, *ITTECH.TXT* (Impulse Tracker 2.14 technical documentation)
- [OpenMPT wiki: Development: Formats/IT](https://wiki.openmpt.org/Development:_Formats/IT)
- [Schism Tracker](https://github.com/schismtracker/schismtracker) and [OpenMPT](https://github.com/OpenMPT/openmpt), whose playback behaviour SwiftIT follows where ITTECH.TXT is silent

## License

MIT. See [`LICENSE`](LICENSE).
