import Foundation
import Testing
@testable import MouseRecorderCore

struct TimelineHarnessTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CURSOR_REPLAY_TIMELINE_FILE"] != nil ||
                  ProcessInfo.processInfo.environment["MOUSEREC_TIMELINE_FILE"] != nil))
    func recordedTimelineWithoutSystemInput() throws {
        let path = try #require(ProcessInfo.processInfo.environment["CURSOR_REPLAY_TIMELINE_FILE"] ??
                                ProcessInfo.processInfo.environment["MOUSEREC_TIMELINE_FILE"])
        let original = try Recording.load(from: path)
        let report = try Playback.run(original, options: PlaybackOptions(), cancellation: Cancellation(), post: { _ in })
        let first = try #require(report.samples.first)
        let last = try #require(report.samples.last)
        let errors = report.samples.map {
            Double($0.postedNS >= $0.targetNS ? $0.postedNS - $0.targetNS : $0.targetNS - $0.postedNS) / 1_000_000
        }
        print("NO-POST TIMELINE HARNESS: \(path)")
        print(String(format: "Recorded first-to-last span %.9f s; scheduled span %.9f s; simulated-submission span %.9f s.",
                     Double(original.durationNS) / 1_000_000_000,
                     Double(last.targetNS - first.targetNS) / 1_000_000_000,
                     Double(last.postedNS - first.postedNS) / 1_000_000_000))
        print("Simulated-submission error: \(Statistics(errors).text(unit: "ms"))")
        #expect(report.postedEvents == original.events.count)
        #expect(report.completedLoops == 1)
        #expect(last.targetNS >= first.targetNS)
        let span = last.targetNS - first.targetNS
        let difference = span >= original.durationNS ? span - original.durationNS : original.durationNS - span
        #expect(difference <= 1)
        #expect(try #require(report.elapsedNS) >= #require(report.plannedDurationNS))
        print("No CGEvent.post call was made. This checks the real scheduler, not HID delivery or target-app behavior.")
    }
}
