import CoreGraphics
import Darwin
import Foundation
import Synchronization

public struct PlaybackOptions: Sendable {
    public var speed: Double
    /// A nil count repeats until cancelled, without retaining per-event timing samples.
    public var loops: Int?
    public var tagBase: Int64?
    public init(speed: Double = 1, loops: Int? = 1, tagBase: Int64? = nil) {
        self.speed = speed
        self.loops = loops
        self.tagBase = tagBase
    }
}

public struct PostSample: Sendable {
    public var index: Int
    public var targetNS: UInt64
    public var postedNS: UInt64
    public var returnedNS: UInt64? = nil
}

public struct PlaybackReport: Sendable {
    public var postedEvents = 0
    public var completedLoops = 0
    public var cleanupEvents = 0
    public var samples: [PostSample] = []
    public var stopReason: String?
    public var plannedDurationNS: UInt64?
    public var startedNS: UInt64?
    public var endedNS: UInt64?

    public var elapsedNS: UInt64? {
        guard let start = startedNS, let end = endedNS else { return nil }
        return end >= start ? end - start : 0
    }
}

struct HeldInput {
    var buttons: [Int64: RecordedEvent] = [:]
    var scrollActive = false
    var momentumActive = false
    var lastScroll: RecordedEvent?
    var lastEvent: RecordedEvent?

    mutating func observe(_ event: RecordedEvent) {
        lastEvent = event
        if event.type.isDown || event.type.isDrag { buttons[event.button] = event }
        if event.type.isUp { buttons.removeValue(forKey: event.button) }
        if let scroll = event.scroll {
            lastScroll = event
            if scroll.scrollPhase & (4 | 8) != 0 { scrollActive = false }
            else if scroll.scrollPhase & (1 | 2 | 128) != 0 { scrollActive = true }
            // Momentum uses begin=1, continue=2, end=3, not the scroll-phase bitmask.
            if scroll.momentumPhase == 3 { momentumActive = false }
            else if scroll.momentumPhase != 0 { momentumActive = true }
        }
    }
}

public enum Playback {
    public static func run(
        _ recording: Recording, options: PlaybackOptions, cancellation: Cancellation
    ) throws -> PlaybackReport {
        try run(recording, options: options, cancellation: cancellation, post: { $0.post(tap: .cghidEventTap) })
    }

    static func run(
        _ recording: Recording, options: PlaybackOptions, cancellation: Cancellation,
        post: @escaping @Sendable (CGEvent) -> Void
    ) throws -> PlaybackReport {
        try recording.validate()
        guard !recording.events.isEmpty else { throw MouseRecorderError("The recording contains no events to replay.") }
        if let loops = options.loops, loops <= 0 {
            throw MouseRecorderError("Loop count must be greater than zero.")
        }
        _ = try MachClock.scaledOffset(recording.replayDurationNS, speed: options.speed)
        let result = Mutex<Result<PlaybackReport, any Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            let outcome = Result { try execute(recording, options: options, cancellation: cancellation, post: post) }
            result.withLock { $0 = outcome }
            finished.signal()
        }
        thread.name = "cursor-replay.playback"
        thread.qualityOfService = .userInteractive
        thread.threadPriority = 1
        thread.start()
        finished.wait()
        guard let outcome = result.withLock({ $0 }) else {
            throw MouseRecorderError("Playback thread finished without a result.")
        }
        return try outcome.get()
    }

    private static func execute(
        _ recording: Recording, options: PlaybackOptions, cancellation: Cancellation,
        post: @Sendable (CGEvent) -> Void
    ) throws -> PlaybackReport {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw MouseRecorderError("Could not create the playback HID event source.")
        }
        source.localEventsSuppressionInterval = 0
        let clock = MachClock()
        if let tagBase = options.tagBase {
            guard options.loops == 1, tagBase >= 0,
                  !tagBase.addingReportingOverflow(Int64(recording.events.count)).overflow else {
                throw MouseRecorderError("Verification tags require one loop and a valid tag range.")
            }
        }
        let events = try recording.events.enumerated().map { index, event in
            try event.makeEvent(source: source, userData: options.tagBase.map { $0 + Int64(index) })
        }
        let offsets = try recording.events.map {
            try MachClock.scaledOffset(recording.leadingIdleNS + $0.timeNS, speed: options.speed)
        }
        let spanNS = max(try MachClock.scaledOffset(recording.replayDurationNS, speed: options.speed), 1_000_000)
        // Unbounded playback checks its first loop here and each subsequent deadline below.
        let totalNS = spanNS.multipliedReportingOverflow(by: UInt64(options.loops ?? 1))
        let paddedNow = clock.nowNS.addingReportingOverflow(21_000_000)
        guard !totalNS.overflow, !paddedNow.overflow,
              !paddedNow.partialValue.addingReportingOverflow(totalNS.partialValue).overflow else {
            throw MouseRecorderError("Total playback duration exceeds the nanosecond clock range.")
        }
        let totalTicks = try clock.ticks(forNS: totalNS.partialValue)
        let start = mach_absolute_time().addingReportingOverflow(try clock.ticks(forNS: 20_000_000))
        let finalDeadline = start.partialValue.addingReportingOverflow(totalTicks)
        guard !start.overflow, !finalDeadline.overflow, finalDeadline.partialValue <= clock.maximumTick else {
            throw MouseRecorderError("Playback deadline exceeds the absolute clock range.")
        }
        var report = PlaybackReport()
        report.plannedDurationNS = options.loops == nil ? nil : totalNS.partialValue
        let startedNS = clock.nanoseconds(at: start.partialValue)
        report.startedNS = startedNS
        var held = HeldInput()
        var failure: (any Error)?
        var loopOffset: UInt64 = 0
        do {
            loop: while !cancellation.isCancelled {
                if let loops = options.loops, report.completedLoops >= loops { break }
                let nextOffset = loopOffset.addingReportingOverflow(spanNS)
                guard !nextOffset.overflow, nextOffset.partialValue <= UInt64.max - startedNS else {
                    throw MouseRecorderError("Total playback duration exceeds the nanosecond clock range.")
                }
                let end = start.partialValue.addingReportingOverflow(try clock.ticks(forNS: nextOffset.partialValue))
                guard !end.overflow, end.partialValue <= clock.maximumTick else {
                    throw MouseRecorderError("Playback deadline exceeds the absolute clock range.")
                }
                for (index, event) in events.enumerated() {
                    let target = start.partialValue + (try clock.ticks(forNS: loopOffset + offsets[index]))
                    guard try clock.wait(until: target, cancellation: cancellation),
                          !cancellation.isCancelled else { break loop }
                    let userData = options.tagBase.map { $0 + Int64(index) } ?? recording.events[index].sourceUserData
                    guard event.getIntegerValueField(.eventSourceUserData) == userData else {
                        throw MouseRecorderError("CoreGraphics tag readback mismatch: requested \(userData), read \(event.getIntegerValueField(.eventSourceUserData)).")
                    }
                    let posted = clock.nowNS
                    // Stamp the actual submission time, never the ideal deadline.
                    event.timestamp = posted
                    post(event)
                    let returned = clock.nowNS
                    held.observe(recording.events[index])
                    report.postedEvents += 1
                    if options.loops != nil {
                        report.samples.append(PostSample(
                            index: index, targetNS: clock.nanoseconds(at: target), postedNS: posted, returnedNS: returned
                        ))
                    }
                }
                guard try clock.wait(until: end.partialValue, cancellation: cancellation) else { break loop }
                report.cleanupEvents += try cleanup(&held, source: source, clock: clock, post: post)
                report.completedLoops += 1
                loopOffset = nextOffset.partialValue
            }
        } catch {
            failure = error
        }
        do {
            report.cleanupEvents += try cleanup(&held, source: source, clock: clock, post: post)
        } catch {
            if let failure {
                throw MouseRecorderError("\(failure.localizedDescription) Safety cleanup also failed: \(error.localizedDescription)")
            }
            throw error
        }
        if let failure { throw failure }
        report.stopReason = cancellation.reason
        report.endedNS = clock.nowNS
        return report
    }

    static func cleanup(
        _ held: inout HeldInput, source: CGEventSource, clock: MachClock,
        post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) throws -> Int {
        var count = 0
        var failures: [String] = []
        for button in held.buttons.keys.sorted() {
            guard let original = held.buttons[button] else { continue }
            let type: CGEventType = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
            guard let event = CGEvent(
                mouseEventSource: source, mouseType: type,
                mouseCursorPosition: (held.lastEvent ?? original).location.cgPoint,
                mouseButton: button == 0 ? .left : button == 1 ? .right : .center
            ) else {
                failures.append("Could not create a safety mouse-up for button \(button).")
                continue
            }
            event.flags = CGEventFlags(rawValue: (held.lastEvent ?? original).flags)
            event.setIntegerValueField(.mouseEventButtonNumber, value: button)
            event.setIntegerValueField(.mouseEventClickState, value: original.clickState)
            event.setIntegerValueField(.mouseEventNumber, value: original.mouseEventNumber)
            event.setDoubleValueField(.mouseEventPressure, value: 0)
            event.timestamp = clock.nowNS
            post(event)
            held.buttons.removeValue(forKey: button)
            count += 1
        }
        if let last = held.lastScroll, held.scrollActive || held.momentumActive {
            for momentum in [false, true] {
                guard momentum ? held.momentumActive : held.scrollActive else { continue }
                guard let event = CGEvent(
                    scrollWheelEvent2Source: source,
                    units: last.scroll?.isContinuous == 0 ? .line : .pixel,
                    wheelCount: 3, wheel1: 0, wheel2: 0, wheel3: 0
                ) else {
                    failures.append("Could not create a safety \(momentum ? "momentum" : "scroll") end event.")
                    continue
                }
                event.location = (held.lastEvent ?? last).location.cgPoint
                event.flags = CGEventFlags(rawValue: (held.lastEvent ?? last).flags)
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: last.scroll?.isContinuous ?? 1)
                event.setIntegerValueField(.scrollWheelEventScrollPhase, value: momentum ? 0 : 4)
                event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum ? 3 : 0)
                event.timestamp = clock.nowNS
                post(event)
                if momentum { held.momentumActive = false } else { held.scrollActive = false }
                count += 1
            }
        }
        if !failures.isEmpty { throw MouseRecorderError(failures.joined(separator: " ")) }
        return count
    }
}
