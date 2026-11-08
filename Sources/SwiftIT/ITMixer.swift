/// ITMixer.swift
///
/// Software mixer for ``ITFile``: a tick-accurate Impulse Tracker
/// playback engine that renders interleaved stereo Float32.

import Foundation

/// Renders an ``ITFile`` to interleaved stereo `Float` PCM.
///
/// The engine follows Impulse Tracker's model: 64 host channels carry
/// effect state and own one foreground voice each; New Note Actions move
/// old voices into a pool of up to 256 background voices. Rows are
/// processed tick by tick (`2.5 / tempo` seconds per tick) and every
/// voice's volume, panning, pitch, and filter are recomputed once per
/// tick.
///
/// ```swift
/// let mixer = ITMixer(file: module, sampleRate: 48_000)
/// var buffer = [Float](repeating: 0, count: 2 * 1024)
/// while !mixer.isFinished {
///     let frames = buffer.withUnsafeMutableBufferPointer { mixer.render(into: $0) }
///     consume(buffer, frames)
/// }
/// ```
///
/// ## End of song
///
/// By default playback stops (``isFinished`` becomes `true`) when the
/// order list ends (`255` or the last entry) or when the song would
/// revisit a row it has already played other than through a pattern
/// loop (`SBx`); this catches the usual `Bxx` loop-back idiom. Set
/// ``Options/loopsSong`` to keep playing instead. Pathological pattern
/// loops are bounded too: 65,536 consecutive revisited rows end the song.
///
/// ## Threading
///
/// `ITMixer` is a reference type with mutable playback state. It is
/// marked `@unchecked Sendable` so it can be handed to an audio render
/// thread, under one rule: after handing it over, only that thread may
/// call into it. It performs no locking and does not allocate inside
/// ``render(into:)``.
public final class ITMixer: @unchecked Sendable {

    /// Playback options.
    public struct Options: Sendable, Hashable {
        /// When `true`, the song restarts instead of finishing, so
        /// rendering never ends. Default `false`.
        public var loopsSong: Bool

        /// Creates playback options.
        /// - Parameter loopsSong: Restart at the end instead of finishing.
        public init(loopsSong: Bool = false) {
            self.loopsSong = loopsSong
        }
    }

    // MARK: Public state

    /// Output sample rate in Hz (clamped to 1,000...1,536,000; a
    /// non-finite value is replaced with 44,100).
    public let sampleRate: Double
    /// Options the mixer was created with.
    public let options: Options
    /// `true` once the song has ended (never, with ``Options/loopsSong``).
    public private(set) var isFinished = false
    /// Index into ``ITFile/orders`` of the row being played.
    public var currentOrder: Int { order }
    /// Row being played within the current pattern.
    public var currentRow: Int { row }
    /// Current speed (ticks per row).
    public var currentSpeed: Int { speed }
    /// Current tempo (BPM).
    public var currentTempo: Int { tempo }
    /// Current global volume (0...128).
    public var currentGlobalVolume: Int { globalVolume }

    // MARK: Internal state

    let file: ITFile
    let instrumentMode: Bool
    let linearSlides: Bool
    let oldEffects: Bool
    let linkedPortamento: Bool
    let midi: ITMIDIConfiguration
    let separation: Int
    let stereoOutput: Bool
    let mixGain: Float

    var channels: [HostChannel]
    var voices: [Voice]

    var order = 0
    var row = 0
    var tick = 0
    var rowTicks = 6
    /// Ticks in one repetition of the row: speed plus `S6x` tick delay.
    /// `SEx` repeats the row; every repetition starts with a first tick.
    var repeatTicks = 6
    var speed = 6
    var tempo = 125
    var globalVolume = 128
    var pattern: ITPattern = .empty(rows: 64)

    var patternDelay = 0
    var patternDelaySet = false
    var fineDelay = 0
    var jumpOrder: Int? = nil
    var breakRow: Int? = nil
    var loopRow: Int? = nil

    /// Set when the song ends during a tick; the tick's audio still
    /// plays and ``isFinished`` flips at the next tick boundary.
    var endReached = false
    var visited: Set<Int> = []
    var inPatternLoop = false
    var revisitRun = 0
    var maximumRevisitRun = 65_536

    var framesLeftInTick = 0
    var tickRemainder = 0.0
    var random: UInt32 = 0x2545_F491

    /// Scratch mix buffers, allocated once.
    var mixLeft: [Float]
    var mixRight: [Float]
    static let chunkFrames = 1024

    /// Number of voices (foreground + background), as in Impulse Tracker.
    static let voiceCount = 256

    /// Amiga period constant: `period = amigaClock / frequency`
    /// (1712 at 8363 Hz, the ST3/IT x4 period scale).
    static let amigaClock = 14_317_056.0

    // MARK: Init

    /// Creates a mixer positioned at the first playable order.
    ///
    /// - Parameters:
    ///   - file: The module to play.
    ///   - sampleRate: Output rate in Hz (clamped to 1,000...1,536,000).
    ///   - options: Playback options.
    public init(file: ITFile, sampleRate: Double, options: Options = Options()) {
        self.file = file
        self.sampleRate = sampleRate.isFinite ? min(max(sampleRate, 1_000), 1_536_000) : 44_100
        self.options = options
        self.instrumentMode = file.usesInstruments
        self.linearSlides = file.usesLinearSlides
        self.oldEffects = file.usesOldEffects
        self.linkedPortamento = file.linksPortamentoMemory
        self.midi = file.midiConfiguration ?? .impulseTrackerDefault
        self.separation = Int(file.panningSeparation)
        self.stereoOutput = file.isStereo
        self.mixGain = Float(file.mixVolume) / 128
        self.channels = Array(repeating: HostChannel(), count: 64)
        self.voices = Array(repeating: Voice(), count: Self.voiceCount)
        self.mixLeft = Array(repeating: 0, count: Self.chunkFrames)
        self.mixRight = Array(repeating: 0, count: Self.chunkFrames)
        reset()
    }

    /// Rewind to the start of the song and clear all voices and effect
    /// memory.
    public func reset() {
        speed = Int(file.initialSpeed)
        tempo = Int(file.initialTempo)
        globalVolume = Int(file.globalVolume)
        random = 0x2545_F491
        for i in 0..<64 {
            var c = HostChannel()
            let raw = file.channelPan[i]
            c.muted = raw & 0x80 != 0
            let p = Int(raw & 0x7F)
            if p == 100 {
                c.surround = true
                c.pan = 128
            } else {
                c.pan = min(p, 64) * 4
            }
            c.channelVolume = Int(file.channelVolume[i])
            channels[i] = c
        }
        for i in voices.indices { voices[i] = Voice() }
        visited.removeAll(keepingCapacity: true)
        inPatternLoop = false
        revisitRun = 0
        jumpOrder = nil
        breakRow = nil
        loopRow = nil
        tick = 0
        row = 0
        framesLeftInTick = 0
        tickRemainder = 0
        isFinished = false
        endReached = false
        if let first = nextPlayableOrder(from: 0) {
            order = first
            pattern = patternFor(order: first)
            visited.insert(positionKey(order, 0))
        } else {
            order = 0
            isFinished = true
        }
    }

    // MARK: Render

    /// Render interleaved stereo frames into `buffer`
    /// (`buffer.count / 2` frames, L R L R ...).
    ///
    /// - Returns: The number of frames of song audio written. When the
    ///   song ends inside the buffer the remaining frames are zeroed and
    ///   the return value is smaller than the frame count.
    @discardableResult
    public func render(into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        guard let base = buffer.baseAddress else { return 0 }
        return render(into: base, frames: buffer.count / 2)
    }

    /// Render `frames` interleaved stereo frames (`2 * frames` floats)
    /// starting at `buffer`.
    ///
    /// - Parameters:
    ///   - buffer: Destination with room for `2 * frames` floats.
    ///   - frames: Number of frames to render; values <= 0 render nothing.
    /// - Returns: The number of frames of song audio written; any frames
    ///   after the end of the song are zeroed.
    @discardableResult
    public func render(into buffer: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        var produced = 0
        while produced < frames {
            if isFinished { break }
            if framesLeftInTick <= 0 {
                processTick()
                if isFinished { break }
                let exact = sampleRate * 2.5 / Double(tempo) + tickRemainder
                let whole = max(1, Int(exact))
                tickRemainder = exact - Double(whole)
                framesLeftInTick = whole
            }
            let chunk = min(framesLeftInTick, frames - produced, Self.chunkFrames)
            mix(into: buffer + produced * 2, frames: chunk)
            produced += chunk
            framesLeftInTick -= chunk
        }
        if produced < frames {
            (buffer + produced * 2).update(repeating: 0, count: (frames - produced) * 2)
        }
        return produced
    }

    // MARK: Song position

    func positionKey(_ order: Int, _ row: Int) -> Int { order * 2048 + row }

    /// The first order at or after `start` that names a pattern,
    /// skipping `254`; `nil` at `255` or the end of the list.
    func nextPlayableOrder(from start: Int) -> Int? {
        var o = max(start, 0)
        while o < file.orders.count {
            let value = file.orders[o]
            if value == 255 { return nil }
            if value != 254 { return o }
            o += 1
        }
        return nil
    }

    /// Pattern for an order entry; missing patterns play as 64 empty rows.
    func patternFor(order: Int) -> ITPattern {
        guard order >= 0, order < file.orders.count else { return .empty(rows: 64) }
        let index = Int(file.orders[order])
        guard index < file.patterns.count else { return .empty(rows: 64) }
        return file.patterns[index]
    }

    // MARK: Tick sequencing

    func processTick() {
        guard !endReached else {
            isFinished = true
            return
        }
        if tick == 0 {
            startRow()
        } else if tick % repeatTicks == 0 {
            // A pattern-delay repetition: effects run as on a first tick,
            // but notes are not read again (OpenMPT test case
            // PatternDelaysRetrig.it).
            for ch in 0..<64 { repeatRow(channel: ch) }
        } else {
            for ch in 0..<64 { runTick(channel: ch) }
        }
        updateVoices()
        tick += 1
        if tick >= rowTicks {
            advanceRow()
        }
    }

    func startRow() {
        patternDelay = 0
        patternDelaySet = false
        fineDelay = 0
        for ch in 0..<64 {
            processRow(channel: ch, cell: pattern[row: row, channel: ch])
        }
        // Tick delays accumulate and are part of each repetition; only the
        // first SEx counts (OpenMPT test case PatternDelays.it).
        repeatTicks = max(1, speed + fineDelay)
        rowTicks = repeatTicks * (1 + patternDelay)
    }

    func advanceRow() {
        tick = 0
        var targetOrder = order
        var targetRow = row + 1
        var isLoopJump = false
        var orderChanged = false

        if let lr = loopRow {
            targetRow = lr
            isLoopJump = true
        } else if jumpOrder != nil || breakRow != nil {
            let start = jumpOrder ?? order + 1
            targetRow = breakRow ?? 0
            guard let next = nextPlayableOrder(from: start) else {
                clearJumps()
                songEnded()
                return
            }
            targetOrder = next
            orderChanged = true
        } else if targetRow >= pattern.rowCount {
            guard let next = nextPlayableOrder(from: order + 1) else {
                songEnded()
                return
            }
            targetOrder = next
            targetRow = 0
            orderChanged = true
        }
        clearJumps()

        let nextPattern = orderChanged ? patternFor(order: targetOrder) : pattern
        if targetRow >= nextPattern.rowCount { targetRow = 0 }

        let key = positionKey(targetOrder, targetRow)
        if visited.contains(key) {
            if isLoopJump || inPatternLoop {
                revisitRun += 1
                if revisitRun > maximumRevisitRun {
                    songEnded(restartAt: (targetOrder, targetRow))
                    return
                }
            } else {
                songEnded(restartAt: (targetOrder, targetRow))
                return
            }
        } else {
            visited.insert(key)
            revisitRun = 0
            if !isLoopJump { inPatternLoop = false }
        }
        if isLoopJump { inPatternLoop = true }
        moveTo(order: targetOrder, row: targetRow, pattern: nextPattern, orderChanged: orderChanged)
    }

    func clearJumps() {
        jumpOrder = nil
        breakRow = nil
        loopRow = nil
    }

    func moveTo(order newOrder: Int, row newRow: Int, pattern newPattern: ITPattern, orderChanged: Bool) {
        if orderChanged {
            for ch in 0..<64 {
                channels[ch].patternLoopStart = 0
                channels[ch].patternLoopCount = 0
            }
        }
        order = newOrder
        row = newRow
        pattern = newPattern
    }

    /// The song has ended: either finish, or (looping) continue at
    /// `restartAt` (or the first playable order when the list ran out).
    func songEnded(restartAt: (Int, Int)? = nil) {
        guard options.loopsSong else {
            endReached = true
            return
        }
        visited.removeAll(keepingCapacity: true)
        inPatternLoop = false
        revisitRun = 0
        let target: (Int, Int)
        if let r = restartAt {
            target = r
        } else if let first = nextPlayableOrder(from: 0) {
            target = (first, 0)
        } else {
            endReached = true
            return
        }
        let p = patternFor(order: target.0)
        let r = target.1 < p.rowCount ? target.1 : 0
        visited.insert(positionKey(target.0, r))
        moveTo(order: target.0, row: r, pattern: p, orderChanged: true)
    }

    // MARK: Random

    /// Deterministic xorshift32 in -1...1.
    func nextRandom() -> Double {
        random ^= random << 13
        random ^= random >> 17
        random ^= random << 5
        return Double(random) / Double(UInt32.max) * 2 - 1
    }
}
