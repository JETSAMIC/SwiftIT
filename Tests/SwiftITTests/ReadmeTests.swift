/// ReadmeTests.swift
///
/// Keeps the README snippets honest: they are compiled (and the quick
/// start is run) against the current API.

import Testing
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
import SwiftIT

@Suite("README")
struct ReadmeTests {

    @Test("Quick start compiles and plays the fixture to the end")
    func quickStart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("swiftit-readme-\(UUID()).it")
        try Data(RobustnessTests.fixture).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // --- README quick start ---
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
        // --- end ---
        #expect(mixer.isFinished)
    }
}

#if canImport(AVFoundation) && !os(watchOS)
// README "AVAudioEngine bridge" (compiled, not run).
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
#endif
