# The Impulse Tracker (IT) Module Format

A byte-level reference for Impulse Tracker `.it` modules, written as the implementation spec for SwiftIT and usable on its own by anyone reading or writing IT files.

## Sources

- **ITTECH.TXT** by Jeffrey Lim, shipped with Impulse Tracker 2.14 (patch 5 is the final revision). This is the format's canonical document. It is not reproduced here; copies sit in the Schism Tracker repository and in the `ittech` Rust crate's source tree.
- **OpenMPT wiki, "Development: Formats/IT"**: documents what ITTECH.TXT leaves out (edit history, MIDI macro block size, the envelope carry bit, and how compressed stereo and the IT 2.15 variant are chosen).
- **De-facto behaviour** of Impulse Tracker 2.14/2.15, as reproduced by OpenMPT and Schism Tracker. Where this document describes playback behaviour that ITTECH.TXT doesn't specify, the section says so and names the behaviour SwiftIT follows.

All multi-byte integers are **little-endian**. Offsets are hexadecimal. "Parapointer" means an absolute 32-bit file offset. Text is IBM code page 437 (CP437), NUL-terminated or space-padded.

---

## Contents

1. [File layout](#1-file-layout)
2. [Header (`IMPM`)](#2-header-impm)
3. [Data after the parapointer tables](#3-data-after-the-parapointer-tables)
4. [Instruments (`IMPI`)](#4-instruments-impi)
5. [Envelopes](#5-envelopes)
6. [Samples (`IMPS`)](#6-samples-imps)
7. [Sample data and compression](#7-sample-data-and-compression)
8. [Patterns](#8-patterns)
9. [Volume column](#9-volume-column)
10. [Effects](#10-effects)
11. [Playback model](#11-playback-model)
12. [Quirks, ambiguities, and SwiftIT decisions](#12-quirks-ambiguities-and-swiftit-decisions)

---

## 1. File layout

```
0x0000  IMPM header (192 bytes)
0x00C0  Order list               OrdNum bytes
        Instrument parapointers  InsNum x u32
        Sample parapointers      SmpNum x u32
        Pattern parapointers     PatNum x u32
        [Edit history]           if Special bit 1
        [MIDI macro config]      if Special bit 3 (4896 bytes)
        ... instruments, sample headers, patterns, sample data, message,
            all located through parapointers, in any order
```

Every structure after the tables is reached through a parapointer, so a reader never needs to know the order. A pattern parapointer of 0 means "empty 64-row pattern". An instrument or sample parapointer of 0 means an empty slot. ITTECH.TXT doesn't say this for instruments and samples, but other trackers write it.

## 2. Header (`IMPM`)

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0x00 | 4 | `IMPM` | Signature |
| 0x04 | 26 | SongName | NUL-terminated |
| 0x1E | 1 | PHiligt (minor) | Rows per beat (valid if Special bit 2) |
| 0x1F | 1 | PHiligt (major) | Rows per measure |
| 0x20 | 2 | OrdNum | Number of order-list bytes |
| 0x22 | 2 | InsNum | Number of instrument parapointers |
| 0x24 | 2 | SmpNum | Number of sample parapointers |
| 0x26 | 2 | PatNum | Number of pattern parapointers |
| 0x28 | 2 | Cwt/v | Created-with tracker version (0x0214 = IT 2.14) |
| 0x2A | 2 | Cmwt | Compatible-with version |
| 0x2C | 2 | Flags | See below |
| 0x2E | 2 | Special | See below |
| 0x30 | 1 | GV | Global volume 0...128 |
| 0x31 | 1 | MV | Mix volume 0...128 |
| 0x32 | 1 | IS | Initial speed (ticks per row) 1...255 |
| 0x33 | 1 | IT | Initial tempo (BPM) 31...255 |
| 0x34 | 1 | Sep | Stereo separation 0...128 |
| 0x35 | 1 | PWD | MIDI pitch-wheel depth |
| 0x36 | 2 | MsgLgth | Song message length |
| 0x38 | 4 | MsgOff | Song message parapointer |
| 0x3C | 4 | Reserved | Edit timer (encrypted from IT 2.08); ignore |
| 0x40 | 64 | ChnlPan | Per-channel pan |
| 0x80 | 64 | ChnlVol | Per-channel volume 0...64 |
| 0xC0 | OrdNum | Orders | Order list |

**Flags**

| Bit | Meaning |
|---|---|
| 0 | Stereo (off = mono output) |
| 1 | Vol0MixOptimizations: don't mix voices whose volume is 0 |
| 2 | Instrument mode (off = sample mode) |
| 3 | Linear slides (off = Amiga slides) |
| 4 | Old effects (see [section 12](#12-quirks-ambiguities-and-swiftit-decisions)) |
| 5 | Compatible Gxx: G shares memory with E/F, Gxx with an instrument retriggers envelopes |
| 6 | Use MIDI pitch controller (depth = PWD) |
| 7 | Request embedded MIDI configuration |

**Special**

| Bit | Meaning |
|---|---|
| 0 | Song message attached |
| 1 | Edit history present (OpenMPT wiki) |
| 2 | Row highlight bytes valid |
| 3 | MIDI macro configuration embedded |

**Channel pan byte:** 0...64 is a pan position (0 = left, 32 = centre, 64 = right). 100 means surround. Adding 128 disables the channel: its effects still run, but nothing is heard.

**Order list:** values 0...199 are pattern numbers, 254 (`+++`) means "skip to the next order", and 255 (`---`) means end of song. An order naming a pattern that doesn't exist plays as an empty 64-row pattern.

**Cwt/v and Cmwt.** Several version-dependent behaviours key off these fields:
- `Cmwt < 0x0200` selects the **old (IT 1.x) instrument layout**. Both layouts begin with `IMPI`, so you can't tell them apart from the bytes.
- `Cwt < 0x0214`: very old IT versions didn't clear the sample stereo flag, so ignore it.
- Many trackers write their own Cwt values (Schism 0x1xxx, OpenMPT 0x5xxx, ModPlug 0x0888, and so on). Don't use these fields to infer anything beyond the two rules above.

## 3. Data after the parapointer tables

**Edit history** (Special bit 1). A u16 count, then count x 8 bytes, each holding a FAT date, a FAT time, and a u32 run time in 1/18.2 s units. Many writers set the bit and store a count of 0.

**MIDI macro configuration** (Special bit 3). 4896 bytes: 153 fields of 32 bytes, each a NUL-terminated ASCII string.

| Index | Count | Macros |
|---|---|---|
| 0 | 9 | Global: start, stop, tick, note on, note off, volume, pan, bank select, program change |
| 9 | 16 | Parametered `SF0`...`SFF`, run by `Z00`...`Z7F` |
| 25 | 128 | Fixed `Z80`...`ZFF` |

Impulse Tracker's default sets `SF0 = "F0F000z"` (filter cutoff = z) and `Z80`...`Z8F = "F0F001xx"` with xx = 00, 08, ..., 78 (filter resonance). In a macro string, `F0 F0 00 xx` sets the internal filter cutoff and `F0 F0 01 xx` sets resonance. `z` substitutes the Zxx parameter.

**Song message.** MsgLgth bytes at MsgOff (Special bit 0). Lines end with CR (0x0D), and the text ends at NUL.

## 4. Instruments (`IMPI`)

Instruments are 554 bytes in both layouts.

### New format (Cmwt >= 0x200)

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0x00 | 4 | `IMPI` | |
| 0x04 | 12 | DOS filename | |
| 0x11 | 1 | NNA | 0 cut, 1 continue, 2 note off, 3 note fade |
| 0x12 | 1 | DCT | 0 off, 1 note, 2 sample, 3 instrument |
| 0x13 | 1 | DCA | 0 cut, 1 note off, 2 note fade |
| 0x14 | 2 | FadeOut | Subtracted per tick from a fade counter that starts at 1024 (ITTECH says the range is 0...128; IT 2.x writes up to 256) |
| 0x16 | 1 | PPS | Pitch-pan separation, signed -32...32 |
| 0x17 | 1 | PPC | Pitch-pan centre note 0...119 |
| 0x18 | 1 | GbV | Instrument global volume 0...128 |
| 0x19 | 1 | DfP | Default pan 0...64; **bit 7 set = don't use** |
| 0x1A | 1 | RV | Random volume variation, percent |
| 0x1B | 1 | RP | Random pan variation 0...64 |
| 0x1C | 2 | TrkVers | Instrument files only |
| 0x1E | 1 | NoS | Instrument files only |
| 0x20 | 26 | Name | |
| 0x3A | 1 | IFC | Initial filter cutoff 0...127; bit 7 = enabled |
| 0x3B | 1 | IFR | Initial filter resonance 0...127; bit 7 = enabled |
| 0x3C | 1 | MCh | MIDI channel |
| 0x3D | 1 | MPr | MIDI program |
| 0x3E | 2 | MIDIBnk | MIDI bank |
| 0x40 | 240 | Keyboard | 120 x (note, sample): the note played and the 1-based sample (0 = none) for each key C-0...B-9 |
| 0x130 | 82 | Volume envelope | |
| 0x182 | 82 | Panning envelope | |
| 0x1D4 | 82 | Pitch envelope | |

Note the inverted pan sense: the sample DfP bit 7 means "use", while the instrument DfP bit 7 means "don't use".

### Old format (Cmwt < 0x200)

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0x00 | 4 | `IMPI` | |
| 0x04 | 12 | DOS filename | |
| 0x11 | 1 | Flg | bit 0 envelope on, bit 1 loop, bit 2 sustain loop |
| 0x12 | 1 | VLS | Loop start node |
| 0x13 | 1 | VLE | Loop end node |
| 0x14 | 1 | SLS | Sustain start node |
| 0x15 | 1 | SLE | Sustain end node |
| 0x18 | 2 | FadeOut | 0...64 against a fade count of 512 |
| 0x1A | 1 | NNA | As the new format |
| 0x1B | 1 | DNC | Duplicate note check: 0 off, 1 on |
| 0x1C | 2 | TrkVers | |
| 0x1E | 1 | NoS | |
| 0x20 | 26 | Name | |
| 0x40 | 240 | Keyboard | As the new format |
| 0x130 | 200 | Volume curve | Pre-computed per-tick curve (redundant with the nodes) |
| 0x1F8 | 50 | Nodes | 25 x (tick u8, value u8 0...64); tick 0xFF ends the list |

Old instruments have no panning or pitch envelope, no filter, and no pan or global-volume fields. SwiftIT converts them to the new shape as follows:
- **FadeOut:** doubled, to put it on the 1024 scale.
- **DNC:** on becomes DCT = note, DCA = cut.
- **Global volume:** 128.
- **Default pan:** none.

## 5. Envelopes

Each new-format envelope is 82 bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | Flags: bit 0 on, bit 1 loop, bit 2 sustain loop, bit 3 carry (Schism/OpenMPT extension), bit 7 filter (pitch envelope only) |
| 1 | 1 | Number of nodes (max 25) |
| 2 | 1 | Loop begin node |
| 3 | 1 | Loop end node |
| 4 | 1 | Sustain begin node |
| 5 | 1 | Sustain end node |
| 6 | 75 | 25 x (value i8, tick u16) |
| 81 | 1 | Reserved |

Value ranges: volume 0...64, panning -32...32, pitch -32...32 (half-semitones, so ±16 semitones). As a filter envelope, the pitch envelope's value scales the cutoff.

**Evaluation (per tick).** Each tick, the player:
1. Takes the value at the current position, linearly interpolating between neighbouring nodes.
2. Increments the position.
3. If the sustain loop is on and the key is held and the position is past the sustain-end node's tick, jumps back to the sustain-start tick.
4. Otherwise, if the loop is on and the position is past the loop-end node's tick, jumps back to the loop-start tick.

Reaching the end of a non-looping volume envelope starts the fadeout. If the last node's value is 0, the voice stops.

**Sanitizing (SwiftIT).** On load, SwiftIT:
- Keeps at most 25 nodes.
- Makes ticks non-decreasing.
- Clamps loop and sustain indices into the node range, with start <= end.
- Clamps values to their ranges.
- Disables an envelope that is enabled but has no nodes.

## 6. Samples (`IMPS`)

Each sample header is 80 bytes.

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0x00 | 4 | `IMPS` | |
| 0x04 | 12 | DOS filename | |
| 0x11 | 1 | GvL | Sample global volume 0...64 |
| 0x12 | 1 | Flg | See below |
| 0x13 | 1 | Vol | Default volume 0...64 |
| 0x14 | 26 | Name | |
| 0x2E | 1 | Cvt | See below |
| 0x2F | 1 | DfP | Default pan 0...64; bit 7 = use |
| 0x30 | 4 | Length | In sample frames, not bytes |
| 0x34 | 4 | Loop begin | |
| 0x38 | 4 | Loop end | Frame after the last loop frame |
| 0x3C | 4 | C5Speed | Hz for C-5, 0...9999999 |
| 0x40 | 4 | Sustain begin | |
| 0x44 | 4 | Sustain end | |
| 0x48 | 4 | SamplePointer | Parapointer to the data |
| 0x4C | 1 | ViS | Auto-vibrato speed 0...64 |
| 0x4D | 1 | ViD | Auto-vibrato depth 0...64 |
| 0x4E | 1 | ViR | Auto-vibrato rate (depth ramp) 0...64 |
| 0x4F | 1 | ViT | Waveform: 0 sine, 1 ramp down, 2 square, 3 random |

**Flg:** bit 0 = has data, 1 = 16-bit, 2 = stereo, 3 = compressed, 4 = loop, 5 = sustain loop, 6 = ping-pong loop, 7 = ping-pong sustain loop.

**Cvt:**

| Bit | Meaning |
|---|---|
| 0 | Signed (off = unsigned) |
| 1 | Big-endian 16-bit |
| 2 | Delta-encoded; for compressed samples, selects IT 2.15 |
| 3 | Byte-delta (PTM 16-bit) |
| 4 | 12-bit TX-Wave (not supported by modern players) |
| 5 | Stereo prompt (UI only) |

ModPlug writes Cvt = 0xFF on 8-bit samples to mean 4-bit ADPCM.

**Sanitizing (SwiftIT).**
- Volumes are clamped.
- A C5Speed of 0 becomes 8363.
- Loop end is clamped to the decoded length.
- A loop with start >= end is dropped.

## 7. Sample data and compression

### Uncompressed

There are `Length` frames per channel. Stereo data is stored as all left frames, then all right frames (split, not interleaved). Delta decoding accumulates in the sample's own width with wrap-around, then the signed/unsigned conversion applies. In byte-delta (PTM) mode, the raw byte stream is delta-decoded and then paired into 16-bit words.

### ModPlug ADPCM

The data starts with a 16-byte table of signed deltas, followed by `ceil(Length / 2)` bytes. Each byte holds two 4-bit table indices, low nibble first, and each decoded delta accumulates into a signed 8-bit value.

### IT 2.14 / 2.15 compression (Flg bit 3)

The data is a sequence of **blocks**. Each block is a u16 byte count, not counting the u16 itself, followed by that many bytes. A block decodes to at most 0x8000 frames (8-bit) or 0x4000 frames (16-bit). The last block covers the remainder of `Length`.

At the start of every block, the player resets:
- bit width W to 9 (8-bit) or 17 (16-bit)
- accumulators d1 = d2 = 0

Bits are read **LSB-first**. Each step reads W bits as an unsigned value v:

| Width | Escape condition | New width |
|---|---|---|
| 1...6 | v == 1 << (W-1) | read 3 bits (8-bit) / 4 bits (16-bit), n = that + 1, W = n < W ? n : n + 1 |
| 7...W-1 | border < v <= border + 8 (16) where border = (0xFF (0xFFFF) >> (9 (17) - W)) - 4 (8) | n = v - border, W = n < W ? n : n + 1 |
| 9 (17) | bit 8 (16) of v set | W = (v + 1) & 0xFF |

Any other v is a delta, sign-extended from W bits (from 8 or 16 bits when W is 9 or 17). The decoder then sets d1 += delta and d2 += d1, both wrapping at the sample width, and outputs **d1 for IT 2.14** or **d2 for IT 2.15**.

The variant is selected by **Cvt bit 2** of the sample, which is what Impulse Tracker, OpenMPT, and Schism key on. Cmwt is not involved.

**Compressed stereo** stores two complete compressed streams, left then right. The right stream starts at the byte after the left stream's last block.

**Error handling (SwiftIT).** A width outside 1...W, a block that runs out of bits, or a block header past end of file stops decoding. The sample is kept at the length actually decoded and flagged `isTruncated`. Output grows only as bits are consumed (at least one bit per sample), so a declared length can't force an allocation.

## 8. Patterns

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | Packed data length (excluding this 8-byte header) |
| 2 | 2 | Rows (IT writes 32...200; OpenMPT allows 1...1024) |
| 4 | 4 | Reserved |
| 8 | n | Packed data |

The packed stream is read as follows (ITTECH.TXT):

```
read channelvariable
if channelvariable == 0: end of row
channel = (channelvariable - 1) & 63
if channelvariable & 0x80: maskvariable = read byte, remember it for channel
else: maskvariable = remembered mask for channel
mask & 0x01: note = read byte          (remember)
mask & 0x02: instrument = read byte    (remember)
mask & 0x04: volume/pan = read byte    (remember)
mask & 0x08: command, value = 2 bytes  (remember)
mask & 0x10: note = remembered note
mask & 0x20: instrument = remembered instrument
mask & 0x40: volume = remembered volume
mask & 0x80: command, value = remembered command, value
```

**Note values:**

| Value | Meaning |
|---|---|
| 0...119 | C-0...B-9 (C-5 = 60) |
| 255 | Note off (`===`) |
| 254 | Note cut (`^^^`) |
| any other | Note fade (`~~~`) |

The instrument number is 1...99; in sample mode it is the sample number. Effect commands are 1...26 = A...Z.

SwiftIT throws for a row count of 0 or more than 1024, and for a stream that ends inside a channel entry. Data ending before the last row leaves the remaining rows empty.

## 9. Volume column

| Value | Command | Notes |
|---|---|---|
| 0...64 | Set volume | |
| 65...74 | `a` fine volume up x | First tick; memory shared by a-d |
| 75...84 | `b` fine volume down x | First tick |
| 85...94 | `c` volume slide up x | Non-first ticks |
| 95...104 | `d` volume slide down x | Non-first ticks |
| 105...114 | `e` pitch slide down 4x | Uses Exx/Fxx memory |
| 115...124 | `f` pitch slide up 4x | Uses Exx/Fxx memory |
| 128...192 | Set pan 0...64 | |
| 193...202 | `g` tone portamento | Speed from table {0,1,4,8,16,32,64,96,128,255}; uses Gxx memory |
| 203...212 | `h` vibrato depth x | Uses Hxx speed |

Values 125...127 and 213...255 are unused and ignored.

## 10. Effects

Units used in this table:
- "Units" in pitch slides are 1/768 octave in linear mode and one step of the x4 Amiga period scale in Amiga mode.
- "First tick" means tick 0 of the row.

| Cmd | Effect | Semantics (SwiftIT) |
|---|---|---|
| Axx | Set speed | xx > 0 |
| Bxx | Jump to order xx | Combines with Cxx |
| Cxx | Pattern break | Next order, row xx (hex, not BCD); out of range becomes row 0 |
| Dxy | Volume slide | `x0` up and `0y` down on non-first ticks; `xF` fine up and `Fy` fine down on the first tick; DF0/D0F are regular slides; other combinations are ignored. Memory shared with K and L |
| Exx | Portamento down | `xx < E0` 4·xx units per non-first tick; `EFx` 4·x and `EEx` x units on the first tick. Memory shared with F (and G when Flags bit 5) |
| Fxx | Portamento up | As E |
| Gxx | Tone portamento | 4·xx units per non-first tick toward the note; doesn't retrigger |
| Hxy | Vibrato | Speed x, depth y·4. Applied every tick, including the first (old effects: non-first only, double depth) |
| Ixy | Tremor | On x ticks, off y ticks (0 → 1; old effects: x+1, y+1) |
| Jxy | Arpeggio | Ticks cycle 0, +x, +y semitones |
| Kxy | Vibrato + volume slide | H memory plus D memory |
| Lxy | Tone portamento + volume slide | G memory plus D memory |
| Mxx | Channel volume | 0...64 |
| Nxy | Channel volume slide | Like D, with its own memory |
| Oxx | Sample offset | xx·256 + SAy·65536. Past the end: ignored (old effects: play from end) |
| Pxy | Panning slide | `P0x` right, `Px0` left, `PFx` fine right, `PxF` fine left |
| Qxy | Retrigger | Every y ticks, with volume change x (see below); nibble-wise memory; counter persists across rows |
| Rxy | Tremolo | Speed x, depth y |
| S0x | (set filter) | Ignored |
| S1x | Glissando | Ignored |
| S2x | Finetune | Ignored |
| S3x / S4x / S5x | Waveform | Vibrato / tremolo / panbrello waveform: 0 sine, 1 ramp down, 2 square, 3 random |
| S6x | Fine pattern delay | Adds x ticks to the row |
| S70 / S71 / S72 | Past notes | Cut / off / fade this channel's background voices |
| S73...S76 | NNA override | Cut / continue / off / fade for the current note |
| S77 / S78 | Volume envelope | Off / on |
| S79 / S7A | Panning envelope | Off / on |
| S7B / S7C | Pitch envelope | Off / on |
| S8x | Set pan | x·64/15 |
| S90 / S91 | Surround | Off / on |
| SAy | High sample offset | Used by Oxx |
| SB0 / SBx | Pattern loop | SB0 sets the loop start; SBx loops x times. After a loop finishes, the start moves to the next row |
| SCx | Note cut | After x ticks (SC0 = SC1) |
| SDx | Note delay | x ticks (SD0 = SD1); ignored if x >= speed |
| SEx | Pattern delay | x rows; the first SEx in a row wins |
| SFx | Active macro | Selects the macro used by Z00...Z7F |
| S00 | | Recalls the last Sxy |
| Txx | Tempo | xx >= 0x20 sets the tempo; `T0x` / `T1x` slide down / up by x per non-first tick (32...255) |
| Uxy | Fine vibrato | As H, with depth y (not ×4); shares H memory |
| Vxx | Global volume | 0...0x80 |
| Wxy | Global volume slide | Like D |
| Xxx | Set pan | 00...FF |
| Yxy | Panbrello | Speed x, depth y |
| Zxx | MIDI macro | 00...7F runs SFx with z = xx; 80...FF runs fixed macro xx-80. Only the filter macros are interpreted |

The retrigger volume change x (default IT behaviour) is:

| x | Change | x | Change |
|---|---|---|---|
| 0 | none | 8 | none |
| 1 | -1 | 9 | +1 |
| 2 | -2 | A | +2 |
| 3 | -4 | B | +4 |
| 4 | -8 | C | +8 |
| 5 | -16 | D | +16 |
| 6 | ×2/3 | E | ×3/2 |
| 7 | ×1/2 | F | ×2 |

## 11. Playback model

**Timing.** A tick lasts 2.5 / tempo seconds. A row lasts speed × (1 + pattern delay) + fine delay ticks. Row-level effects run on tick 0, and continuous effects run on the ticks after it.

**Frequency.** For a sample's C5Speed and note n, the frequency is `C5Speed × 2^((n − 60)/12)`. Slides change the frequency as follows:
- **Linear mode:** multiply by 2^(units/768).
- **Amiga mode:** convert to a period P = 14317056 / f (1712 at 8363 Hz), add or subtract the units, and convert back.

**Volume** (all factors normalised to 0...1):

```
note volume (0...64, + tremolo) × sample GvL (0...64) × instrument GbV (0...128)
× channel volume (0...64) × volume envelope × fade (0...1024) × global volume (0...128)
```

In SwiftIT, output is further scaled by MV / 128 and clamped to ±1.

**Panning.** In priority order:
1. Channel pan.
2. Instrument DfP (if used) overrides it.
3. Sample DfP (if used) overrides that.
4. Pitch-pan separation adds `(note − PPC) × PPS / 8`.
5. The panning envelope swings within the available headroom.
6. Separation scales the distance from centre.

Mono files output centre-panned audio. Surround outputs the left signal and an inverted right signal.

**Instrument mode.** The keyboard table maps the played note to a sample and a transposed note. A note with sample 0 is ignored. A note without an instrument number keeps the channel's current volume. An instrument number resets the volume to the sample's default.

**NNA (instrument mode only).** When a new note starts, the playing voice's NNA decides what happens to it:

| NNA | Effect on the old voice |
|---|---|
| cut | Stops |
| continue | Moves to the background |
| note off | Moves to the background and is released |
| note fade | Moves to the background and starts fading |

Tone portamento never triggers NNA. In sample mode, a new note always cuts the old one. SwiftIT has 256 voices, the same as IT's virtual channel limit. When the pool is full, it steals the quietest background voice.

**DCT/DCA.** Before NNA runs, voices from the same host channel that play the same instrument are checked for duplicates. DCT decides what counts as a duplicate: the same pattern note, the same sample, or any voice of the same instrument. Matches receive the DCA (cut, note off, or fade).

**Note off.** Releases sustain loops (sample and envelope). In instrument mode it also starts the fadeout when the volume envelope is off or has a loop. In sample mode there is no fadeout, so note fade cuts the note.

**Fadeout.** Each tick while fading, the fade counter (starting at 1024) decreases by FadeOut. At 0 the voice stops.

**Auto-vibrato.** Each tick:
- Depth ramps up by ViR/256, up to ViD.
- Phase advances by ViS on a 256-step cycle.
- The pitch offset is `wave × depth / 64` in 1/64 semitone.

**Filter** (from Jeffrey Lim's description, as used by Schism Tracker and OpenMPT):

```
fc   = 110 × 2^(0.25 + cutoff × (envmod + 256) / (24 × 512))   [Hz, clamped 120...min(20000, mixrate/4)]
damp = 10^(−(24/128) × resonance / 20)
r    = mixrate / (2π fc);  d = damp·r + damp − 1;  e = r²
y[n] = x[n]/(1+d+e) + y[n−1]·(d+2e)/(1+d+e) − y[n−2]·e/(1+d+e)
```

`envmod` is 256 without a filter envelope, and `(value + 32) × 8` with one.

The recursion is stable only while r > 1/2 (fc < mixrate / π). With strong resonance near Nyquist it diverges, so SwiftIT clamps fc to mixrate / 4. Impulse Tracker's own ~5 kHz maximum at 44.1 kHz stays far inside that limit. The filter is active when cutoff < 127, when resonance > 0, or when a filter envelope is running.

**End of song.** Impulse Tracker itself loops forever. SwiftIT ends the song when either of these happens:
- the order list runs out (255 or the last entry)
- playback would revisit an (order, row) already played, other than through an SBx loop

Revisits during pattern loops are allowed, but more than 65,536 revisits in a row also end the song, which bounds pathological nested loops. `ITMixer.Options.loopsSong` restores IT's endless behaviour.

## 12. Quirks, ambiguities, and SwiftIT decisions

- **Old effects (Flags bit 4)** changes three behaviours: vibrato is twice as deep and skips the first tick, Oxx past the end plays from the end, and tremor uses x+1/y+1.
- **Compatible Gxx (Flags bit 5)** links G memory with E/F and restarts envelopes when Gxx has an instrument. SwiftIT doesn't rescale the frequency when the sample changes during Gxx.
- **IT 2.15 selection** uses Cvt bit 2, not Cmwt; see the OpenMPT wiki. The original SwiftIT used Cmwt, which was wrong.
- **Pattern channel** is `(byte − 1) & 63`. ITTECH.TXT says so explicitly, and channel bytes 65...127 wrap.
- **SEx repetitions** are treated as ordinary non-first ticks. Impulse Tracker re-runs some first-tick effects on each repeat. SwiftIT doesn't, which differs only for fine slides inside a pattern delay.
- **Approximations in the mixer**, chosen for simplicity and documented in the README:
  - Linear interpolation with no volume ramping.
  - Vibrato in Amiga mode is applied as a linear pitch offset.
  - Tremolo, panbrello, and auto-vibrato depth scaling follow OpenMPT's documented ranges and are not bit-exact to IT.
  - The filter envelope modifier range is from OpenMPT.
- **Not interpreted:**
  - MIDI output macros (anything other than `F0F000`/`F0F001`).
  - The global MIDI macros.
  - The MIDI pitch controller (Flags bit 6).
  - 12-bit TX-Wave samples.
  - OpenMPT's extension chunks after the module data.
  - The Vol0MixOptimizations flag, which only affects CPU use.
- **Resource limits (SwiftIT).**
  - Pattern cells are capped at 8 Mi summed over distinct patterns.
  - Decoded sample frames are capped at `8 × file size + 1 Mi`.
  - Parapointers shared between slots are decoded once.
  - Exceeding a cap throws `ITError.limitExceeded`.
