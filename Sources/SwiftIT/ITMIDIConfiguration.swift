/// ITMIDIConfiguration.swift
///
/// The embedded MIDI macro configuration (4896 bytes) and the tiny
/// subset of macro semantics SwiftIT's mixer interprets.

import Foundation

/// MIDI macro configuration: 9 global macros, 16 parametered macros
/// (`SF0`...`SFF`, triggered by `Z00`...`Z7F`) and 128 fixed macros
/// (`Z80`...`ZFF`). Each macro is up to 31 ASCII characters.
///
/// Only the internal filter macros are interpreted by ``ITMixer``:
/// `F0F000xx` sets the filter cutoff and `F0F001xx` sets the resonance,
/// where `xx` is either two hex digits or `z` (the `Zxx` parameter).
/// All other macros (real MIDI output, plugin parameters) are ignored.
public struct ITMIDIConfiguration: Sendable, Hashable {

    /// Global macros: start, stop, tick, note on, note off, volume,
    /// pan, bank select, program change.
    public let global: [String]
    /// Parametered macros `SF0`...`SFF`.
    public let parametered: [String]
    /// Fixed macros for `Z80`...`ZFF`.
    public let fixed: [String]

    /// Impulse Tracker's default configuration: `SF0` controls the
    /// filter cutoff, `Z80`...`Z8F` set resonance 0, 8, ..., 120.
    public static let impulseTrackerDefault: ITMIDIConfiguration = {
        let global = ["FF", "FC", "", "9c n v", "9c n 0", "", "", "", "Cc p"]
        var parametered = [String](repeating: "", count: 16)
        parametered[0] = "F0F000z"
        var fixed = [String](repeating: "", count: 128)
        for i in 0..<16 {
            let hex = String(i * 8, radix: 16, uppercase: true)
            fixed[i] = "F0F001" + (hex.count == 1 ? "0" + hex : hex)
        }
        return ITMIDIConfiguration(global: global, parametered: parametered, fixed: fixed)
    }()

    /// Creates a configuration from macro strings. Arrays are padded or
    /// truncated to 9 / 16 / 128 entries.
    public init(global: [String], parametered: [String], fixed: [String]) {
        func fit(_ a: [String], _ n: Int) -> [String] {
            Array((a + [String](repeating: "", count: max(0, n - a.count))).prefix(n))
        }
        self.global = fit(global, 9)
        self.parametered = fit(parametered, 16)
        self.fixed = fit(fixed, 128)
    }

    /// Size of the block on disk.
    static let byteSize = (9 + 16 + 128) * 32

    /// Parse the 4896-byte block at `offset`, or `nil` if it does not fit.
    static func parse(bytes: [UInt8], at offset: Int) -> ITMIDIConfiguration? {
        guard bytes.contains(offset: offset, length: byteSize) else { return nil }
        func macro(_ i: Int) -> String {
            var s = ""
            for j in 0..<32 {
                let b = bytes[offset + i * 32 + j]
                if b == 0 { break }
                s.unicodeScalars.append(Unicode.Scalar(b < 0x80 ? b : 0x3F))
            }
            return s
        }
        return ITMIDIConfiguration(
            global: (0..<9).map(macro),
            parametered: (9..<25).map(macro),
            fixed: (25..<153).map(macro)
        )
    }

    /// The effect of a macro the mixer understands.
    enum FilterAction: Equatable {
        case cutoff(Int)
        case resonance(Int)
    }

    /// Interpret `macro` with Zxx parameter `z` (0...127). Returns `nil`
    /// for anything other than the internal filter macros.
    static func filterAction(macro: String, parameter z: Int) -> FilterAction? {
        let chars = Array(macro.uppercased().filter { !$0.isWhitespace })
        guard chars.count >= 7, String(chars[0..<4]) == "F0F0" else { return nil }
        let kind = String(chars[4..<6])
        let valueChars = chars[6...]
        let value: Int
        if valueChars.first == "Z" {
            value = z
        } else if let v = Int(String(valueChars.prefix(2)), radix: 16) {
            value = v
        } else {
            return nil
        }
        let clamped = min(max(value, 0), 127)
        switch kind {
        case "00": return .cutoff(clamped)
        case "01": return .resonance(clamped)
        default: return nil
        }
    }
}
