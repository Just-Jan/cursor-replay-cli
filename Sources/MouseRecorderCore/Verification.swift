import CoreGraphics
import Foundation

public struct Statistics: Sendable {
    public let count: Int
    public let maximum: Double
    public let mean: Double
    public let p95: Double

    public init(_ values: [Double]) {
        count = values.count
        maximum = values.max() ?? 0
        mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let sorted = values.sorted()
        p95 = sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }

    public func text(unit: String) -> String {
        guard count > 0 else { return "unavailable (no matched events)" }
        return String(format: "max %.6f / mean %.6f / p95 %.6f %@", maximum, mean, p95, unit)
    }
}

public struct VerificationReport: Sendable {
    public var expectedCount: Int
    public var observedCount: Int
    public var matchedCount: Int
    public var missingIndices: [Int]
    public var duplicateTags: Int
    public var reorderedEvents: Int
    public var payloadMismatches: Int
    public var mismatchExamples: [String]
    public var position: Statistics
    public var timestampTiming: Statistics
    public var arrivalTiming: Statistics
    public var postingTiming: Statistics
    public var scrollSumsMatch: Bool
    public var expectedScrollSums: [String: Decimal]
    public var observedScrollSums: [String: Decimal]
    public var captureInterruptions: Int
    public var captureError: String?
    public var ignoredPhysicalEvents: Int
    public var modifierMismatches: Int
    public var rawFlagMismatches: Int
    public var addedFlagBits: UInt64
    public var removedFlagBits: UInt64

    public var passed: Bool {
        expectedCount > 0 && expectedCount == observedCount && matchedCount == expectedCount &&
        missingIndices.isEmpty && duplicateTags == 0 && reorderedEvents == 0 && payloadMismatches == 0 &&
        position.maximum == 0 && timestampTiming.maximum <= 2 && arrivalTiming.maximum <= 2 &&
        postingTiming.maximum <= 2 && scrollSumsMatch && captureInterruptions == 0 &&
        captureError == nil && ignoredPhysicalEvents == 0
    }

    public static func compare(
        original: Recording, capture: Capture, playback: PlaybackReport, tagBase: Int64
    ) -> VerificationReport {
        let targets = Dictionary(playback.samples.map { ($0.index, $0.targetNS) }, uniquingKeysWith: { first, _ in first })
        var byIndex: [Int: ObservedEvent] = [:]
        var duplicateTags = 0
        var reordered = 0
        var previousIndex = -1
        for observation in capture.observations {
            let offset = observation.tag.subtractingReportingOverflow(tagBase)
            guard !offset.overflow, offset.partialValue >= 0, offset.partialValue < Int64(original.events.count) else { continue }
            let index = Int(offset.partialValue)
            if index < previousIndex { reordered += 1 }
            previousIndex = index
            if byIndex[index] != nil { duplicateTags += 1 }
            else { byIndex[index] = observation }
        }
        var positions: [Double] = []
        var timestamps: [Double] = []
        var arrivals: [Double] = []
        var mismatches = 0
        var examples: [String] = []
        var missing: [Int] = []
        var modifierMismatches = 0
        var flagMismatches = 0
        var addedBits: UInt64 = 0
        var removedBits: UInt64 = 0
        let modifierMask: CGEventFlags = [
            .maskAlphaShift, .maskShift, .maskControl, .maskAlternate,
            .maskCommand, .maskNumericPad, .maskHelp, .maskSecondaryFn
        ]
        for (index, event) in original.events.enumerated() {
            guard let observed = byIndex[index], let target = targets[index] else { missing.append(index); continue }
            positions.append(hypot(event.location.x - observed.event.location.x, event.location.y - observed.event.location.y))
            timestamps.append(errorMS(observed.timestampNS, target))
            arrivals.append(errorMS(observed.arrivalNS, target))
            let actual = observed.event
            var fields: [String] = []
            if event.type != actual.type { fields.append("type") }
            if event.flags != actual.flags {
                flagMismatches += 1
                addedBits |= actual.flags & ~event.flags
                removedBits |= event.flags & ~actual.flags
                fields.append("flags recorded=0x\(String(event.flags, radix: 16)) observed=0x\(String(actual.flags, radix: 16))")
            }
            if event.flags & modifierMask.rawValue != actual.flags & modifierMask.rawValue { modifierMismatches += 1 }
            if event.type != .scrollWheel {
                if event.button != actual.button { fields.append("button") }
                if event.clickState != actual.clickState { fields.append("clickState") }
                if event.pressure != actual.pressure { fields.append("pressure") }
                if event.deltaX != actual.deltaX || event.deltaY != actual.deltaY { fields.append("mouse deltas") }
                if event.mouseEventNumber != actual.mouseEventNumber { fields.append("mouse event number") }
            }
            if event.scroll != actual.scroll { fields.append("scroll fields/phases") }
            if !fields.isEmpty {
                mismatches += 1
                if examples.count < 5 { examples.append("Event \(index): \(fields.joined(separator: ", "))") }
            }
        }
        let expectedSums = scrollSums(original.events)
        let actualSums = scrollSums(capture.recording.events)
        return VerificationReport(
            expectedCount: original.events.count, observedCount: capture.observations.count,
            matchedCount: positions.count, missingIndices: missing, duplicateTags: duplicateTags,
            reorderedEvents: reordered, payloadMismatches: mismatches, mismatchExamples: examples,
            position: Statistics(positions), timestampTiming: Statistics(timestamps), arrivalTiming: Statistics(arrivals),
            postingTiming: Statistics(playback.samples.map { errorMS($0.postedNS, $0.targetNS) }),
            scrollSumsMatch: expectedSums == actualSums,
            expectedScrollSums: expectedSums, observedScrollSums: actualSums,
            captureInterruptions: capture.recording.header.tapInterruptions,
            captureError: capture.recording.header.captureError, ignoredPhysicalEvents: capture.ignoredEvents,
            modifierMismatches: modifierMismatches, rawFlagMismatches: flagMismatches,
            addedFlagBits: addedBits, removedFlagBits: removedBits
        )
    }

    static func errorMS(_ actual: UInt64, _ expected: UInt64) -> Double {
        Double(actual >= expected ? actual - expected : expected - actual) / 1_000_000
    }

    public static func scrollSums(_ events: [RecordedEvent]) -> [String: Decimal] {
        var sums: [String: Decimal] = [:]
        for event in events {
            guard let scroll = event.scroll else { continue }
            for (label, values) in [("point", scroll.pointDelta), ("fixedRaw16.16", scroll.fixedDeltaRaw), ("line", scroll.lineDelta)] {
                for (axis, value) in values.enumerated() {
                    sums["\(label).axis\(axis + 1)", default: 0] += Decimal(value)
                }
            }
        }
        return sums
    }
}
