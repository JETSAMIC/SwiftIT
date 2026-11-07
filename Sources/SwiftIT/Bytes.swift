/// Bytes.swift
///
/// Bounds-checked little-endian readers over a zero-based byte array,
/// plus CP437 string decoding. Every read either succeeds or returns a
/// caller-chosen fallback; nothing in here can trap on hostile input.

import Foundation

extension Array where Element == UInt8 {

    /// Byte at `offset`, or 0 when out of range.
    @inline(__always)
    func u8(_ offset: Int) -> UInt8 {
        offset >= 0 && offset < count ? self[offset] : 0
    }

    /// Little-endian `UInt16` at `offset`; missing bytes read as 0.
    @inline(__always)
    func u16(_ offset: Int) -> UInt16 {
        UInt16(u8(offset)) | (UInt16(u8(offset &+ 1)) << 8)
    }

    /// Little-endian `UInt32` at `offset`; missing bytes read as 0.
    @inline(__always)
    func u32(_ offset: Int) -> UInt32 {
        UInt32(u8(offset))
            | (UInt32(u8(offset &+ 1)) << 8)
            | (UInt32(u8(offset &+ 2)) << 16)
            | (UInt32(u8(offset &+ 3)) << 24)
    }

    /// True when `length` bytes starting at `offset` lie inside the array.
    @inline(__always)
    func contains(offset: Int, length: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= count && length <= count - offset
    }

    /// Decode a fixed-width, NUL-terminated CP437 string. Stops at the
    /// first NUL, then trims trailing spaces (IT pads names with both).
    func cp437String(at offset: Int, maxLength: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var i = 0
        while i < maxLength {
            let b = u8(offset &+ i)
            if b == 0 { break }
            scalars.append(CP437.scalar(for: b))
            i += 1
        }
        var s = String(scalars)
        while s.last == " " { s.removeLast() }
        return s
    }
}

/// IBM code page 437, the character set every DOS tracker wrote names in.
enum CP437 {
    /// Unicode scalars for bytes 0x80...0xFF (Unicode Consortium
    /// `VENDORS/MICSFT/PC/CP437.TXT`).
    private static let high: [UInt32] = [
        0x00C7, 0x00FC, 0x00E9, 0x00E2, 0x00E4, 0x00E0, 0x00E5, 0x00E7,
        0x00EA, 0x00EB, 0x00E8, 0x00EF, 0x00EE, 0x00EC, 0x00C4, 0x00C5,
        0x00C9, 0x00E6, 0x00C6, 0x00F4, 0x00F6, 0x00F2, 0x00FB, 0x00F9,
        0x00FF, 0x00D6, 0x00DC, 0x00A2, 0x00A3, 0x00A5, 0x20A7, 0x0192,
        0x00E1, 0x00ED, 0x00F3, 0x00FA, 0x00F1, 0x00D1, 0x00AA, 0x00BA,
        0x00BF, 0x2310, 0x00AC, 0x00BD, 0x00BC, 0x00A1, 0x00AB, 0x00BB,
        0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
        0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
        0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
        0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
        0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
        0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
        0x03B1, 0x00DF, 0x0393, 0x03C0, 0x03A3, 0x03C3, 0x00B5, 0x03C4,
        0x03A6, 0x0398, 0x03A9, 0x03B4, 0x221E, 0x03C6, 0x03B5, 0x2229,
        0x2261, 0x00B1, 0x2265, 0x2264, 0x2320, 0x2321, 0x00F7, 0x2248,
        0x00B0, 0x2219, 0x00B7, 0x221A, 0x207F, 0x00B2, 0x25A0, 0x00A0,
    ]

    static func scalar(for byte: UInt8) -> Unicode.Scalar {
        if byte < 0x80 { return Unicode.Scalar(byte) }
        // Every entry in the table is a valid BMP scalar.
        return Unicode.Scalar(high[Int(byte) - 0x80]) ?? "?"
    }
}
