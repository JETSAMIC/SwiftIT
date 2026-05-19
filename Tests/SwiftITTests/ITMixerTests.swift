/// ITMixerTests.swift
///
/// Smoke tests for the mixer. We don't try to assert on rendered
/// audio fidelity here — just that the engine boots, renders frames
/// without crashing on a hand-built file, and reports `finished`
/// once the order list is exhausted.

import Testing
import Foundation
@testable import SwiftIT

@Suite("ITMixer")
struct ITMixerTests {

    @Test("Mixer renders frames for an end-of-song file without crashing")
    func rendersEmpty() throws {
        var data = Data(count: 0x100)
        data[0] = 0x49; data[1] = 0x4D; data[2] = 0x50; data[3] = 0x4D
        data[0x20] = 1
        data[0x32] = 6
        data[0x33] = 125
        // Order list: end of song.
        data[0xC0] = 255

        let file = try ITFile(data: data)
        let mixer = ITMixer(file: file, sampleRate: 48_000)

        let frames = 1024
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer {
            buffer.deinitialize(count: frames * 2)
            buffer.deallocate()
        }
        buffer.initialize(repeating: 0, count: frames * 2)
        _ = mixer.render(into: buffer, frames: frames)
        // Order list of [255] means the song has nothing to play,
        // so the mixer should immediately mark itself finished.
        #expect(mixer.finished)
    }
}
