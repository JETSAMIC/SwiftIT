# ``SwiftIT``

Parse and play Impulse Tracker (`.it`) modules in pure Swift.

## Overview

SwiftIT reads Impulse Tracker modules, including IT 2.14/2.15 compressed samples, old (IT 1.x) instruments, envelopes, and embedded MIDI macro configurations. Its software mixer renders interleaved stereo `Float` PCM.

The parser treats its input as untrusted. Every structural problem throws an ``ITError``, and memory use is bounded by the file size, so a hostile file can't crash or exhaust the host.

```swift
import SwiftIT

let module = try ITFile(data: Data(contentsOf: url))
let mixer = ITMixer(file: module, sampleRate: 48_000)
var buffer = [Float](repeating: 0, count: 2 * 1024)
let frames = buffer.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
```

## Topics

### Essentials

- <doc:GettingStarted>
- ``ITFile``
- ``ITMixer``
- ``ITError``

### Module structure

- ``ITFile/Flags``
- ``ITFile/Special``
- ``ITMIDIConfiguration``

### Instruments

- ``ITInstrument``
- ``ITInstrument/NewNoteAction``
- ``ITInstrument/DuplicateCheckType``
- ``ITInstrument/DuplicateCheckAction``
- ``ITInstrument/KeyboardEntry``
- ``ITEnvelope``
- ``ITEnvelope/Node``

### Samples

- ``ITSample``
- ``ITSample/Flags``
- ``ITSample/Conversion``
- ``ITSample/Loop``
- ``ITSample/AutoVibrato``
- ``ITSample/Waveform``

### Patterns

- ``ITPattern``
- ``ITPattern/Cell``
- ``ITNote``
- ``ITVolumeCommand``

### Playback

- ``ITMixer/Options``
