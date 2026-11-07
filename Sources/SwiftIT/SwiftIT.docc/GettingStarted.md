# Getting Started

Load an Impulse Tracker module, inspect it, and render it to PCM.

## Load a module

``ITFile`` parses the whole file up front. It throws an ``ITError`` when the data isn't a well-formed IT module:

```swift
import Foundation
import SwiftIT

do {
    let module = try ITFile(data: Data(contentsOf: url))
    print(module.songName)
    print("\(module.orders.count) orders, \(module.patterns.count) patterns")
    print("instrument mode:", module.usesInstruments, "linear slides:", module.usesLinearSlides)
} catch let error as ITError {
    print("Not playable:", error.localizedDescription)
}
```

Sample data that ends early is the one problem that doesn't throw. Files cut short at the tail are common, so SwiftIT decodes what's there and sets ``ITSample/isTruncated`` instead.

## Inspect patterns

Patterns are unpacked into cells. Each cell's ``ITPattern/Cell/note`` is an ``ITNote``, so note-off, note-cut, and note-fade can't be mistaken for an empty cell:

```swift
let pattern = module.patterns[0]
for row in 0..<pattern.rowCount {
    let cell = pattern[row: row, channel: 0]
    if case .note(let n)? = cell.note {
        print(row, n, cell.effectLetter.map(String.init) ?? "-")
    }
}
```

## Render audio

``ITMixer`` renders interleaved stereo frames. It returns how many frames contained song audio, and zero-fills the rest once the song ends:

```swift
let mixer = ITMixer(file: module, sampleRate: 44_100)
var pcm: [Float] = []
var buffer = [Float](repeating: 0, count: 2 * 4096)
while !mixer.isFinished {
    let frames = buffer.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
    pcm += buffer[0..<(frames * 2)]
}
```

By default the song ends when the order list runs out, or when playback would loop back to a row it has already played (the usual `Bxx` idiom). Pass ``ITMixer/Options/loopsSong`` to play forever instead, as Impulse Tracker does.

## Real-time playback

``ITMixer/render(into:frames:)`` doesn't allocate or lock. You can call it from an audio render callback, as long as only that thread uses the mixer after you hand it over.
