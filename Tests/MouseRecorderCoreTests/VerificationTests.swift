import Testing
@testable import MouseRecorderCore

struct VerificationTests {
    private func fixture() throws -> (Recording, Capture, PlaybackReport) {
        let original = recording(try [sample(), sample(at: 10_000_000)])
        let observations = original.events.enumerated().map { index, event in
            ObservedEvent(
                event: event, timestampNS: 1_000_000_000 + event.timeNS,
                arrivalNS: 1_000_000_000 + event.timeNS + 100_000, tag: 100 + Int64(index)
            )
        }
        let capture = Capture(recording: original, observations: observations, ignoredEvents: 0)
        var playback = PlaybackReport()
        playback.samples = original.events.enumerated().map { index, event in
            PostSample(index: index, targetNS: 1_000_000_000 + event.timeNS, postedNS: 1_000_000_000 + event.timeNS)
        }
        return (original, capture, playback)
    }

    @Test func exactEventsPassWithMeasuredArrivalLatency() throws {
        let (original, capture, playback) = try fixture()
        let report = VerificationReport.compare(original: original, capture: capture, playback: playback, tagBase: 100)
        #expect(report.passed)
        #expect(abs(report.arrivalTiming.maximum - 0.1) < 0.000001)
        #expect(report.position.maximum == 0)
    }

    @Test func missingEventIsNotPairedWithNextEvent() throws {
        var (original, capture, playback) = try fixture()
        capture.observations.removeFirst()
        capture.recording.events.removeFirst()
        let report = VerificationReport.compare(original: original, capture: capture, playback: playback, tagBase: 100)
        #expect(!report.passed)
        #expect(report.missingIndices == [0])
        #expect(report.matchedCount == 1)
        #expect(report.timestampTiming.maximum == 0)
    }

    @Test func positionPayloadAndTimingFailuresAreMeasured() throws {
        var (original, capture, playback) = try fixture()
        capture.observations[1].event.location.x += 3
        capture.observations[1].event.location.y += 4
        capture.observations[1].event.clickState = 9
        capture.observations[1].arrivalNS += 3_000_000
        let report = VerificationReport.compare(original: original, capture: capture, playback: playback, tagBase: 100)
        #expect(!report.passed)
        #expect(report.position.maximum == 5)
        #expect(report.payloadMismatches == 1)
        #expect(abs(report.arrivalTiming.maximum - 3.1) < 0.000001)
    }

    @Test func duplicatesReorderingAndPhysicalInterferenceFail() throws {
        var (original, capture, playback) = try fixture()
        capture.observations.reverse()
        capture.observations.append(capture.observations[0])
        capture.ignoredEvents = 1
        let report = VerificationReport.compare(original: original, capture: capture, playback: playback, tagBase: 100)
        #expect(!report.passed)
        #expect(report.duplicateTags == 1)
        #expect(report.reorderedEvents == 1)
        #expect(report.ignoredPhysicalEvents == 1)
    }

    @Test func emptyCaptureDoesNotReportSuccessfulZeroErrors() throws {
        let (original, _, playback) = try fixture()
        let capture = Capture(recording: recording([]), observations: [], ignoredEvents: 0)
        let report = VerificationReport.compare(original: original, capture: capture, playback: playback, tagBase: 100)
        #expect(!report.passed)
        #expect(report.position.count == 0)
        #expect(report.missingIndices == [0, 1])
    }

    @Test func tapInterruptionOrPostingDelayCannotPass() throws {
        var (original, capture, playback) = try fixture()
        capture.recording.header.tapInterruptions = 1
        var report = VerificationReport.compare(original: original, capture: capture, playback: playback, tagBase: 100)
        #expect(!report.passed)
        capture.recording.header.tapInterruptions = 0
        playback.samples[1].postedNS += 2_000_001
        report = VerificationReport.compare(original: original, capture: capture, playback: playback, tagBase: 100)
        #expect(!report.passed)
        #expect(report.postingTiming.maximum > 2)
    }

    @Test func reservedFlagDifferenceIsExplainedButNotHidden() throws {
        var (original, capture, playback) = try fixture()
        original.events[0].flags = 0
        capture.observations[0].event.flags = 0x20000000
        let report = VerificationReport.compare(original: original, capture: capture, playback: playback, tagBase: 100)
        #expect(!report.passed)
        #expect(report.rawFlagMismatches == 1)
        #expect(report.modifierMismatches == 0)
        #expect(report.addedFlagBits == 0x20000000)
    }
}
