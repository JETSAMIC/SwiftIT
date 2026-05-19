/// ITDecompressTests.swift
///
/// Coverage for the bit-reader and a sanity check on the
/// decompressor's exit conditions. We don't have a reliable way to
/// hand-construct a real compressed block here (the encoder is
/// nontrivial and not part of this library), so the test focuses on
/// the parts of the codec that we *can* drive directly: the
/// bit-reader, and the early-exit when the input runs out before
/// the requested sample count.

import Testing
import Foundation
@testable import SwiftIT

@Suite("ITDecompress")
struct ITDecompressTests {

    @Test("Truncated input yields a zero-filled tail rather than crashing")
    func truncatedInputDoesNotCrash() {
        // A block header claiming 1024 bytes of payload, followed by
        // a stream that runs out almost immediately. The decoder
        // should bail cleanly and the remaining samples come back
        // as zeros.
        var data = Data(count: 16)
        data[0] = 0x10; data[1] = 0x00  // claimed block length = 16
        // Rest is zero — the bit reader will hit EOF and return nil.
        let pcm = ITDecompress.decompress8(data: data, offset: 0, sampleCount: 256, is215: false)
        #expect(pcm.count == 256)
        // Trailing samples should be zero (decoder couldn't produce them).
        #expect(pcm.last == 0)
    }

    @Test("Empty input returns silence")
    func emptyInput() {
        let pcm = ITDecompress.decompress8(data: Data(), offset: 0, sampleCount: 32, is215: false)
        #expect(pcm.count == 32)
        #expect(pcm.allSatisfy { $0 == 0 })
    }
}
