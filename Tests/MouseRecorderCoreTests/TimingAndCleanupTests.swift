import CoreGraphics
import Testing
import Synchronization
@testable import MouseRecorderCore

struct TimingTests {
    @Test func defaultSpeedPreservesIntegerTimestampAboveDoublePrecision() throws {
        let value: UInt64 = 9_007_199_254_740_993
        #expect(try MachClock.scaledOffset(value, speed: 1) == value)
    }

    @Test func scaledOffsetsAndInvalidSpeeds() throws {
        #expect(try MachClock.scaledOffset(10_000_000, speed: 2) == 5_000_000)
        #expect(try MachClock.scaledOffset(10_000_000, speed: 0.5) == 20_000_000)
        for speed in [0.0, -1, Double.nan, Double.infinity, Double.leastNonzeroMagnitude] {
            #expect(throws: (any Error).self) { try MachClock.scaledOffset(100, speed: speed) }
        }
    }

    @Test func clockConversionAndNanosecondRounding() throws {
        let clock = MachClock()
        for ns: UInt64 in [0, 1, 1_000, 1_234_567_890_123] {
            let ticks = try clock.ticks(forNS: ns)
            let restored = clock.nanoseconds(at: ticks)
            #expect(restored >= ns)
            #expect(restored - ns <= clock.numerator / clock.denominator + 1)
        }
    }

    @Test func statisticsUseNearestRankP95() {
        let stats = Statistics((1...100).map(Double.init))
        #expect(stats.maximum == 100)
        #expect(stats.mean == 50.5)
        #expect(stats.p95 == 95)
        #expect(Statistics([]).count == 0)
    }

    @Test func physicalAndPostedEventsUseTheirOwnClockUnits() {
        let clock = MachClock(numerator: 125, denominator: 3)
        let ticks: UInt64 = 4_244_332_817_791
        let ns = clock.nanoseconds(at: ticks)
        let physical = clock.eventTimestamp(ticks, near: ns + 1_000_000)
        let posted = clock.eventTimestamp(ns, near: ns + 1_000_000)
        #expect(physical.ns == ns)
        #expect(physical.unit == .machAbsoluteTicks)
        #expect(posted.ns == ns)
        #expect(posted.unit == .nanoseconds)
        let identityClock = MachClock(numerator: 1, denominator: 1)
        #expect(identityClock.eventTimestamp(ns, near: ns).ns == ns)
    }
}

struct CleanupTests {
    @Test func allHeldButtonsAreTrackedAndReleasesRemoveThem() throws {
        var state = HeldInput()
        state.observe(try sample(.leftMouseDown))
        state.observe(try sample(.otherMouseDragged))
        #expect(Set(state.buttons.keys) == [0, 2])
        state.observe(try sample(.leftMouseUp))
        #expect(Set(state.buttons.keys) == [2])
    }

    @Test func scrollAndMomentumHaveDifferentEndValues() throws {
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0
        ))
        event.timestamp = 0
        var state = HeldInput()
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        state.observe(try RecordedEvent(event: event, relativeTo: 0))
        #expect(state.scrollActive)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
        state.observe(try RecordedEvent(event: event, relativeTo: 0))
        #expect(!state.scrollActive)
        #expect(state.momentumActive)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 3)
        state.observe(try RecordedEvent(event: event, relativeTo: 0))
        #expect(!state.momentumActive)
    }

    @Test func cleanupCreatesMatchingUpsIncludingButton31WithoutPosting() throws {
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        var state = HeldInput()
        state.observe(try sample(.leftMouseDown))
        var other = try sample(.otherMouseDown)
        other.button = 31
        state.observe(other)
        var last = try sample()
        last.location = Position(x: -700.5, y: 20.25)
        state.observe(last)
        var events: [CGEvent] = []
        let count = try Playback.cleanup(&state, source: source, clock: MachClock()) { events.append($0) }
        #expect(count == 2)
        #expect(state.buttons.isEmpty)
        #expect(events.map(\.type) == [.leftMouseUp, .otherMouseUp])
        #expect(events.map { $0.getIntegerValueField(.mouseEventButtonNumber) } == [0, 31])
        #expect(events.allSatisfy { $0.location == last.location.cgPoint })
        #expect(events.allSatisfy { $0.getDoubleValueField(.mouseEventPressure) == 0 })
    }

    @Test func cleanupEndsBothPhasesWithZeroDeltasWithoutPosting() throws {
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: source, units: .pixel, wheelCount: 3, wheel1: -100, wheel2: 30, wheel3: 1
        ))
        event.timestamp = 0
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        var state = HeldInput()
        state.observe(try RecordedEvent(event: event, relativeTo: 0))
        var endings: [CGEvent] = []
        let count = try Playback.cleanup(&state, source: source, clock: MachClock()) { endings.append($0) }
        #expect(count == 2)
        #expect(!state.scrollActive && !state.momentumActive)
        #expect(endings.map { $0.getIntegerValueField(.scrollWheelEventScrollPhase) } == [4, 0])
        #expect(endings.map { $0.getIntegerValueField(.scrollWheelEventMomentumPhase) } == [0, 3])
        for ending in endings {
            let fields = ScrollFields(event: ending)
            #expect(fields.pointDelta == [0, 0, 0])
            #expect(fields.lineDelta == [0, 0, 0])
            #expect(fields.fixedDeltaRaw == [0, 0, 0])
        }
    }
}

struct PlaybackTests {
    @Test func cancellationBeforePlaybackPostsNothing() throws {
        let cancellation = Cancellation()
        cancellation.cancel("test cancellation")
        let report = try Playback.run(recording([sample()]), options: PlaybackOptions(), cancellation: cancellation)
        #expect(report.postedEvents == 0)
        #expect(report.cleanupEvents == 0)
        #expect(report.completedLoops == 0)
        #expect(report.stopReason == "test cancellation")
    }

    @Test func overflowingTimelineFailsBeforeAnyPost() throws {
        let long = recording(try [sample(), sample(at: 1)])
        var original = long
        original.events[1].timeNS = UInt64.max
        #expect(throws: (any Error).self) {
            try Playback.run(original, options: PlaybackOptions(), cancellation: Cancellation())
        }
    }

    @Test func fullSessionPausesAndLoopsUseAbsoluteTargetsWithoutPosting() throws {
        var original = recording(try [sample(), sample(at: 5_000_000)])
        original.header.timestampOriginNS = 1_000_000_000
        original.header.captureStartedNS = 990_000_000
        original.header.captureEndedNS = 1_020_000_000
        let observed = Mutex<[UInt64]>([])
        let report = try Playback.run(
            original, options: PlaybackOptions(loops: 2), cancellation: Cancellation(),
            post: { event in observed.withLock { $0.append(event.timestamp) } }
        )
        let start = try #require(report.startedNS)
        #expect(report.samples.map { $0.targetNS - start } == [10_000_000, 15_000_000, 40_000_000, 45_000_000])
        #expect(observed.withLock { $0.count } == 4)
        #expect(report.completedLoops == 2)
        #expect(report.plannedDurationNS == 60_000_000)
        #expect(try #require(report.elapsedNS) >= 60_000_000)
    }

    @Test func cancellationBeforeSessionEndStillReleasesHeldButtonWithoutPosting() throws {
        var original = recording([try sample(.leftMouseDown)])
        original.header.timestampOriginNS = 1_000_000_000
        original.header.captureStartedNS = 1_000_000_000
        original.header.captureEndedNS = 1_200_000_000
        let cancellation = Cancellation()
        let observed = Mutex<[UInt32]>([])
        let report = try Playback.run(
            original, options: PlaybackOptions(), cancellation: cancellation,
            post: { event in
                observed.withLock { $0.append(event.type.rawValue) }
                if event.type == .leftMouseDown { cancellation.cancel("test stop") }
            }
        )
        #expect(observed.withLock { $0 } == [CGEventType.leftMouseDown.rawValue, CGEventType.leftMouseUp.rawValue])
        #expect(report.cleanupEvents == 1)
        #expect(report.completedLoops == 0)
    }
}
