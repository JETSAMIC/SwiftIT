# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - Unreleased (proposed initial release)

### Added
- `ITFile` parser for Impulse Tracker modules:
  - `IMPM` header with `Flags` / `Special` option sets, row highlights, CP437 song name and message
  - order list and embedded MIDI macro configuration (`ITMIDIConfiguration`)
  - new-format and IT 1.x (`Cmwt < 0x200`) instruments with sanitized envelopes, including the carry and filter bits
  - sample headers; 8/16-bit, signed/unsigned, big-endian, delta, PTM byte-delta, and ModPlug ADPCM PCM
  - stereo samples
  - IT 2.14 / 2.15 compressed samples (8/16-bit, mono/stereo)
  - packed patterns decoded into `ITPattern.Cell` values with `ITNote` and `ITVolumeCommand`
- `ITError`, with typed cases for every structural failure and resource limit.
- `ITSample.isTruncated` for sample data that ends early (decoded partially instead of throwing).
- `ITMixer`, a tick-based playback engine:
  - 64 host channels and 256 voices, with NNA / DCT / DCA
  - linear and Amiga slides
  - the IT effect set with shared effect memory, and the volume column
  - volume / panning / pitch / filter envelopes, fadeout, and auto-vibrato
  - the IT resonant filter, driven by `IFC` / `IFR` / `Zxx`
  - surround, separation, and mono output
- `ITMixer.Options.loopsSong`. Without it, playback ends at the end of the order list or on a row revisit, and runaway pattern loops are capped.
- `Reference/IT-Format.md`, the DocC catalog, `.spi.yml`, and the org CI workflow.
- Truncation-at-every-offset and seeded mutation fuzz tests.

### Fixed (relative to the pre-release code on `main`)
- Old-format instruments were detected by magic (both formats use `IMPI`) and read from the wrong offsets.
- Instrument default pan bit 7 was inverted.
- The IT 2.15 codec was chosen by `Cmwt` instead of the sample's `Cvt` bit 2.
- Stereo PCM was read interleaved instead of as split L/R blocks, and compressed stereo dropped the right channel.
- Delta PCM did not wrap at the sample width.
- Note-off (255) was indistinguishable from an empty note.
- Pattern channel bytes were rejected instead of masked with `& 63`.
- `Data` slices and malformed files could trap (out-of-bounds reads, unbounded allocations).
- Envelopes and fadeout advanced per audio frame instead of per tick.
- Tone portamento never had a target.
- Several documented effects were no-ops.
- Songs that loop without `Bxx` rendered forever.

### Changed
- The public API was reshaped before the first tag:
  - Option sets replace raw flag words.
  - Optional values replace sentinel bytes.
  - PCM is `[Int16]`.
  - `finished` is now `isFinished`.
  - `render(...)` returns the number of song frames and zero-fills the tail.
