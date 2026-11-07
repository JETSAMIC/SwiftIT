/// ITError.swift
///
/// The single error type thrown by the SwiftIT parser.

import Foundation

/// Errors thrown by ``ITFile/init(data:)`` when the input is not a
/// well-formed Impulse Tracker module.
///
/// SwiftIT treats every structural problem (a bad magic, a table that
/// runs past the end of the file, a pattern whose packed stream ends in
/// the middle of an entry) as an error. The one deliberate exception is
/// sample *PCM data* that ends early: real-world files are frequently
/// cut short at the tail, so the parser decodes as much as is present
/// and sets ``ITSample/isTruncated`` instead of throwing.
public enum ITError: Error, Sendable, Equatable, Hashable, LocalizedError {

    /// A structure in the file that a parapointer points at.
    public enum Structure: String, Sendable, Equatable, Hashable {
        /// An instrument header (`IMPI`, 554 bytes).
        case instrument
        /// A sample header (`IMPS`, 80 bytes).
        case sample
        /// A packed pattern (8-byte header plus packed data).
        case pattern
    }

    /// A resource ceiling that protects the host from hostile files.
    public enum Limit: String, Sendable, Equatable, Hashable {
        /// The sum of `rows x channels` across all distinct patterns
        /// exceeded ``ITFile/maximumPatternCells``.
        case patternCells
        /// The sum of decoded sample frames (per channel) exceeded the
        /// budget derived from the file size (see ``ITFile/init(data:)``).
        case sampleFrames
    }

    /// The first four bytes are not `IMPM`.
    case notAnITFile

    /// The file ends inside the 192-byte header, the order list, or the
    /// instrument / sample / pattern parapointer tables.
    case truncatedHeader

    /// A non-zero parapointer points at a structure that does not fit
    /// inside the file.
    ///
    /// - Parameters:
    ///   - structure: The kind of structure being read.
    ///   - index: Zero-based index of the structure in its table.
    ///   - offset: The parapointer value read from the file.
    case invalidOffset(Structure, index: Int, offset: Int)

    /// An instrument parapointer does not point at an `IMPI` header.
    case invalidInstrumentHeader(index: Int)

    /// A sample parapointer does not point at an `IMPS` header.
    case invalidSampleHeader(index: Int)

    /// A pattern declares 0 or more than 1024 rows, or its packed data
    /// ends in the middle of a channel entry.
    case invalidPattern(index: Int)

    /// Decoding the file would exceed a resource limit.
    case limitExceeded(Limit)

    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .notAnITFile:
            return "Missing IMPM signature; not an Impulse Tracker module."
        case .truncatedHeader:
            return "The file ends inside the header, order list, or parapointer tables."
        case let .invalidOffset(structure, index, offset):
            return "The \(structure.rawValue) at index \(index) points at offset \(offset), outside the file."
        case let .invalidInstrumentHeader(index):
            return "Instrument \(index) is missing its IMPI signature."
        case let .invalidSampleHeader(index):
            return "Sample \(index) is missing its IMPS signature."
        case let .invalidPattern(index):
            return "Pattern \(index) has an invalid row count or truncated packed data."
        case let .limitExceeded(limit):
            return "Decoding exceeds the \(limit.rawValue) resource limit."
        }
    }
}
