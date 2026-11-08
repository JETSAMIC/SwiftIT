/// ITMIDIConfiguration.swift
///
/// The embedded MIDI macro configuration (4896 bytes) and the tiny
/// subset of macro semantics SwiftIT's mixer interprets.

import Foundation

/// MIDI macro configuration: 9 global macros, 16 parametered macros
/// (`SF0`...`SFF`, triggered by `Z00`...`Z7F`) and 128 fixed macros
/// (`Z80`...`ZFF`). Each macro is up to 31 ASCII characters.
///
/// Only the internal filter messages are interpreted by ``ITMixer``:
/// `F0F000xx` sets the filter cutoff and `F0F001xx` sets the resonance,
/// where `xx` is either two hex digits or `z` (the `Zxx` parameter). A
/// macro may contain several messages, and `FA` / `FC` / `FF` reset the
/// filter. All other macros (real MIDI output, plugin parameters) are
/// ignored.
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
        let global = ["FF", "FC", "", "9c n v", "9c n 0", "", "", "Bc 0 a 20 b", "Cc p"]
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
        /// `F0 F0 00 xx`: set the filter cutoff.
        case cutoff(Int)
        /// `F0 F0 01 xx`: set the filter resonance.
        case resonance(Int)
        /// `FA`, `FC`, or `FF` (MIDI start / stop / reset): back to an
        /// open filter (cutoff 127, resonance 0).
        case reset
    }

    /// Interpret `macro` with Zxx parameter `z` and return the first
    /// filter action it contains, or `nil` when it contains none.
    static func filterAction(macro: String, parameter z: Int) -> FilterAction? {
        filterActions(macro: macro, parameter: z).first
    }

    /// Interpret `macro` with Zxx parameter `z` (the raw command byte,
    /// 0...255) and return every filter action it contains, in order.
    ///
    /// The macro text is turned into bytes the way Impulse Tracker does:
    /// pairs of hex digits form a byte, `z` inserts the parameter byte,
    /// and whitespace is ignored. The other variable letters (`c`, `n`,
    /// `v`, `u`, `x`, `y`, `a`, `b`, `p`, `h`, `o`, `m`, `s`) depend on
    /// MIDI state the mixer does not model, so a filter message whose
    /// value comes from one of them is skipped. A macro may hold several
    /// messages; each `F0 F0 00 xx` / `F0 F0 01 xx` is applied.
    static func filterActions(macro: String, parameter z: Int) -> [FilterAction] {
        // nil marks a byte whose value the mixer cannot know.
        var bytes: [Int?] = []
        var pendingNibble: Int? = nil
        func flush() {
            if let n = pendingNibble { bytes.append(n) }
            pendingNibble = nil
        }
        for ch in macro.unicodeScalars {
            if ch == " " || ch == "\t" { continue }
            if let digit = Int(String(ch), radix: 16), !(ch == "b" || ch == "c" || ch == "a") {
                if let hi = pendingNibble {
                    bytes.append(hi << 4 | digit)
                    pendingNibble = nil
                } else {
                    pendingNibble = digit
                }
                continue
            }
            flush()
            if ch == "z" || ch == "Z" {
                bytes.append(z & 0xFF)
            } else {
                bytes.append(nil)
            }
        }
        flush()

        var actions: [FilterAction] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0xF0, i + 3 < bytes.count, bytes[i + 1] == 0xF0 {
                if let kind = bytes[i + 2], let value = bytes[i + 3] {
                    let clamped = min(max(value, 0), 127)
                    if kind == 0x00 { actions.append(.cutoff(clamped)) }
                    if kind == 0x01 { actions.append(.resonance(clamped)) }
                }
                i += 4
                continue
            }
            if let b = bytes[i], b == 0xFA || b == 0xFC || b == 0xFF {
                actions.append(.reset)
            }
            i += 1
        }
        return actions
    }
}
