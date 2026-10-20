import CoreGraphics
import Foundation
import Testing
@testable import MouseRecorderCore

func sample(_ type: CGEventType = .mouseMoved, at time: UInt64 = 0) throws -> RecordedEvent {
    let source = try #require(CGEventSource(stateID: .hidSystemState))
    let event = try #require(CGEvent(
        mouseEventSource: source, mouseType: type,
        mouseCursorPosition: CGPoint(x: -144.125, y: 350.75),
        mouseButton: type == .otherMouseDown || type == .otherMouseUp || type == .otherMouseDragged ? .center : .left
    ))
    event.timestamp = 1_000_000_000 + time
    event.flags = [.maskShift, .maskAlternate, .maskNonCoalesced]
    event.setIntegerValueField(.mouseEventClickState, value: 2)
    event.setDoubleValueField(.mouseEventPressure, value: 0.625)
    event.setIntegerValueField(.mouseEventDeltaX, value: -17)
    event.setIntegerValueField(.mouseEventDeltaY, value: 4)
    return try RecordedEvent(event: event, relativeTo: 1_000_000_000)
}

func recording(_ events: [RecordedEvent]) -> Recording {
    Recording(header: RecordingHeader(displays: []), events: events)
}

struct RecordingTests {
    @Test func mouseFieldsAndNativePayloadRoundTrip() throws {
        let original = try sample(.otherMouseDragged)
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        let restored = try original.makeEvent(source: source)
        restored.timestamp = 1_000_000_000
        let actual = try RecordedEvent(event: restored, relativeTo: 1_000_000_000)
        #expect(actual.type == .otherMouseDragged)
        #expect(actual.location == original.location)
        #expect(actual.button == 2)
        #expect(actual.flags == original.flags)
        #expect(actual.clickState == 2)
        #expect(actual.pressure == original.pressure)
        #expect(actual.deltaX == -17)
        #expect(actual.deltaY == 4)
        #expect(!original.nativeData.isEmpty)
    }

    @Test func scrollRestoresAllRepresentationsAndMomentum() throws {
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: source, units: .pixel,
            wheelCount: 3, wheel1: -17, wheel2: 8, wheel3: 1
        ))
        for (fields, values) in [
            (ScrollFields.lineFields, [-2, 3, 0]),
            (ScrollFields.fixedFields, [-65537, 98305, 1]),
            (ScrollFields.pointFields, [-17, 8, 1])
        ] {
            for (field, value) in zip(fields, values) { event.setIntegerValueField(field, value: Int64(value)) }
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        event.setIntegerValueField(.scrollWheelEventScrollCount, value: 12)
        if let accelerated = CGEventField(rawValue: 176) {
            event.setDoubleValueField(accelerated, value: -12.625)
        }
        event.timestamp = 42
        let original = try RecordedEvent(event: event, relativeTo: 42)
        let restored = try original.makeEvent(source: source)
        #expect(ScrollFields(event: restored) == original.scroll)
        #expect(original.scroll?.fixedDeltaRaw == [-65537, 98305, 1])
    }

    @Test func jsonRoundTripPreservesNanosecondsAndCoordinates() throws {
        let original = recording(try [sample(), sample(at: 17_123_456_789)])
        let data = try JSONEncoder().encode(original)
        let actual = try JSONDecoder().decode(Recording.self, from: data)
        try actual.validate()
        #expect(actual.events == original.events)
        #expect(actual.durationNS == 17_123_456_789)
    }

    @Test func invalidTimelinesAndVersionAreRejected() throws {
        #expect(throws: (any Error).self) { try recording([sample(at: 1)]).validate() }
        #expect(throws: (any Error).self) { try recording([sample(), sample(at: 20), sample(at: 10)]).validate() }
        var future = recording([])
        future.header.formatVersion = 4
        #expect(throws: (any Error).self) { try future.validate() }
    }

    @Test func malformedScrollAxesAreRejected() throws {
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0
        ))
        event.timestamp = 0
        var original = try RecordedEvent(event: event, relativeTo: 0)
        original.scroll?.pointDelta = [1]
        #expect(throws: (any Error).self) { try recording([original]).validate() }
    }

    @Test func truncatedButtonSequenceIsFlagged() throws {
        #expect(!recording([try sample(.leftMouseDragged)]).captureWarnings.isEmpty)
        #expect(!recording([try sample(.leftMouseDown)]).captureWarnings.isEmpty)
        #expect(recording(try [sample(.leftMouseDown), sample(.leftMouseUp, at: 10)]).captureWarnings.isEmpty)
    }

    @Test func invalidNativePayloadFailsBeforePosting() throws {
        var original = try sample()
        original.nativeData = Data([0, 1, 2, 3])
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        #expect(throws: (any Error).self) { try original.makeEvent(source: source) }
    }

    @Test func pressureQuantizationDoesNotChangeDuringRestoration() throws {
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        let event = try #require(CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDragged,
            mouseCursorPosition: .zero, mouseButton: .left
        ))
        event.timestamp = 0
        for value in 0...255 {
            event.setDoubleValueField(.mouseEventPressure, value: Double(value) / 255)
            let captured = try RecordedEvent(event: event, relativeTo: 0)
            let restored = try captured.makeEvent(source: source)
            #expect(restored.getDoubleValueField(.mouseEventPressure) == captured.pressure)
        }
    }

    @Test func verificationTagOverridesRecordedSourceMetadataBeforeConstruction() throws {
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        var captured = try sample()
        captured.sourceUserData = 0x4D5250524F4245
        let first = try captured.makeEvent(source: source, userData: 12345)
        let second = try captured.makeEvent(source: source, userData: 12346)
        #expect(first.getIntegerValueField(.eventSourceUserData) == 12345)
        #expect(second.getIntegerValueField(.eventSourceUserData) == 12346)
    }

    @Test func lineScrollingRemainsDiscreteAndAllMouseTypesSurvive() throws {
        let source = try #require(CGEventSource(stateID: .hidSystemState))
        let line = try #require(CGEvent(
            scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: -3, wheel2: 2, wheel3: 0
        ))
        line.timestamp = 0
        let original = try RecordedEvent(event: line, relativeTo: 0)
        let restored = try original.makeEvent(source: source)
        #expect(ScrollFields(event: restored) == original.scroll)
        #expect(restored.getIntegerValueField(.scrollWheelEventIsContinuous) == 0)
        for kind in EventKind.allCases where kind != .scrollWheel {
            let mouse = try sample(kind.cgType)
            let recreated = try mouse.makeEvent(source: source)
            #expect(recreated.type == kind.cgType)
            #expect(recreated.getIntegerValueField(.mouseEventClickState) == mouse.clickState)
            #expect(recreated.getIntegerValueField(.mouseEventButtonNumber) == mouse.button)
        }
    }

    @Test func physicalMachTickRecordingIsNotCompressedByTimebase() throws {
        let clock = MachClock(numerator: 125, denominator: 3)
        let rawOrigin: UInt64 = 4_244_332_817_791
        let rawSpan: UInt64 = 23_986_768
        var legacy = recording(try [sample(), sample(at: rawSpan)])
        legacy.header.formatVersion = 1
        legacy.header.timestampOriginNS = rawOrigin
        let fixed = try legacy.normalizingLegacyTimestamps(near: clock.nanoseconds(at: rawOrigin), clock: clock)
        #expect(legacy.durationNS == 23_986_768)
        #expect(fixed.durationNS == clock.nanoseconds(at: rawOrigin + rawSpan) - clock.nanoseconds(at: rawOrigin))
        #expect(fixed.durationNS > 999_000_000 && fixed.durationNS < 1_000_000_000)
        #expect(fixed.events.allSatisfy { $0.timestampUnit == .machAbsoluteTicks })
        #expect(fixed.header.formatVersion == 2)
    }

    @Test func legacyNanosecondsAreNotConvertedTwiceAndAmbiguityFails() throws {
        let clock = MachClock(numerator: 125, denominator: 3)
        let origin: UInt64 = 176_847_200_741_291
        var legacy = recording(try [sample(), sample(at: 10_000_000)])
        legacy.header.formatVersion = 1
        legacy.header.timestampOriginNS = origin
        let fixed = try legacy.normalizingLegacyTimestamps(near: origin, clock: clock)
        #expect(fixed.durationNS == 10_000_000)
        #expect(fixed.events.allSatisfy { $0.timestampUnit == .nanoseconds })
        #expect(throws: (any Error).self) {
            try legacy.normalizingLegacyTimestamps(near: 1, clock: clock)
        }
    }

    @Test func fullSessionTimingSurvivesJSONWithoutChangingEventOffsets() throws {
        var original = recording(try [sample(), sample(at: 10_000_000)])
        original.header.timestampOriginNS = 1_000_000_000
        original.header.captureStartedNS = 800_000_000
        original.header.captureEndedNS = 1_500_000_000
        let restored = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(original))
        try restored.validate()
        #expect(restored.events == original.events)
        #expect(restored.leadingIdleNS == 200_000_000)
        #expect(restored.sessionDurationNS == 700_000_000)
        #expect(restored.replayDurationNS == 700_000_000)
        #expect(recording(original.events).replayDurationNS == 10_000_000)
    }

    @Test func invalidOrPartialSessionBoundsAreRejected() throws {
        var original = recording(try [sample(), sample(at: 10_000_000)])
        original.header.timestampOriginNS = 1_000_000_000
        original.header.captureStartedNS = 900_000_000
        #expect(throws: (any Error).self) { try original.validate() }
        original.header.captureEndedNS = 1_005_000_000
        #expect(throws: (any Error).self) { try original.validate() }
        original.header.captureEndedNS = 1_020_000_000
        original.header.captureStartedNS = 1_005_000_000
        #expect(throws: (any Error).self) { try original.validate() }
    }
}
