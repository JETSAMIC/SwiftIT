# The Impulse Tracker (IT) Module Format

A byte-level and behavioural reference for Impulse Tracker `.it` modules. It is the implementation spec for SwiftIT, and it is written to be usable on its own by anyone who reads, writes, or plays IT files.

Where this document describes how a module *plays* rather than how it is *stored*, it names the source of each rule: Impulse Tracker itself (IT 2.14/2.15), a named OpenMPT test case, the OpenMPT wiki, or Schism Tracker. Rules that SwiftIT adopted without such a source are marked **SwiftIT choice**.

## Contents

1. [Overview](#1-overview)
2. [Conventions](#2-conventions)
3. [Byte-level layouts](#3-byte-level-layouts)
4. [Enumerations and flags](#4-enumerations-and-flags)
5. [Algorithms](#5-algorithms)
6. [Semantics and de-facto behaviour](#6-semantics-and-de-facto-behaviour)
7. [Robustness guidance for readers](#7-robustness-guidance-for-readers)
8. [Errata](#8-errata)
9. [Implementation status](#9-implementation-status)
10. [References and provenance](#10-references-and-provenance)

---

## 1. Overview

### 1.1 What the format is

An IT file is a complete piece of tracker music: a song header, an order list, up to 99 instruments, up to 99 samples (the format allows more), up to 200 patterns of up to 64 channels, and the sample PCM. Playback is defined by the tracker's replay routine as much as by the bytes, so a faithful player must reproduce Impulse Tracker's effect semantics, not just parse the file.

Jeffrey Lim ("Pulse") wrote Impulse Tracker for DOS and released it as freeware between 1995 and 1999. It extended the Scream Tracker 3 model with:

- **Instruments** that map each of 120 notes to a sample and a transposed note.
- **Three envelopes per instrument** (volume, panning, pitch); from IT 2.x on, the pitch envelope can drive a **resonant low-pass filter** instead.
- **New Note Actions (NNA)**: a note that is interrupted can keep sounding in a *virtual channel* (up to 256 of them) while the pattern channel moves on.
- **Lossless sample compression** (IT 2.14, with a refined variant in the registered IT 2.15).
- An embedded **MIDI macro configuration** that `Zxx` commands drive.

The last public release is IT 2.14 patch 5. IT 2.15 and later were sold to registered users; their only file-format addition that matters to readers is the IT 2.15 compression variant. Lim later published the program's source code, but nothing in this document is derived from it.

### 1.2 Programs that write IT files

| Program | How to recognise it | Notes |
|---|---|---|
| Impulse Tracker 1.x–2.17 | `Cwt` = `0x0yxx` for version y.xx | Others imitate this value, so it doesn't prove anything on its own |
| Schism Tracker | `Cwt` = `0x1xxx` | `0x1050` = v0.50; later builds encode a build timestamp (see §4.2) |
| OpenMPT (current) | `Cwt` = `0x5xyy` | The reserved dword (§3.2) holds `OMPT`, or the version bytes in compatible-export mode |
| ModPlug Tracker / OpenMPT 1.17 compatible mode | `Cwt` = `0x0217`, `Cmwt` = `0x0200` | Older ModPlug builds used `0x0202`, `0x0214` with various `Cmwt` |
| OpenMPT 1.17.02.20–1.17.02.25 | `Cwt` = `Cmwt` = `0x0300` | |
| OpenMPT 1.17.02.26–1.18 | `Cwt` = `Cmwt` = `0x0888` | |
| pyIT, BeRoTracker, ITMCK, Tralala, others | `0x4xyy`, `0x6xyy`, `0x7xyz`, `0x8xyy`, … | See the OpenMPT wiki's table |
| ChibiTracker, CheeseTracker, UNMO3, converters | Imitate IT 2.14 (`0x0214`) | Fingerprints are on the OpenMPT wiki |

### 1.3 Versions, variants, and how to tell them apart

| Variant | Distinguishing data |
|---|---|
| IT module | Bytes 0–3 = `IMPM` |
| Old (IT 1.x) instrument layout | `Cmwt < 0x0200`. Both layouts start with `IMPI`, so only `Cmwt` tells them apart |
| Unsigned sample PCM | `Cvt` bit 0 clear. IT 2.01 and older wrote unsigned PCM; IT 2.02+ signed |
| IT 2.14 compressed sample | Sample `Flg` bit 3 set, `Cvt` bit 2 clear |
| IT 2.15 compressed sample | Sample `Flg` bit 3 set, `Cvt` bit 2 set |
| Edit history present | `Special` bit 1 (but see §6.1: many writers set it falsely) |
| Embedded MIDI macros | `Special` bit 3 |
| OpenMPT extensions | `XTPM` / `STPM` blocks after the sample data, ModPlug chunks after the MIDI block (§6.13) |
| MPTM (OpenMPT's own format) | Shares this layout but uses `Cwt` `0x0889`–`0x0FFF` (early versions replaced `IMPM` with `tpm.`). Not an IT file; out of scope |

Related files use the same structures on their own: an `.iti` instrument file is one `IMPI` header followed by its `IMPS` sample headers and data; an `.its` sample file is one `IMPS` header plus data.

### 1.4 Identification metadata

| Item | Value |
|---|---|
| File extension | `.it` (instruments `.iti`, samples `.its`) |
| Magic | `49 4D 50 4D` (`IMPM`) at offset 0 |
| MIME type | `audio/x-it` is in common use; nothing is registered with IANA |
| Uniform Type Identifier | Apple declares none. Apps declare their own, conforming to `public.audio` |
| SAUCE | DataType 4 (Audio), FileType 24 (IT) |

---

## 2. Conventions

- **Endianness.** All multi-byte integers are little-endian. The one exception is 16-bit sample PCM with `Cvt` bit 1 set, which is big-endian.
- **Integer types.** `u8`/`u16`/`u32` are unsigned and `i8` is signed two's complement. Offsets in tables are hexadecimal and relative to the start of the structure.
- **Parapointer.** An absolute `u32` file offset to a structure. IT uses the word "parapointer" for these even though, unlike S3M, they aren't in 16-byte paragraphs. A value of 0 means "no structure".
- **Strings.** IBM code page 437. Fixed-width name fields are NUL-terminated when shorter than the field and may be space-padded. Readers should stop at the first NUL and trim trailing spaces. Song-message lines end with CR (`0x0D`).
- **Notes.** 0 = C-0 … 119 = B-9, so C-5 = 60. Octaves run C to B.
- **Ticks and rows.** A row lasts `speed` ticks. Tick 0 of a row is the *first tick*; IT processes most row-level effects there and continuous effects on the other ticks.
- **Units used below.**
  - Volume: note volume 0–64, sample global volume 0–64, instrument global volume 0–128, channel volume 0–64, song global volume 0–128.
  - Pan: 0 (left)–64 (right). SwiftIT works internally on 0–256 (×4).
  - Pitch-slide unit: 1/768 octave (1/64 semitone) in linear mode; one step on the ×4 period scale in Amiga mode.
- **Alignment.** None. Structures may sit at any offset, in any order, and may share bytes.
- **Terminology.** *Host channel*: one of the 64 pattern channels. *Virtual channel* (voice): one playing sample instance. In instrument mode a host channel owns one foreground voice, and NNA can move voices to the background.

---

## 3. Byte-level layouts

### 3.1 File layout and locating structures

```
0x0000  IMPM header                    192 bytes
0x00C0  Order list                     OrdNum × u8
        Instrument parapointers        InsNum × u32
        Sample parapointers            SmpNum × u32
        Pattern parapointers           PatNum × u32
        [Edit history]                 if Special bit 1 (§3.3)
        [MIDI macro configuration]     if Special bit 3, 4896 bytes (§3.4)
        [ModPlug song chunks]          optional, OpenMPT/ModPlug (§6.13)
        ... instruments, sample headers, patterns, song message, sample PCM:
            anywhere, reached only through parapointers
        [XTPM ... STPM extension blocks] optional, OpenMPT (§6.13)
```

The fixed part ends at `0xC0 + OrdNum + 4·(InsNum + SmpNum + PatNum)`. A reader must never assume an order for the structures after that. Impulse Tracker writes the message, instruments, sample headers, patterns, then the sample data, but other writers differ (early ModPlug wrote patterns first and interleaved sample headers with their data).

| Parapointer | 0 means |
|---|---|
| Instrument | Empty instrument slot |
| Sample | Empty sample slot |
| Pattern | Empty 64-row pattern |
| Sample data (`SamplePointer` in `IMPS`) | No data |

### 3.2 Header (`IMPM`, 192 bytes)

| Offset | Size | Type | Name | Meaning / valid range | Notes |
|---|---|---|---|---|---|
| 0x00 | 4 | char[4] | Signature | `IMPM` | |
| 0x04 | 26 | char[26] | SongName | NUL-terminated | |
| 0x1E | 1 | u8 | PHiligt minor | Rows per beat | Valid if `Special` bit 2 |
| 0x1F | 1 | u8 | PHiligt major | Rows per measure | Valid if `Special` bit 2 |
| 0x20 | 2 | u16 | OrdNum | Order-list length in bytes | IT writes a trailing 255 |
| 0x22 | 2 | u16 | InsNum | Instrument parapointer count | |
| 0x24 | 2 | u16 | SmpNum | Sample parapointer count | |
| 0x26 | 2 | u16 | PatNum | Pattern parapointer count | |
| 0x28 | 2 | u16 | Cwt/v | Created-with tracker | §4.2 |
| 0x2A | 2 | u16 | Cmwt | Compatible-with (format version) | `< 0x0200` selects old instruments |
| 0x2C | 2 | u16 | Flags | §4.3 | |
| 0x2E | 2 | u16 | Special | §4.4 | |
| 0x30 | 1 | u8 | GV | Initial global volume 0–128 | |
| 0x31 | 1 | u8 | MV | Mix volume 0–128 | Output gain; IT's software mixer scales by it |
| 0x32 | 1 | u8 | IS | Initial speed (ticks/row) 1–255 | |
| 0x33 | 1 | u8 | IT | Initial tempo (BPM) 31–255 | `Txx` itself accepts 0x20–0xFF |
| 0x34 | 1 | u8 | Sep | Stereo separation 0–128 | 128 = full |
| 0x35 | 1 | u8 | PWD | MIDI pitch-wheel depth | Used with `Flags` bit 6 |
| 0x36 | 2 | u16 | MsgLgth | Song message length in bytes | IT 1.04+ allows up to 8000 bytes |
| 0x38 | 4 | u32 | MsgOff | Message parapointer | Valid if `Special` bit 0 |
| 0x3C | 4 | u32 | Reserved | Edit timer (§5.15) or writer ID | Schism: build date; OpenMPT: `OMPT` or version bytes; ChibiTracker: `CHBI` |
| 0x40 | 64 | u8[64] | ChnlPan | Per-channel initial pan | §4.5 |
| 0x80 | 64 | u8[64] | ChnlVol | Per-channel initial volume 0–64 | |
| 0xC0 | OrdNum | u8[] | Orders | §4.6 | |

### 3.3 Edit history (`Special` bit 1)

The edit history sits immediately after the pattern parapointer table.

| Offset | Size | Type | Name | Meaning |
|---|---|---|---|---|
| 0 | 2 | u16 | Count | Number of entries |
| 2 | 8·Count | entry[] | Entries | One per editing session |

Each entry:

| Offset | Size | Type | Meaning |
|---|---|---|---|
| 0 | 2 | u16 | FAT (MS-DOS) date the file was opened |
| 2 | 2 | u16 | FAT time |
| 4 | 4 | u32 | Time spent, in DOS timer ticks (18.2 per second) |

IT 2.08 and later write it. Many other writers set the bit and store a count of 0, and some (older Schism and BeRoTracker builds) set the bit without writing the count at all. §7 gives the rule for detecting that.

### 3.4 MIDI macro configuration (`Special` bit 3)

It follows the edit history, or the parapointer tables if there is none: 4896 bytes = 153 fields of 32 bytes. Each field is an ASCII string of up to 31 characters plus a NUL.

| Field | Count | Contents |
|---|---|---|
| 0–8 | 9 | Global macros: 0 start, 1 stop, 2 tick, 3 note on, 4 note off, 5 volume change, 6 pan change, 7 bank select, 8 program change |
| 9–24 | 16 | Parametered macros `SF0`–`SFF`, run by `Z00`–`Z7F` |
| 25–152 | 128 | Fixed macros, run by `Z80`–`ZFF` |

Default configuration (what IT uses when nothing is embedded, and what IT writes by default):

| Macro | Default |
|---|---|
| Start | `FF` |
| Stop | `FC` |
| Tick | (empty) |
| Note on | `9c n v` |
| Note off | `9c n 0` |
| Volume / pan change | (empty) |
| Bank select | `Bc 0 a 20 b` |
| Program change | `Cc p` |
| `SF0` | `F0F000z` (filter cutoff) |
| `SF1`–`SFF` | (empty) |
| `Z80`–`Z8F` | `F0F001xx`, with xx = `00`, `08`, `10`, … `78` (filter resonance in steps of 8) |
| `Z90`–`ZFF` | (empty) |

Macro syntax and semantics are in §6.11.

### 3.5 Song message (`Special` bit 0)

`MsgLgth` bytes at `MsgOff`: CP437 text, lines separated by CR (`0x0D`), terminated by NUL. ChibiTracker writes LF instead, and some converters write CR LF.

### 3.6 New-format instrument (`IMPI`, `Cmwt ≥ 0x0200`, 554 bytes)

| Offset | Size | Type | Name | Meaning / valid range | Notes |
|---|---|---|---|---|---|
| 0x00 | 4 | char[4] | Signature | `IMPI` | |
| 0x04 | 12 | char[12] | DOS filename | | |
| 0x10 | 1 | u8 | — | 0 | |
| 0x11 | 1 | u8 | NNA | New note action, §4.8 | |
| 0x12 | 1 | u8 | DCT | Duplicate check type, §4.8 | |
| 0x13 | 1 | u8 | DCA | Duplicate check action, §4.8 | |
| 0x14 | 2 | u16 | FadeOut | Amount subtracted per tick from a 1024 fade counter | ITTECH: 0–128. Values above that occur in files; SwiftIT clamps to 1024 |
| 0x16 | 1 | i8 | PPS | Pitch-pan separation −32…+32 | |
| 0x17 | 1 | u8 | PPC | Pitch-pan centre note 0–119 | |
| 0x18 | 1 | u8 | GbV | Instrument global volume 0–128 | |
| 0x19 | 1 | u8 | DfP | Default pan 0–64; **bit 7 set = don't use** | Opposite sense to the sample's DfP |
| 0x1A | 1 | u8 | RV | Random volume variation 0–100 % | |
| 0x1B | 1 | u8 | RP | Random pan variation 0–64 | ITTECH calls it unimplemented; later IT 2.x plays it (RandomPan.it) |
| 0x1C | 2 | u16 | TrkVers | Tracker version | Instrument files only |
| 0x1E | 1 | u8 | NoS | Number of samples | Instrument files only |
| 0x1F | 1 | u8 | — | | |
| 0x20 | 26 | char[26] | Name | | |
| 0x3A | 1 | u8 | IFC | Initial filter cutoff 0–127; bit 7 = set it | |
| 0x3B | 1 | u8 | IFR | Initial filter resonance 0–127; bit 7 = set it | |
| 0x3C | 1 | u8 | MCh | MIDI channel (0 = off, 1–16, 17 = mapped) | ModPlug: bit 7 + n = output to plugin n |
| 0x3D | 1 | u8 | MPr | MIDI program (255 = off) | |
| 0x3E | 2 | u16 | MIDIBnk | MIDI bank (0xFFFF = off) | |
| 0x40 | 240 | (u8,u8)[120] | Keyboard | For each key C-0…B-9: (note to play 0–119, sample 1–99 or 0 = none) | |
| 0x130 | 82 | envelope | Volume envelope | §3.8 | |
| 0x182 | 82 | envelope | Panning envelope | §3.8 | |
| 0x1D4 | 82 | envelope | Pitch / filter envelope | §3.8 | |
| 0x226 | 4 | — | Padding | ModPlug: `MPTX`/`XTPM` here announces an extension (§6.13) | |

### 3.7 Old-format instrument (`IMPI`, `Cmwt < 0x0200`, 554 bytes)

| Offset | Size | Type | Name | Meaning / valid range |
|---|---|---|---|---|
| 0x00 | 4 | char[4] | Signature | `IMPI` |
| 0x04 | 12 | char[12] | DOS filename | |
| 0x10 | 1 | u8 | — | 0 |
| 0x11 | 1 | u8 | Flg | Bit 0 volume envelope on, bit 1 loop on, bit 2 sustain loop on |
| 0x12 | 1 | u8 | VLS | Loop start node |
| 0x13 | 1 | u8 | VLE | Loop end node |
| 0x14 | 1 | u8 | SLS | Sustain loop start node |
| 0x15 | 1 | u8 | SLE | Sustain loop end node |
| 0x16 | 2 | — | — | |
| 0x18 | 2 | u16 | FadeOut | 0–64, against a fade counter of 512 |
| 0x1A | 1 | u8 | NNA | As the new format |
| 0x1B | 1 | u8 | DNC | Duplicate note check: 0 off, 1 on |
| 0x1C | 2 | u16 | TrkVers | Instrument files only |
| 0x1E | 1 | u8 | NoS | Instrument files only |
| 0x1F | 1 | — | — | |
| 0x20 | 26 | char[26] | Name | |
| 0x3A | 6 | — | — | |
| 0x40 | 240 | (u8,u8)[120] | Keyboard | As the new format |
| 0x130 | 200 | u8[200] | Volume curve | Envelope pre-rendered per tick (0–64); redundant with the nodes |
| 0x1F8 | 50 | (u8,u8)[25] | Nodes | (tick, value 0–64); a tick of `0xFF` ends the list |

Old instruments have only a volume envelope. There is no panning or pitch envelope, filter, pan, global volume, PPS/PPC, or random variation. Converting to the new shape:

| Old field | New equivalent |
|---|---|
| FadeOut f (0–64, count 512) | 2f (count 1024) |
| DNC = 1 | DCT = note, DCA = cut |
| — | GbV = 128, DfP = don't use, PPS = 0, filter off |

### 3.8 Envelope (82 bytes, new-format instruments)

| Offset | Size | Type | Name | Meaning |
|---|---|---|---|---|
| 0 | 1 | u8 | Flg | §4.9 |
| 1 | 1 | u8 | Num | Node count, 0–25 |
| 2 | 1 | u8 | LpB | Loop begin node |
| 3 | 1 | u8 | LpE | Loop end node (inclusive) |
| 4 | 1 | u8 | SLB | Sustain loop begin node |
| 5 | 1 | u8 | SLE | Sustain loop end node (inclusive) |
| 6 | 75 | (i8,u16)[25] | Nodes | (value, tick). Ticks 0–9999, non-decreasing |
| 81 | 1 | u8 | — | Reserved |

| Envelope | Value range | Meaning |
|---|---|---|
| Volume | 0–64 | Multiplier /64 |
| Panning | −32…+32 | Pan offset, scaled to the headroom (§5.9) |
| Pitch | −32…+32 | Half-semitones: ±16 semitones |
| Filter (pitch envelope with `Flg` bit 7) | −32…+32 | Cutoff modifier (§5.14) |

### 3.9 Sample header (`IMPS`, 80 bytes)

| Offset | Size | Type | Name | Meaning / valid range | Notes |
|---|---|---|---|---|---|
| 0x00 | 4 | char[4] | Signature | `IMPS` | |
| 0x04 | 12 | char[12] | DOS filename | | |
| 0x10 | 1 | u8 | — | 0 | |
| 0x11 | 1 | u8 | GvL | Sample global volume 0–64 | |
| 0x12 | 1 | u8 | Flg | §4.10 | |
| 0x13 | 1 | u8 | Vol | Default note volume 0–64 | |
| 0x14 | 26 | char[26] | Name | | |
| 0x2E | 1 | u8 | Cvt | Storage conversion, §4.11 | |
| 0x2F | 1 | u8 | DfP | Default pan 0–64; **bit 7 set = use** | |
| 0x30 | 4 | u32 | Length | Length in sample frames (not bytes), per channel | |
| 0x34 | 4 | u32 | LoopBeg | First loop frame | |
| 0x38 | 4 | u32 | LoopEnd | Frame after the last loop frame | Exclusive |
| 0x3C | 4 | u32 | C5Speed | Playback rate in Hz for C-5, 0–9999999 | |
| 0x40 | 4 | u32 | SusLBeg | Sustain loop start | |
| 0x44 | 4 | u32 | SusLEnd | Sustain loop end (exclusive) | |
| 0x48 | 4 | u32 | SmpPoint | Parapointer to the PCM | |
| 0x4C | 1 | u8 | ViS | Auto-vibrato speed 0–64 | Phase step per tick on a 256-step cycle |
| 0x4D | 1 | u8 | ViD | Auto-vibrato depth 0–64 | |
| 0x4E | 1 | u8 | ViR | Auto-vibrato rate 0–64 | Depth ramp ("sweep"), in 1/256 depth units per tick |
| 0x4F | 1 | u8 | ViT | Auto-vibrato waveform, §4.12 | |

### 3.10 Pattern

| Offset | Size | Type | Name | Meaning |
|---|---|---|---|---|
| 0 | 2 | u16 | Length | Packed data length, excluding this 8-byte header |
| 2 | 2 | u16 | Rows | 32–200 in IT. OpenMPT allows 1–1024 |
| 4 | 4 | — | Reserved | |
| 8 | Length | u8[] | Packed data | §5.5 |

IT keeps a pattern plus its header below 64 KiB.

---

## 4. Enumerations and flags

Readers should treat reserved bits as "ignore on read, write 0".

### 4.1 Signatures

`IMPM` (module), `IMPI` (instrument), `IMPS` (sample). OpenMPT block markers: `XTPM`, `STPM`, `MPTX` (§6.13).

### 4.2 `Cwt/v` and `Cmwt`

| `Cwt` range | Writer |
|---|---|
| `0x0000`–`0x0FFF` | Impulse Tracker y.xx as `0x0yxx`, or a program imitating it. `0x0888`, `0x0300` are OpenMPT (see §1.2). `0x0889`–`0x0FFF` with MPTM data is MPTM |
| `0x1000`–`0x1FFF` | Schism Tracker. Up to `0x1050` (v0.50) the low bits are the version; later builds encode a build timestamp here and in the reserved dword (see the OpenMPT wiki for the encoding) |
| `0x4xyy` | pyIT |
| `0x5xyy` | OpenMPT |
| `0x6xyy` | BeRoTracker |
| `0x7xyz` | ITMCK (`0x7FFF` with `Cmwt` `0x0215`: munch.py) |
| `0x8xyy` | Tralala |
| `0xCxyy` | ChickDune ChipTune Tracker |
| `0xDAEB` | spc2it |
| `0xD1CE` | itwriter (JavaScript) |
| `0xEFFF` | rosetracker |

`Cmwt` is the oldest IT version that can load the file. Only two version rules are format-relevant:

1. `Cmwt < 0x0200` selects the old instrument layout (§3.7).
2. The compression variant is chosen per sample by `Cvt` bit 2, never by `Cmwt` (§5.4).

**SwiftIT choice:** SwiftIT also clears the sample stereo flag (`Flg` bit 2) when `Cwt < 0x0214`. Impulse Tracker never played stereo samples ("not supported yet" in ITTECH.TXT), so the bit carries no meaning in files from those versions. See §8.2.

### 4.3 Header `Flags`

| Bit | Mask | Name | Meaning |
|---|---|---|---|
| 0 | 0x0001 | Stereo | Off = mono output |
| 1 | 0x0002 | Vol0MixOptimizations | Skip mixing voices at volume 0 (CPU only; no audible effect intended) |
| 2 | 0x0004 | Instruments | On = instrument mode, off = sample mode |
| 3 | 0x0008 | Linear slides | Off = Amiga (period) slides |
| 4 | 0x0010 | Old Effects | S3M-compatible effect behaviour, §6.9 |
| 5 | 0x0020 | Compatible Gxx | Links G memory with E/F and changes portamento with instruments, §6.10 |
| 6 | 0x0040 | MIDI pitch controller | Use MIDI pitch bend, depth = `PWD` |
| 7 | 0x0080 | Request embedded MIDI configuration | The UI request that makes IT save the macro block; the block's presence is signalled by `Special` bit 3 |
| 8–11 | | Reserved | |
| 12 | 0x1000 | Extended filter range | OpenMPT extension: a wider cutoff curve. Not IT |
| 13–15 | | Reserved | |

### 4.4 Header `Special`

| Bit | Mask | Meaning | Documented in |
|---|---|---|---|
| 0 | 0x0001 | Song message attached | ITTECH.TXT |
| 1 | 0x0002 | Edit history present | OpenMPT wiki (ITTECH.TXT: reserved) |
| 2 | 0x0004 | Row highlight bytes valid | OpenMPT wiki (ITTECH.TXT: reserved) |
| 3 | 0x0008 | MIDI macro configuration embedded | ITTECH.TXT |
| 4–15 | | Reserved | |

### 4.5 Channel pan byte (`ChnlPan`)

| Value | Meaning |
|---|---|
| 0–64 | Pan position (0 left, 32 centre, 64 right) |
| 100 | Surround |
| +128 | Channel disabled: no notes are heard, but effects are still processed |
| 65–99, 101–127 | Undefined. SwiftIT clamps the low 7 bits to 0–64 |

ModPlug writes `0xFF` for unused channels, which reads as disabled.

### 4.6 Order list values

| Value | Meaning |
|---|---|
| 0–199 | Pattern number |
| 200–253 | Undefined. SwiftIT plays an order naming a missing pattern as 64 empty rows |
| 254 (`+++`) | Skip to the next order |
| 255 (`---`) | End of song |

### 4.7 Note values (pattern note byte)

| Value | Meaning |
|---|---|
| 0–119 | C-0 … B-9 |
| 120–253 | Note fade (`~~~`): in IT's player, though not enterable in its editor |
| 254 | Note cut (`^^^`) |
| 255 | Note off (`===`) |

### 4.8 NNA, DCT, DCA

| NNA | Meaning | DCT | Duplicate when … | DCA | Action on the duplicate |
|---|---|---|---|---|---|
| 0 | Cut | 0 | Off | 0 | Cut |
| 1 | Continue | 1 | Same pattern note and instrument | 1 | Note off |
| 2 | Note off | 2 | Same sample and instrument | 2 | Note fade |
| 3 | Note fade | 3 | Same instrument | | |

Values above these ranges are undefined. SwiftIT reads them as 0.

### 4.9 Envelope `Flg`

| Bit | Mask | Meaning |
|---|---|---|
| 0 | 0x01 | Envelope on |
| 1 | 0x02 | Loop on |
| 2 | 0x04 | Sustain loop on |
| 3 | 0x08 | Carry (Schism/OpenMPT extension, undocumented in ITTECH.TXT): a new note continues the previous note's envelope position |
| 4–6 | | Reserved |
| 7 | 0x80 | Pitch envelope only: filter envelope instead of pitch |

### 4.10 Sample `Flg`

| Bit | Mask | Meaning |
|---|---|---|
| 0 | 0x01 | A sample is associated with this header (data present) |
| 1 | 0x02 | 16-bit (off = 8-bit) |
| 2 | 0x04 | Stereo. IT never supported it; OpenMPT and Schism write it |
| 3 | 0x08 | Compressed (IT 2.14/2.15, §5.4) |
| 4 | 0x10 | Loop on |
| 5 | 0x20 | Sustain loop on |
| 6 | 0x40 | Ping-pong loop |
| 7 | 0x80 | Ping-pong sustain loop |

### 4.11 Sample `Cvt`

| Bit | Mask | Meaning |
|---|---|---|
| 0 | 0x01 | Signed PCM (IT 2.02+). Off = unsigned (IT 2.01 and older) |
| 1 | 0x02 | 16-bit samples are big-endian |
| 2 | 0x04 | Delta-encoded PCM. On a compressed sample: the IT 2.15 variant |
| 3 | 0x08 | Byte-delta (16-bit PTM samples) |
| 4 | 0x10 | 12-bit TX-Wave |
| 5 | 0x20 | Left/right/all stereo prompt (editor only) |
| 6–7 | | Reserved |

Whole-byte values with special meaning:

| `Cvt` | Meaning | Writer |
|---|---|---|
| `0xFF` on an 8-bit sample | 4-bit ADPCM (§5.3) | ModPlug |
| `0x80` | External sample: the data is a VarInt length plus a UTF-8 file name | OpenMPT (MPTM/ITI only) |
| `0x40` | OPL instrument | OpenMPT (MPTM only) |

### 4.12 Waveforms (`ViT`, `S3x`, `S4x`, `S5x`)

| Value | Waveform |
|---|---|
| 0 | Sine |
| 1 | Ramp down (sawtooth) |
| 2 | Square |
| 3 | Random. For panbrello the speed is the number of ticks each value is held (RandomWaveform.it) |
| 4–15 | Undefined: `S3x`–`S5x` with these values are ignored; `ViT` reads as sine |

### 4.13 Volume-column byte

| Range | Command | Parameter |
|---|---|---|
| 0–64 | Set volume | v |
| 65–74 | `a` fine volume slide up | v − 65 |
| 75–84 | `b` fine volume slide down | v − 75 |
| 85–94 | `c` volume slide up | v − 85 |
| 95–104 | `d` volume slide down | v − 95 |
| 105–114 | `e` pitch slide down | v − 105 |
| 115–124 | `f` pitch slide up | v − 115 |
| 125–127 | Undefined: ignore | |
| 128–192 | Set pan | v − 128 (0–64) |
| 193–202 | `g` tone portamento | v − 193 |
| 203–212 | `h` vibrato depth | v − 203 |
| 213–255 | Undefined: ignore | |

### 4.14 Effect command numbers

1–26 = `A`–`Z`. 0 = none. Values above 26 are OpenMPT extensions (for example `\xx` smooth MIDI macro) and must be ignored by IT players. In the `S` command the high nibble selects the subcommand (§6.7).

---

## 5. Algorithms

### 5.1 Reading the fixed part

```
require bytes[0..3] == "IMPM" and file length >= 0xC0
ordersAt   = 0xC0
insTable   = ordersAt + OrdNum
smpTable   = insTable + 4*InsNum
patTable   = smpTable + 4*SmpNum
tablesEnd  = patTable + 4*PatNum          // all counts are u16: no overflow in 32 bits
require tablesEnd <= file length
cursor = tablesEnd
if Special & 2: cursor = skipEditHistory(cursor)      // §7 for the validity rule
if Special & 8: midi = read 4896 bytes at cursor
```

### 5.2 Uncompressed PCM

```
frames   = Length                  // per channel
width    = Flg&2 ? 16 : 8
channels = Flg&4 ? 2 : 1           // stereo is split: all left frames, then all right frames
for each channel c (left block first):
    acc = 0
    for i in 0..<frames:
        raw = width == 8 ? u8 : (Cvt&2 ? u16 big-endian : u16 little-endian)
        if Cvt&4:  acc = (acc + raw) mod 2^width; raw = acc       // delta
        sample = Cvt&1 ? signed(raw) : raw XOR 2^(width-1)          // unsigned -> signed
```

**Byte-delta (`Cvt` bit 3, 16-bit only).** The raw *byte* stream is delta-decoded with 8-bit wrap-around across both bytes of each word. The decoded bytes are then paired little-endian into words and the signed/unsigned rule applies.

**12-bit TX-Wave (`Cvt` bit 4).** The layout isn't publicly documented, and modern players decode such samples as plain PCM.

### 5.3 ModPlug 4-bit ADPCM (`Cvt` = `0xFF`, 8-bit)

```
table[0..15] = 16 signed bytes at SmpPoint
data         = ceil(Length / 2) bytes after the table
acc = 0 (i8)
for i in 0..<Length:
    byte   = data[i / 2]
    nibble = (i even) ? byte & 0x0F : byte >> 4        // low nibble first
    acc    = (acc + table[nibble]) wrapping in 8 bits
    output acc
```

### 5.4 IT 2.14 / 2.15 sample compression

Compressed samples (`Flg` bit 3) are stored as a sequence of blocks. The header's `Length` is the uncompressed length, and decoding stops once it is reached.

| Property | 8-bit | 16-bit |
|---|---|---|
| Frames per block (last block: the remainder) | 0x8000 | 0x4000 |
| Initial / maximum width W | 9 | 17 |
| Bits read for a width change at widths 1–6 | 3 | 4 |
| Border constant for widths 7…W−1 | `(0xFF >> (9 − w)) − 4` | `(0xFFFF >> (17 − w)) − 8` |
| Escape range above the border | 1…8 | 1…16 |
| Sample arithmetic | 8-bit wrapping | 16-bit wrapping |

Each block is a `u16` byte count, not counting the `u16` itself, followed by that many bytes. Bits are read **LSB first** within each byte, and bytes in order. A block's bits never continue into the next block. The decoder state is reset at the start of every block: the conversion (delta integration) applies per block, not across the whole sample.

```
decodeChannel(offset, length, is16, it215):
    out = []
    while out.count < length:
        blockBytes = u16 at offset; offset += 2
        block = bytes[offset ..< offset + blockBytes]; offset += blockBytes
        reader = LSB-first bit reader over block
        target = min(is16 ? 0x4000 : 0x8000, length - out.count)
        W = is16 ? 17 : 9;  w = W
        d1 = 0; d2 = 0                       // integrators, wrapping at the sample width
        produced = 0
        while produced < target:
            v = reader.read(w)               // unsigned
            // --- width-change escapes -------------------------------------------
            if w <= 6:                                   // method A
                if v == 1 << (w - 1):
                    n = reader.read(is16 ? 4 : 3) + 1    // 1 … 8 / 1 … 16
                    w = (n < w) ? n : n + 1              // skip the current width
                    continue
            else if w < W:                               // method B
                border = ((is16 ? 0xFFFF : 0xFF) >> (W - w)) - (is16 ? 8 : 4)
                if border < v <= border + (is16 ? 16 : 8):
                    n = v - border
                    w = (n < w) ? n : n + 1
                    continue
            else:                                        // method C, w == W
                if v & (1 << (W - 1)):
                    w = (v + 1) & 0xFF                   // must be 1 … W, else corrupt
                    continue
            // --- a delta ---------------------------------------------------------
            if w < W:  delta = signExtend(v, fromBits: w)
            else:      delta = signExtend(v, fromBits: W - 1)   // the low 8 / 16 bits
            d1 = wrap(d1 + delta)
            d2 = wrap(d2 + d1)
            out.append(it215 ? d2 : d1)
            produced += 1
    return (out, offset)                     // offset = first byte after the last block
```

| Variant | Selected by | Output |
|---|---|---|
| IT 2.14 | `Cvt` bit 2 clear | `d1`: deltas integrated once |
| IT 2.15 | `Cvt` bit 2 set | `d2`: integrated twice |

**Compressed stereo.** Not defined by Impulse Tracker. The convention, which XMPlay introduced and OpenMPT and Schism follow, is two complete compressed streams: left, then right. The right stream starts at the first byte after the left stream's last block.

**Worked example** (also a SwiftIT test vector). An 8-bit, 3-frame block whose successive reads are:

| Width | Value read | Meaning |
|---|---|---|
| 9 | `0x101` | Method C: w ← 2 |
| 2 | `1` | Delta +1 |
| 2 | `3` | Delta −1 (sign-extended from 2 bits) |
| 2 | `2` | Method A escape |
| 3 bits | `3` | n = 4 ≥ 2, so w ← 5 |
| 5 | `0x1E` | Delta −2 |

The output is `1, 0, −2` for IT 2.14 and `1, 1, −1` for IT 2.15. Packed LSB-first, the 23 bits fill three bytes, so the block is `03 00 01 DB 79`.

### 5.5 Pattern unpacking

```
lastMask[64], lastNote[64], lastIns[64], lastVol[64], lastCmd[64], lastParam[64] = 0
row = 0
while row < Rows and bytes remain:
    cv = read u8
    if cv == 0: row += 1; continue                 // end of row
    ch = (cv - 1) & 63
    if cv & 0x80: lastMask[ch] = read u8
    mask = lastMask[ch]
    cell = empty
    if mask & 0x01: lastNote[ch] = read u8;  cell.note = lastNote[ch]
    if mask & 0x02: lastIns[ch]  = read u8;  cell.instrument = lastIns[ch]
    if mask & 0x04: lastVol[ch]  = read u8;  cell.volume = lastVol[ch]
    if mask & 0x08: lastCmd[ch]  = read u8; lastParam[ch] = read u8
                    cell.command = lastCmd[ch]; cell.param = lastParam[ch]
    if mask & 0x10: cell.note = lastNote[ch]
    if mask & 0x20: cell.instrument = lastIns[ch]
    if mask & 0x40: cell.volume = lastVol[ch]
    if mask & 0x80: cell.command = lastCmd[ch]; cell.param = lastParam[ch]
    pattern[row][ch] = cell
```

The "last value" memories belong to the packed stream: they persist across rows within one pattern and reset to 0 at the start of each pattern. They are unrelated to effect memory (§6.8).

### 5.6 Timing

| Quantity | Formula |
|---|---|
| Tick length | `2.5 / tempo` seconds (125 BPM → 20 ms) |
| Frames per tick at output rate R | `R · 2.5 / tempo` (carry the fraction) |
| Ticks per row (one repetition) | `speed + Σ S6x` on the row |
| Total ticks in a row | `(speed + Σ S6x) × (1 + x of the first SEx)` (PatternDelays.it) |

### 5.7 Frequency

**Notes.** For a played note n (after the keyboard transposition in instrument mode) and the sample's `C5Speed`:

```
f = C5Speed × 2^((n − 60) / 12)
```

**Linear slides** (`Flags` bit 3). IT works on actual frequencies (LinearSlides.it): a slide of u units multiplies f by `2^(u / 768)`.

| Command | Units per application | Applied on |
|---|---|---|
| `Exx` / `Fxx` (xx < 0xE0) | −4·xx / +4·xx | Every non-first tick |
| `EFx` / `FFx` | −4·x / +4·x | First tick |
| `EEx` / `FEx` | −x / +x | First tick |
| Volume column `e x` / `f x` | as `E(4x)` / `F(4x)` | Every non-first tick |
| `Gxx` | 4·xx toward the target | Every non-first tick |

**Amiga slides** (`Flags` bit 3 clear). Slides act on a period P inversely proportional to frequency. SwiftIT uses the Scream Tracker ×4 scale, `P = 14317056 / f` (1712 at 8363 Hz). A slide of u units subtracts u from P (up) or adds u (down), then `f = 14317056 / P`. The OpenMPT effect reference instead describes one unit as one period of `3546895 / f`, which is about 1 % slower per unit on the ×4 scale; see §8.3.

**Vibrato, arpeggio, pitch envelope, auto-vibrato** are offsets applied on top of the slid frequency each tick. IT applies sample auto-vibrato as a linear offset even in Amiga mode (ITTECH.TXT).

### 5.8 Volume

ITTECH.TXT's final-volume formula, with every factor at its stored range:

```
sample mode:     FV = Vol · SV · CV · GV / 2^18                         (0 … 128)
instrument mode: FV = Vol · SV · IV · CV · GV · VEV · NFC / 2^41         (0 … 128)

Vol: note volume 0–64 (after volume commands, tremolo, tremor)
SV:  sample GvL 0–64           IV:  instrument GbV 0–128
CV:  channel volume 0–64       GV:  song global volume 0–128
VEV: volume-envelope value 0–64
NFC: fade counter 0–1024 (starts at 1024)
```

Random volume variation (`RV`) scales the note's volume by a random factor in `1 ± RV/100`, chosen when the note starts (swing2.it: the variation multiplies the sample volume). The mix volume `MV` scales the whole software mix.

### 5.9 Panning

```
pan = channel pan (0–64)
if instrument DfP is "use":       pan = instrument DfP          // on a note, not a lone instrument (PanReset.it)
if sample DfP bit 7 is set:       pan = sample DfP & 0x7F
pan += (note − PPC) · PPS / 8                                   // pitch-pan separation
pan += random pan swing (±RP), chosen per note                  // RandomPan.it: survives envelopes
pan += panbrello offset
if panning envelope on: pan += E · (32 − |pan − 32|) / 32       // E = envelope value −32 … 32
pan = 32 + (pan − 32) · Sep / 128                               // stereo separation
```

Surround channels ignore pan swing, panbrello, and the panning envelope (surround-pan.it). A sample or instrument default pan cancels the channel's surround (SmpInsPanSurround.it). With `Flags` bit 0 clear, the output is mono.

### 5.10 Envelope processing (per tick, per voice)

```
evaluate(env, pos):                      // linear interpolation
    if pos <= node[0].tick: return node[0].value
    if pos >= node[last].tick: return node[last].value
    find i with node[i].tick <= pos < node[i+1].tick
    return node[i].value + (node[i+1].value − node[i].value) · (pos − node[i].tick) / (node[i+1].tick − node[i].tick)

each tick, for each enabled envelope:
    value = evaluate(env, pos)
    pos += 1
    if sustain loop on and key is held:
        if pos > node[SLE].tick: pos = node[SLB].tick
    else if loop on:
        if pos > node[LpE].tick: pos = node[LpB].tick
    else if pos > node[last].tick:
        envelope has ended
```

| Rule | Source |
|---|---|
| The end of a non-looping volume envelope starts the fadeout | ITTECH.TXT |
| A volume envelope ending at value 0 ends the voice | Common player behaviour; not tied to a test case |
| `S77`/`S79`/`S7B` pause an envelope and `S78`/`S7A`/`S7C` resume it at the same position | s77.it |
| IT increments the position before evaluating it, so a just-triggered note has no valid position until its first tick | EnvLoops.it |
| If a sustain loop ends on the tick of a note-off, the envelope is released only when the loop end is next reached | EnvOffLength.it |
| A sustain loop lying behind a normal loop, left past the normal loop's end, resumes at `loopStart + (pos − loopStart) mod loopLength` | SusAfterLoop.it |
| **Carry** (`Flg` bit 3): a new note on the same instrument continues from the previous note's position. A cut note can't be carried | cut-carry.it, CarryNNA.it |

### 5.11 Fadeout

Fading starts on any of:

- an NNA or DCA of "note fade";
- a note-off when the volume envelope is off or has a (non-sustain) loop;
- the end of the volume envelope;
- a note-fade note value in instrument mode (NoteFade-InsMode.it).

```
each tick while fading: NFC = max(0, NFC − FadeOut); when NFC == 0 the voice ends
```

Sample mode has no fadeout. A note-fade value there does nothing (NoteFade-SmpMode.it).

### 5.12 Sample auto-vibrato

```
on note start (not tone portamento: Autovibrato-Reset.it): depth256 = 0, phase = 0
each tick (skipped entirely when ViR == 0: VibratoSweep0.it):
    depth256 = min(depth256 + ViR, ViD · 256)
    value    = waveform[ViT][phase]             // 256-step cycle, −64 … +64
    offset   = value · (depth256 / 256) / 64    // in 1/64 semitone (linear units)
    phase    = (phase + ViS) & 255
```

### 5.13 LFO tables (vibrato `H`/`U`, tremolo `R`, panbrello `Y`)

IT's tables have 256 steps, and the `H` speed advances 4·x steps per tick. That is the same as a 64-step table advanced x steps. Values run −64…+64:

| Waveform | Value at step p of 64 |
|---|---|
| Sine | `round(64 · sin(2π p / 64))` |
| Ramp down | `64 − 2p` |
| Square | `+64` for p < 32, `−64` otherwise |
| Random | Uniform −64…+64 per step (panbrello: held for *speed* ticks) |

| Effect | Offset per tick (SwiftIT) |
|---|---|
| `Hxy` | `value · 4y / 64` pitch units (1/64 semitone); Old Effects `−value · 4y / 32` |
| `Uxy` | `value · y / 64`; Old Effects `−value · y / 32` |
| `Rxy` | `value · y / 32` volume units |
| `Yxy` | `value · y / 8` pan units (0–256 scale) |

The vibrato depths follow ITTECH.TXT (depth 4y, ×2 under Old Effects). The tremolo and panbrello scale factors are SwiftIT's approximations to IT's (tremolo.it and the panbrello tests check the exact tables).

### 5.14 Resonant filter

IT's filter is a two-pole low-pass, recomputed whenever cutoff, resonance, or the filter envelope changes. The constants below are the ones OpenMPT uses in IT-compatible mode to reproduce IT:

```
c = cutoff 0–127, r = resonance 0–127
m = filter-envelope modifier: 256 with no filter envelope; (E + 32) · 8 with one
    (E = envelope value −32 … 32, so m runs 0 … 512)

fc   = 110 · 2^(0.25 + c · (m + 256) / (24 · 512))       Hz
damp = 10^(−(24/128) · r / 20)                            (r = 127 → about −23.8 dB)
k    = R / (2π · fc)                                      R = output sample rate
d    = damp · k + damp − 1
e    = k²
a0 = 1 / (1 + d + e);  b1 = (d + 2e) / (1 + d + e);  b2 = −e / (1 + d + e)
y[n] = a0 · x[n] + b1 · y[n−1] + b2 · y[n−2]
```

With no envelope, c = 127 gives about 5.1 kHz and c = 0 about 131 Hz.

**Rules for when the filter runs:**

| Rule | Source |
|---|---|
| The filter is bypassed unless cutoff < 127 or resonance > 0 | filter-7F.it, filter-reset.it |
| A `Z7F` next to a note without portamento disables it | filter-reset.it |
| The maximum filter-envelope value without resonance does not enable filtering, and leaving it doesn't disable it | env-flt-max.it |
| Instrument `IFC`/`IFR` are not applied when a portamento is present | ins-flt-porta-reset.it |
| A cutoff of 0 isn't reset to open when a note triggers with the filter envelope on | FilterEnvReset.it |
| `S7B` before the first tick still filters at the envelope's midpoint value | S7B_StillAppliesFilter.it |

**Stability.** The recursion is stable only while k > 1/2 (fc below R/π). IT's own maximum, about 5 kHz, is far inside that at common rates. A filter envelope can push fc much higher, so players must clamp it. SwiftIT clamps fc to 120 Hz … min(20 kHz, R/4).

Older ModPlug-derived players use a different damping term. Don't mix coefficients from the two families.

### 5.15 Edit timer (reserved dword at 0x3C)

IT 2.07 stores the time spent editing as a DOS-timer count (18.2 Hz). IT 2.08 and later obscure it, as documented on the OpenMPT wiki. To recover the count: XOR with `'ITRK'`, rotate right by 7, negate, rotate left by 4, then XOR with `'JTHL'`. This is informational only; nothing in playback depends on it.

---

## 6. Semantics and de-facto behaviour

### 6.1 Song flow

- Playback starts at the first order that is not 254. A 255, or the end of the list, ends the song; Impulse Tracker itself then restarts from order 0.
- `Bxx` jumps to order xx. `B00` restarts the song. With `Cxx` on the same row, `Cxx` picks the row of the order `Bxx` chose.
- `Cxx` breaks to row xx (hexadecimal, not BCD as in MOD) of the next order. A row past the end of that pattern means row 0.
- **Pattern loops** (`SB0`/`SBx`):
  - Each host channel keeps its own loop start and count.
  - After a loop finishes, the loop start moves to the row after the `SBx`. That is IT's quirk, which `weirdloop.it` turns into an endless loop.
  - The loop state is **not reset** when the pattern changes. A loop start beyond the end of the current pattern sends playback on to the next order (LoopStartAfterPatternEnd.it).
  - A `Cxx` on the row of a looping `SBx` doesn't stop the loop: the loop repeats, then the break happens (LoopBreak.it).
  - A `Bxx` to the right of a looping `SBx` cancels the loop, but one to its left gives the loop priority (LoopBreak.it, sbx-priority.it).
- **Row delays.** `S6x` tick delays on a row add up. Only the first `SEx` on a row counts, even `SE0` (PatternDelays.it). Each `SEx` repetition starts with a new first tick (§6.2).
- **SwiftIT choice (end of song).** By default SwiftIT stops at the end of the order list, or when playback would return to an (order, row) already played other than through `SBx`. A run of more than 65,536 revisited rows inside pattern loops also ends the song. `ITMixer.Options.loopsSong` restores IT's endless playback.

### 6.2 Row processing order

On the first tick of a row, host channels are processed left to right. For each channel:

1. The note and instrument are resolved, unless `SDx` delays them.
2. The volume column runs its first-tick part.
3. The effect column runs its first-tick part.

Zxx macros run after the note and instrument data and before the other effects, except Set Volume (Volume-Macro-Letters.it).

On rows with `SEx`, every repetition (each `speed + Σ S6x` ticks) begins with another first tick (PatternDelaysRetrig.it):

- The effect column runs its first-tick behaviour again. That includes fine slides and `Vxx` (GlobalVolFirstTick.it).
- Notes are not read again, and volume-column fine slides do not repeat (FineVolColSlide.it).
- Notes delayed by `SDx` retrigger on every repetition; undelayed notes don't (PatternDelay-NoteDelay.it).
- `SDx`, `SCx`, and the `Jxx` arpeggio counter count from the start of each repetition (JxxTicks.it).

### 6.3 Notes, instruments, and samples

**Sample mode** (`Flags` bit 2 clear):

- The instrument column is a sample number.
- A new note always cuts the previous one; there is no NNA.
- An invalid sample number cuts the playing sample (InstrumentNumberChange.it).

**Instrument mode:**

- **Keyboard.** The note and instrument pass through the keyboard table first. The table gives the sample and the note actually played. A key mapped to sample 0 is ignored completely, together with the effects in its cell (emptyslot.it, NoMapEffects.it, NoMap.it). Row 3 of NoMapEffects.it is the exception: a note off, cut, or fade still invalidates the previous note.
- **Lone instrument number** (no note):
  - Resets the note volume to the sample's default, and reloads that sample's properties while the playing sample continues (InstrAfterMultisamplePorta.it).
  - Does not reset panning (PanReset.it).
  - May restart a note stopped by `^^^`/`SCx`, with differences between the two (NoteOffInstr.it, scx.it, SCx-Reset.it, PortaResetAfterRetrigger.it).
- **Note memory.** Each channel's initial last-note memory is C-0 (InitialNoteMemory.it, InitialNoteMemoryInstrMode.it).
- **Notes without an instrument number** can switch samples through the keyboard, and the C-5 frequency follows (freqreset-noins.it).
- **Default volume** comes from the sample's `Vol` whenever an instrument number is present.
- **Panning** comes from the instrument/sample defaults (§5.9) on a note.
- **Note values:**

  | Note | Effect |
  |---|---|
  | Note off | Releases the sustain loops (sample and envelopes) and starts the fadeout under the rules in §5.11 |
  | Note cut (`^^^`) | Stops the sample without zeroing its volume (NoteOffInstr.it) |
  | Note fade | Starts the fadeout |

### 6.4 New Note Actions, duplicate checks, virtual channels

When a note starts on a host channel in instrument mode, IT does the following:

1. Runs the **duplicate check** of the new note's instrument over that channel's voices (foreground and background) that play the same instrument:
   - DCT "note" compares raw pattern notes, not mapped notes.
   - DCT "sample" applies only when the old and new instruments match (dct_smp_note_test.it).
   - Each match receives the DCA.
2. Applies the old foreground voice's **NNA**:

   | NNA | The old voice |
   |---|---|
   | Cut | Ends |
   | Continue | Moves to the background unchanged |
   | Note off | Moves to the background and is released |
   | Note fade | Moves to the background and starts fading |

3. Allocates a voice for the new note: the first free voice, else the quietest background voice, else none (the note is dropped). This is ITTECH.TXT's description; IT 2.03+ chooses more selectively. IT has 256 virtual channels.

Further rules:

- A tone portamento never triggers an NNA.
- `S73`–`S76` override the NNA of the current note only. The NNA is reset on note changes but not on instrument changes (s7xinsnum.it), and during an instrument swap with portamento (SwapNNA.it).
- `S70`–`S72` cut, release, or fade this host channel's background voices.
- The duplicate and NNA checks for a note without an instrument number use the sample the keyboard selects (DNA-NoInstr.it).

### 6.5 Effect column

"First" means the first tick of the row or repetition, "other" means the remaining ticks. "Memory" names the slot that a zero parameter recalls (§6.8).

| Cmd | Name | Ticks | Memory | Semantics |
|---|---|---|---|---|
| `Axx` | Set speed | First | — | Ticks per row; `A00` ignored |
| `Bxx` | Position jump | First | — | §6.1 |
| `Cxx` | Pattern break | First | — | §6.1 |
| `Dxy` | Volume slide | First/other | D (shared with K, L) | Tested in order `Dx0`, `D0x`, `DxF`, `DFx`. `Dx0`: up x on other ticks. `D0y`: down y on other ticks. `DxF` (x≠0): fine up x on the first tick. `DFy` (y≠0): fine down. **`DF0` and `D0F` slide by 15 on every tick, the first included** (ITTECH.TXT, OpenMPT effect reference). `DFF` is fine up by 15. Other combinations do nothing. Clamped 0–64 |
| `Exx` | Portamento down | First/other | E/F (and G with Compatible Gxx) | §5.7 units. `EFx` fine, `EEx` extra fine |
| `Fxx` | Portamento up | First/other | as E | |
| `Gxx` | Tone portamento | Other | G (E/F with Compatible Gxx) | Slides toward the note's frequency by 4·xx units per tick and stops there. The note does not retrigger. If no note is playing, the note plays normally. A new non-portamento note fully resets the target (PortaReset.it) |
| `Hxy` | Vibrato | All (Old Effects: other) | H/U speed and depth (nibble-wise) | Speed x, depth 4y (§5.13). The volume column's `h` vibrato is separate and adds to it (VibratoDouble.it) |
| `Ixy` | Tremor | All | I | On for x ticks, off for y ticks; 0 counts as 1. Old Effects: x+1 and y+1 |
| `Jxy` | Arpeggio | All | J | Cycles base, +x, +y semitones by tick count within the repetition (JxxTicks.it) |
| `Kxy` | Vibrato + volume slide | First/other | D | `H00` + `Dxy` |
| `Lxy` | Tone portamento + volume slide | First/other | D | `G00` + `Dxy`. With G memory 0, IT always assumes a downward portamento (LxxWith0Portamento-*.it) |
| `Mxx` | Channel volume | First | — | 0–0x40; larger values ignored |
| `Nxy` | Channel volume slide | First/other | N | As `Dxy` (ITTECH.TXT: same test order) |
| `Oxx` | Sample offset | First, on a note | O | Starts at `xx·256 + SAy·65536` frames (ITTECH.TXT: "xx00h", in frames, so bytes are doubled for 16-bit). Executes even next to a portamento (porta-offset.it). An offset past the end is ignored, or with Old Effects plays from the end. An offset next to a key mapped to an empty sample is ignored entirely in instrument mode (empty_sample_offset.it). A lone instrument number can trigger an offset (OffsetWithInstr.it) |
| `Pxy` | Panning slide | First/other | P | `P0x` right and `Px0` left on other ticks; `PFx` fine right and `PxF` fine left on the first tick |
| `Qxy` | Retrigger | All | Q | Retrigger every y ticks (0 → 1), changing volume by x (table below). The counter persists across rows. IT ignores notes shorter than one tick (retrig-short.it) |
| `Rxy` | Tremolo | All (Old Effects: other) | R (nibble-wise) | Speed x, depth y |
| `Sxy` | Special | | S (`S00` recalls the last `Sxy`) | §6.7 |
| `Txx` | Tempo | First / other | T (slides) | `xx ≥ 0x20`: set tempo. `T0x`: down x per other tick. `T1x`: up x per other tick. Clamped 32–255 |
| `Uxy` | Fine vibrato | All (Old Effects: other) | H | As H, with depth y |
| `Vxx` | Global volume | First | — | 0–0x80. `V81`–`VFF` are ignored (globalvol-invalid.it) |
| `Wxy` | Global volume slide | First/other | W | As `Dxy`, clamped 0–128 |
| `Xxx` | Set pan | First | — | 0x00–0xFF (fine) |
| `Yxy` | Panbrello | All | Y (nibble-wise) | Speed x, depth y. The offset persists after the effect stops until a panning command or a new note (PanbrelloHold.it) |
| `Zxx` | MIDI macro | First | — | `Z00`–`Z7F`: macro `SFx` with z = xx. `Z80`–`ZFF`: fixed macro xx−0x80, where z is still the raw byte (MacroExtendedParam.it) |

Retrigger volume change (the x nibble of `Qxy`):

| x | Change | x | Change |
|---|---|---|---|
| 0 | none | 8 | none |
| 1 | −1 | 9 | +1 |
| 2 | −2 | A | +2 |
| 3 | −4 | B | +4 |
| 4 | −8 | C | +8 |
| 5 | −16 | D | +16 |
| 6 | ×2/3 | E | ×3/2 |
| 7 | ×1/2 | F | ×2 |

### 6.6 LFO retrigger

A new note (not a tone portamento) restarts the vibrato, tremolo, and panbrello waveforms (OpenMPT effect reference). Only waveforms 0–3 exist in IT.

### 6.7 `S` subcommands

| Cmd | Name | Semantics |
|---|---|---|
| `S0x` | Set filter (MOD heritage) | No effect in IT |
| `S1x` | Glissando control | Listed by ITTECH.TXT. Not implemented in SwiftIT; OpenMPT documents its own support as quirky |
| `S2x` | Set finetune | Legacy MOD finetune; no effect on IT samples |
| `S3x` / `S4x` / `S5x` | Vibrato / tremolo / panbrello waveform | §4.12; x > 3 ignored |
| `S6x` | Fine pattern delay | Adds x ticks to each repetition of the row. Multiple `S6x` add up |
| `S70` / `S71` / `S72` | Past note cut / off / fade | This host channel's background voices |
| `S73`–`S76` | NNA override | Cut / continue / off / fade, for the current note |
| `S77` / `S78` | Volume envelope off / on | Pauses or resumes at the same position (s77.it) |
| `S79` / `S7A` | Panning envelope off / on | |
| `S7B` / `S7C` | Pitch (or filter) envelope off / on | |
| `S7D` / `S7E` | Force pitch / filter envelope | OpenMPT, MPTM only |
| `S8x` | Set pan | x·64/15 |
| `S90` / `S91` | Surround off / on | `S91` is the only original IT sound-control command |
| `S98`–`S9F` | Reverb off/on, centre/quad surround, global/local filters, play forward/backward | ModPlug/OpenMPT extensions |
| `SAy` | High offset | Adds y·65536 to subsequent `Oxx` |
| `SB0` / `SBx` | Pattern loop | §6.1 |
| `SCx` | Note cut | After x ticks of the repetition; `SC0` = `SC1`. Cuts like `^^^` (scx.it). Never reached if x ≥ speed + `S6x` |
| `SDx` | Note delay | The note, instrument, and volume column wait x ticks; `SD0` = `SD1`. If x ≥ speed + `S6x`, the cell's note and volume column are dropped (tickdelay.it). Volume-column slides start only after the delay (SlideDelay.it) |
| `SEx` | Pattern delay | Repeat the row x more times; the first `SEx` on the row wins |
| `SFx` | Set active macro | Selects `SFx` for `Z00`–`Z7F` |

### 6.8 Effect memory

| Slot | Written by | Read by |
|---|---|---|
| D | `Dxy`, `Kxy`, `Lxy` | `D00`, `K00`, `L00` |
| E/F | `Exx`, `Fxx`, volume column `e`/`f` (as 4x) | `E00`, `F00`, volume column `e0`/`f0` |
| G | `Gxx`, volume column `g` (table below) | `G00`, `L`, volume column `g0` |
| H | `Hxy` (depth 4y), `Uxy` (depth y), volume column `h` (depth) | `H00`, `U00`, `K`, volume column `h0` |
| Volume column a–d | Volume column `a`, `b`, `c`, `d` (one slot for all four) | The same four |
| One slot each | `I`, `J`, `N`, `O`, `P`, `Q`, `R`, `S`, `T`, `W`, `Y` | The same command with 00 |

Volume-column `g` speeds: `g0` = memory, then `g1`…`g9` = 1, 4, 8, 16, 32, 64, 96, 128, 255.

| Rule | Source |
|---|---|
| The volume column's a–d slot is separate from `Dxy` in both directions | VolColMemory.it, VolColNoSlideMemoryPropagation.it |
| With Compatible Gxx, the G slot and the E/F slot are one slot | ITTECH.TXT |
| Memory initialisation order on one row: effect `Gxx`, volume `g`, volume `e`/`f`, effect `Exx`/`Fxx` | DoubleSlide.it, DoubleSlideCompatGxx.it |

### 6.9 Old Effects (`Flags` bit 4)

| Behaviour | Off (IT) | On (S3M-compatible) |
|---|---|---|
| Vibrato (`H`, `U`, `K`, volume column `h`) | Updated on every tick | Not on the first tick. Double depth, and the waveform is inverted (vibrato-oldfx.it) |
| Tremolo | Every tick | Not on the first tick (SwiftIT, by analogy with vibrato; unverified) |
| `Oxx` past the sample end | Ignored | Plays from the end (silence) |
| Tremor `Ixy` | x on / y off | x+1 on / y+1 off |
| Instrument number resets envelopes | Never (ins-xx.it) | Unless tone portamento is present (ins-ox.it); next to a note-off as well (ResetEnvNoteOffOldFx.it) |

### 6.10 Compatible Gxx (`Flags` bit 5)

- G memory is linked with E/F (§6.8).
- With an instrument number, a `Gxx` retriggers the envelopes (ins-xc.it, ins-oc.it). The note does not resume envelopes from the previous note (CarryCompatGxxPortaWithIns.it).
- When the sample changes on a `Gxx` row, the frequency is rescaled: `f_new = f_old · C5_new / C5_old` (ITTECH.TXT).
  - Without Compatible Gxx, the new sample plays (PortaInsNum.it, PortaSample.it).
  - With it, the old sample keeps playing (PortaInsNumCompat.it, PortaSampleCompat.it).
- The key-off flag is also cleared when portamento continues a note (Off-Porta-CompatGxx.it). Without the flag it is cleared only by new notes (Off-Porta.it).

### 6.11 MIDI macros

A macro is a string that becomes a byte sequence:

- **Hex digits.** `0`–`9` and uppercase `A`–`F` form nibbles, paired into bytes. Whitespace is ignored. SwiftIT also accepts lowercase `d`–`f` as hex.
- **Variables.** Each lowercase letter below inserts a value. Note that lowercase `a`, `b`, and `c` are variables, not hex digits:

  Letters attributed to "IT" come from Impulse Tracker's MIDI configuration screen, not ITTECH.TXT.

  | Letter | Value | Source |
  |---|---|---|
  | `c` | MIDI channel | IT |
  | `n` | Note: the last triggered note, ignoring cuts | macro-lastnote.it |
  | `v` | Velocity | IT |
  | `u` | Computed volume. `u` and `v` emit at least 1 | Volume-Macro-Letters.it |
  | `x` | Pan | IT |
  | `y` | Computed pan | IT |
  | `a` | Bank select MSB | IT; OpenMPT wiki default `Bc 0 a 20 b` |
  | `b` | Bank select LSB | IT; OpenMPT wiki default |
  | `p` | Program | IT |
  | `z` | The `Zxx` parameter byte | IT; MacroExtendedParam.it |
  | `h` | Host channel (0-based) | ZxxSecrets.it |
  | `o` | Last sample offset | ZxxSecrets.it |
  | `m` | Loop direction (0 forward, 1 backward) | ZxxSecrets.it |
  | `s` | SysEx checksum | OpenMPT extension |

- **Several messages.** A macro may hold several MIDI messages, and all of them run (MultiZxx.it: `Z90` sets both cutoff and resonance).
- **Internal messages** (not sent to MIDI out):

  | Bytes | Effect |
  |---|---|
  | `F0 F0 00 xx` | Set the filter cutoff to xx |
  | `F0 F0 01 xx` | Set the resonance to xx |
  | `FA`, `FC`, `FF` | Reset the filter to cutoff 127, resonance 0, without updating the coefficients immediately (ZxxSecrets.it) |

  OpenMPT defines further `F0 F0 nn` messages (filter mode, plugin parameters).
- **Global macros.** IT applies global and channel volume to `u` and `v` macros one row late (GlobalVolume-Macro.it). OpenMPT doesn't run the global macros at all.

### 6.12 Filter

Each host channel holds a current cutoff and resonance:

- `IFC`/`IFR` set them when a note triggers, except next to a portamento.
- `Zxx` sets them.
- The filter envelope modulates the cutoff.
- IT's filter state is per channel, and carries over to later notes ("global filters", `S9C` in OpenMPT terms) until reset.

### 6.13 OpenMPT and ModPlug extensions

These are documented so readers can skip them safely. None are Impulse Tracker features.

| Extension | Location / marker | Contents |
|---|---|---|
| ModPlug song chunks | After the MIDI block (or the edit history). Each is a FOURCC plus a `u32` size | `PNAM` pattern names (32 bytes each), `CNAM` channel names (20 bytes each), `CHFX` per-channel plugin (`u32`), `FX00`–`FX99` and `F100`–`F255` plugin slots |
| ModPlug instrument extension | `MPTX` or `XTPM` in the 4 padding bytes at instrument offset 0x226 | 120 bytes follow: the high byte of each keyboard entry's sample number (for more than 255 samples) |
| OpenMPT instrument extensions | Block beginning `XTPM`, after the sample data | Repeated FOURCC + `u16` per-instrument size, then size × InsNum bytes. Fields include fade-out (`u32`), panning 0–256, MIDI bank/program/channel, plugin, ramping, resampling, cutoff/resonance swing, filter mode, release nodes, pitch-wheel depth, pitch/tempo lock |
| OpenMPT song extensions | Block beginning `STPM`, after the instrument extensions | FOURCC + `u16` size fields: default tempo above 255, rows per beat/measure (`u32`), channel count (`u16`, for more than 64 channels), settings for channels 65+, tempo mode, mix-level mode, created-with/last-saved-with version, pre-amps, restart position, compatibility flags, artist (UTF-8), MIDI mapping, channel colours |
| Extended filter range | `Flags` bit 12 | §4.3 |
| Stereo samples | `Flg` bit 2 | §5.2 and §5.4 |
| `S9x` sound control, `S7D`/`S7E`, `\xx` smooth macro | Effect column | §6.7. Plain IT players ignore them |
| MPTM-only commands (`:xy`, `#xx`, `+xx`, `*xx`, volume `o0x` cue) | MPTM files | Out of scope |

Placing the `XTPM` block "after the sample data" is ambiguous when there are no samples or the last sample is compressed, so readers should search for the marker conservatively, never before the end of the last known structure.

### 6.14 Known Impulse Tracker mixer details

- IT's software mixer shortens ping-pong loops by one sample compared with its GUS driver (Bidi-Loops.it).
- Envelope carry differs between IT's output drivers (CarryNNA.it, flt-env-carry.it).
- Players reproduce IT's WAV writer.

---

## 7. Robustness guidance for readers

Every field is untrusted. Here is what can go wrong, field by field.

| Field / structure | Hazard | Guidance (what SwiftIT does) |
|---|---|---|
| Signature | Wrong file type | Reject unless `IMPM`. Require 192 header bytes |
| `OrdNum`, `InsNum`, `SmpNum`, `PatNum` | Tables past end of file | Compute `tablesEnd` with 32-bit or wider math. Reject if it exceeds the file length |
| Parapointers | Past EOF, overlapping, shared | Bounds-check `pointer + structure size`. Decode shared pointers once (cache by offset) so duplicates can't multiply work. Treat 0 as empty |
| `Special` bit 1 | Set without a history, or without even a count | If `tablesEnd + 2 + 8·Count` would run past the smallest parapointer at or after `tablesEnd` (or past EOF), treat the history as absent and leave the cursor at `tablesEnd`. Then read the MIDI block from there |
| MIDI block | Truncated; non-ASCII | Ignore if it doesn't fit. Map bytes ≥ 0x80 to `?` |
| Message | Length past EOF, missing NUL, LF or CR LF | Clamp to the file. Stop at NUL. Treat CR, LF, and CR LF as one line break |
| `GV`, `MV`, `Sep`, `ChnlVol`, volumes | Out of range | Clamp to their documented ranges |
| `IS` = 0, `IT` < 31 | Division by zero, stalls | Use 6 and 125 |
| Instrument signature | Not `IMPI` | Throw |
| Instrument enums (NNA, DCT, DCA) | Out of range | Map to 0 |
| Keyboard | Note > 119; sample > count | Replace the note with the key. Treat a missing sample as "no sample" |
| Envelope `Num` | > 25 | Clamp to 25 |
| Envelope ticks | Decreasing | Make them non-decreasing |
| Envelope loop indices | Out of range, start > end | Clamp into the node range with start ≤ end |
| Envelope values | Out of range | Clamp |
| Envelope state | Enabled with no nodes | Disable |
| Sample signature | Not `IMPS` | Throw |
| `Length` | Up to 2^32 − 1 frames | Never allocate from it. Cap total decoded frames relative to the file size (SwiftIT: `8 × file size + 1 Mi`). Decode what is present and flag truncation |
| Loops | `end > Length`, `start ≥ end` | Clamp end to the decoded length. Drop a degenerate loop |
| `C5Speed` | 0, or huge | 0 → 8363. Cap at 9,999,999 |
| Compressed blocks | Truncated block, header past EOF, illegal width | Stop decoding, keep what was produced, flag truncation. Output grows only as bits are consumed (≥ 1 bit per frame), so allocation is bounded by the input |
| Compressed stereo | Left stream shorter than declared | Start the right stream after the left's last whole block. Trim both to the shorter |
| Pattern `Rows` | 0 or more than 1024 | Reject |
| Pattern `Length` | Past EOF | Reject |
| Pattern data | Stream ends inside an entry | Reject |
| Pattern data | Stream ends early | Leave the remaining rows empty |
| Pattern channel byte | Channel > 64 | `& 63` |
| Pattern memory | Rows × channels across many patterns | Store only up to the highest used channel. Cap total cells (SwiftIT: 8 Mi) |
| Order list | Values naming missing patterns | Play 64 empty rows |
| Playback | `Bxx`/`SBx` loops | Bound endless playback (see §6.1). Bound nested pattern-loop revisits |
| Filter | Instability near Nyquist, huge envelope modifiers | Clamp fc. Reset non-finite filter state |
| Arithmetic | Overflow on file-supplied values | Use checked or wrapping arithmetic where the format wraps (delta coding, compression integrators) |

---

## 8. Errata

### 8.1 ITTECH.TXT (IT 2.14 patch 5)

| # | ITTECH.TXT says / omits | Correction | Evidence |
|---|---|---|---|
| 1 | `Special` bits 1–2 "reserved" | Bit 1 = edit history (written by IT 2.08+), bit 2 = row highlights valid | OpenMPT wiki |
| 2 | The edit history is not described | `u16` count + 8-byte entries (FAT date, FAT time, DOS-timer run time); §3.3 | OpenMPT wiki |
| 3 | The reserved dword at 0x3C is not described | Edit timer: plain in IT 2.07, obscured from 2.08 (§5.15). Other trackers store IDs there | OpenMPT wiki |
| 4 | Envelope flag bit 3 not described | Envelope carry | OpenMPT wiki; cut-carry.it |
| 5 | Compressed-sample format not described | §5.4. `Cvt` bit 2 selects the IT 2.15 variant | OpenMPT wiki; IT 2.15 behaviour |
| 6 | Stereo samples "not supported yet" | Others write them: split L/R blocks uncompressed, two streams compressed | OpenMPT wiki (XMPlay convention) |
| 7 | The volume-column note says a–d don't share memory with `Dxx`, but not that `Dxx` doesn't write the a–d slot | Separate in both directions | VolColNoSlideMemoryPropagation.it |
| 8 | Its effect notes label `Axx` "Set Tempo" | `Axx` sets speed (ticks per row); `Txx` sets tempo (BPM) | IT behaviour; ITTECH.TXT's own header field names (IS/IT) |
| 9 | Effect section "incomplete": no `S` subcommands | §6.7 | OpenMPT effect reference, test cases |
| 10 | `RP` (random pan) "not implemented yet" | Implemented in later IT 2.x | RandomPan.it |
| 11 | MIDI macro block size, field order, default macros, and macro letters not given | §3.4 and §6.11 | OpenMPT wiki, ZxxSecrets.it |
| 12 | `IFC`/`IFR`/`MIDIBnk` named only | Bit 7 = apply; 0–127; filter formula in §5.14 | OpenMPT IT-compatible filter |
| 13 | Old Effects described as doubled vibrato depth, non-first-tick vibrato, and the `Oxx` rule only | Also inverted vibrato, tremolo timing, tremor +1, and envelope reset by instrument numbers | vibrato-oldfx.it, ins-ox.it, ITTECH.TXT `Ixy` |
| 14 | Pattern rows 32–200 | Other writers produce 1–1024; readers should accept them | OpenMPT |
| 15 | Order values 200–253 not described | Undefined. Play as empty or skip; never index past the pattern table | — |
| 16 | `FadeOut` 0–128 | Files carry larger values; clamp, don't reject | Observed files |
| 17 | Row length with `S6x` and `SEx` not stated | `(speed + ΣS6x) × (1 + SEx)`, each repetition with its own first tick | PatternDelays.it, PatternDelaysRetrig.it |

### 8.2 Previous edition of this document (SwiftIT audit, 2026)

| # | Previous text | Correction |
|---|---|---|
| 1 | "A row lasts speed × (1 + pattern delay) + fine delay ticks" | `(speed + fine delay) × (1 + pattern delay)` |
| 2 | "SEx repetitions are treated as ordinary non-first ticks" | Each repetition starts with a first tick (§6.2) |
| 3 | `DF0`/`D0F` "are regular slides" (non-first ticks only) | They slide on every tick including the first |
| 4 | In sample mode "note fade cuts the note" | It does nothing |
| 5 | `Z80`–`ZFF` run the fixed macro with no parameter, and only the first filter message is read | `z` is the raw command byte. All messages run. `FA`/`FC`/`FF` reset the filter |
| 6 | Default MIDI configuration listed without bank select | Bank select is `Bc 0 a 20 b` |
| 7 | Edit history: "many writers set the bit and store a count of 0" | Some don't even write the count. Validate against the first parapointer (§7) |
| 8 | Pattern-loop state not described across patterns | The state survives pattern changes. `Bxx`/`SBx` ordering rules (§6.1) |
| 9 | Old Effects: "vibrato is twice as deep and skips the first tick" | Also inverted |
| 10 | Panbrello offset implicitly reset every row | Held until a panning command or new note |
| 11 | `S3x`–`S5x` waveform masked to 2 bits | Values above 3 are ignored |
| 12 | `S1x` glissando "ignored (as in IT)" | ITTECH.TXT lists it. Whether IT 2.14 acts on it is unverified; SwiftIT ignores it |
| 13 | Song message: "lines end with CR" | Also LF (ChibiTracker) and CR LF |
| 14 | "`Cwt < 0x0214`: very old IT versions didn't clear the sample stereo flag" | Unsourced. Kept only as a SwiftIT heuristic (§4.2) |

### 8.3 Open questions (unverified, recorded so they aren't mistaken for fact)

- **Amiga-slide period constant.** SwiftIT uses the ST3 ×4 scale (14317056/f). The OpenMPT effect reference describes `3546895/f` periods.
- **Retrigger memory.** SwiftIT updates the `Qxy` x and y nibbles independently.
- **Tremolo and panbrello depth tables.** SwiftIT's scale factors are approximations.

---

## 9. Implementation status

SwiftIT 0.1.0. "Partial" entries name what is missing.

| Section | Feature | Status |
|---|---|---|
| 3.2 | `IMPM` header, `Flags`, `Special`, row highlights | Supported |
| 3.2 | Reserved dword / edit timer (5.15) | Not decoded (not needed for playback) |
| 3.3 | Edit history | Located and skipped (validated against parapointers); not surfaced |
| 3.4 | Embedded MIDI macro configuration | Parsed. Only the internal filter messages run (6.11) |
| 3.5 | Song message (CP437; CR, LF, CR LF) | Supported |
| 3.6 | New-format instruments | Supported |
| 3.7 | Old-format IT 1.x instruments | Supported (converted to the new shape) |
| 3.8, 5.10 | Volume / panning / pitch envelopes, loop, sustain loop, carry | Supported. Not modelled: the EnvOffLength.it and CarryNNA.it driver quirks, and the first-tick position rule of EnvLoops.it |
| 3.8, 5.14 | Filter envelope | Supported |
| 3.9 | Sample headers, loops, sustain loops, ping-pong | Supported. The Bidi-Loops.it one-sample shortening is not modelled |
| 5.2 | 8/16-bit, signed/unsigned, big-endian, delta, byte-delta PCM | Supported |
| 5.2 | Stereo samples | Supported (played in stereo) |
| 5.2 | 12-bit TX-Wave | Unsupported (decoded as plain PCM) |
| 5.3 | ModPlug ADPCM | Supported |
| 5.4 | IT 2.14 / 2.15 compression, 8/16-bit, mono/stereo | Supported |
| 5.5 | Pattern packing with mask/value memory | Supported |
| 5.6 | Timing; `S6x`/`SEx` row structure and repeated first ticks | Supported |
| 5.7 | Linear slides | Supported |
| 5.7 | Amiga slides | Supported (ST3 ×4 period scale; vibrato applied linearly) |
| 5.8, 5.9 | Volume and pan formulas, separation, surround, mono | Supported (surround as an inverted right channel) |
| 5.11 | Fadeout | Supported |
| 5.12 | Auto-vibrato | Supported (ViR = 0 yields no vibrato) |
| 5.13 | LFO waveforms | Supported. Approximate tremolo/panbrello depth; random panbrello isn't held for *speed* ticks |
| 5.14 | Resonant filter | Supported. Implemented: IT formula, the bypass rule, IFC/IFR, Zxx. Not modelled: env-flt-max.it, FilterEnvReset.it, ins-flt-porta-reset.it |
| 6.1 | Song flow, `Bxx`/`Cxx`, pattern loops incl. cross-pattern state and `Bxx`/`SBx` ordering | Supported |
| 6.3 | Instrument and sample mode, keyboard, default volume/pan | Supported. Not modelled: lone-instrument-number retrigger/reset quirks (NoteOffInstr.it, scx.it, PortaResetAfterRetrigger.it, InstrAfterMultisamplePorta.it), NoMapEffects.it effect suppression, InitialNoteMemory.it |
| 6.4 | NNA, DCT/DCA, `S70`–`S76`, 256 voices | Supported |
| 6.5 | Effects `A`–`Z` | Supported. Not modelled: `Oxx` next to a tone portamento (porta-offset.it), OffsetWithInstr.it, the LxxWith0Portamento.it quirk, retrig-short.it, VibratoDouble.it (volume-column and effect vibrato replace instead of adding) |
| 6.6 | LFO retrigger on new notes | Supported |
| 6.7 | `S` subcommands | Supported. `S0x`/`S1x`/`S2x` ignored; ModPlug `S9x` extensions other than `S90`/`S91` ignored |
| 6.8 | Effect memory, including the separate volume-column a–d slot | Supported. The DoubleSlide.it initialisation order is not verified |
| 6.9 | Old Effects | Supported. Not modelled: envelope reset by instrument numbers (ins-ox.it, ResetEnvNoteOffOldFx.it) |
| 6.10 | Compatible Gxx | Partial. Implemented: memory link, envelope retrigger with an instrument. Missing: the sample-change frequency rescale and old-sample retention (PortaInsNumCompat.it), and the key-off clearing rule |
| 6.11 | Zxx / SFx macros | Partial. Implemented: internal filter messages (several per macro, raw `z`, `FA`/`FC`/`FF` reset). Missing: MIDI output, the other macro letters, global macros |
| 6.12 | Filter state per channel | Supported |
| 6.13 | OpenMPT/ModPlug extensions (chunks, `XTPM`/`STPM`, plugins, extended filter range, `\xx`, MPTM) | Unsupported (safely ignored) |
| 4.3 | MIDI pitch controller (`Flags` bit 6), MIDI output | Unsupported |
| 4.3 | Vol0MixOptimizations | Ignored (CPU only) |

---

## 10. References and provenance

### Sources

- **Jeffrey Lim**, *ITTECH.TXT*, the technical documentation shipped with Impulse Tracker 2.14 (patch 5 is the final revision). The format's canonical document. A wiki copy edited by **Brandon Mulcahy** is in the Schism Tracker wiki.
- **OpenMPT wiki** (maintained by the OpenMPT developers, principally **Johannes Schultz**):
  - "Development: Formats/IT": tracker IDs, edit history, edit timer, compression notes, the stereo convention.
  - "Development: OpenMPT Format Extensions": `XTPM`/`STPM`, ModPlug chunks.
  - "Manual: Effect Reference": effect semantics and memory.
  - "Development: Test Cases/IT": the named test cases cited throughout. Each one is a small module whose description states the IT 2.14/2.15 behaviour it captures.
- **Schism Tracker** (originally by **Storlek** and **Mrs. Brisby**, with contributors): its documentation and the ITTECH.TXT wiki copy.
- **ModPlug Tracker** (**Olivier Lapicque**): the ADPCM sample format and the original song/instrument extension chunks.
- **XMPlay** (**Ian Luck**): the two-stream compressed-stereo convention.
- **SAUCE 00.5** (org specs repository, `metadata/sauce-00.5.md`): the Audio/IT file-type code.

### Provenance

This document was written in its author's own words from the public documents listed above and from black-box observation of how modules play (the OpenMPT test-case descriptions). No third-party source code was consulted for it or copied into SwiftIT. Field layouts, numeric tables, and formulas are facts reproduced for interoperability. Test-case and command names are cited for attribution.
