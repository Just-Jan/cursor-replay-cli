import CoreGraphics
import Foundation

public struct MouseRecorderError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum EventKind: String, Codable, CaseIterable, Sendable {
    case mouseMoved, leftMouseDown, leftMouseUp, leftMouseDragged
    case rightMouseDown, rightMouseUp, rightMouseDragged
    case otherMouseDown, otherMouseUp, otherMouseDragged, scrollWheel

    public var cgType: CGEventType {
        switch self {
        case .mouseMoved: .mouseMoved
        case .leftMouseDown: .leftMouseDown
        case .leftMouseUp: .leftMouseUp
        case .leftMouseDragged: .leftMouseDragged
        case .rightMouseDown: .rightMouseDown
        case .rightMouseUp: .rightMouseUp
        case .rightMouseDragged: .rightMouseDragged
        case .otherMouseDown: .otherMouseDown
        case .otherMouseUp: .otherMouseUp
        case .otherMouseDragged: .otherMouseDragged
        case .scrollWheel: .scrollWheel
        }
    }

    public init?(_ type: CGEventType) {
        guard let kind = Self.allCases.first(where: { $0.cgType == type }) else { return nil }
        self = kind
    }

    public var isDown: Bool { [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(self) }
    public var isUp: Bool { [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(self) }
    public var isDrag: Bool { [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(self) }
}

public struct Position: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public init(_ point: CGPoint) { self.init(x: point.x, y: point.y) }
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public enum EventTimestampUnit: String, Codable, Sendable {
    case nanoseconds, machAbsoluteTicks
}

public struct DisplayFrame: Codable, Equatable, Sendable {
    public var id: UInt32
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var scaleFactor: Double
    public var pixelWidth: Int
    public var pixelHeight: Int

    public static func current() throws -> [DisplayFrame] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else {
            throw MouseRecorderError("Could not enumerate active displays.")
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            throw MouseRecorderError("Could not read the active display layout.")
        }
        return try ids.prefix(Int(count)).sorted().map { id in
            guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else {
                throw MouseRecorderError("Could not read display mode for display \(id).")
            }
            let frame = CGDisplayBounds(id)
            return DisplayFrame(
                id: id, x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                scaleFactor: Double(mode.pixelWidth) / Double(mode.width),
                pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight
            )
        }
    }
}

public struct ScrollFields: Codable, Equatable, Sendable {
    public var pointDelta: [Int64]
    public var fixedDeltaRaw: [Int64]
    public var lineDelta: [Int64]
    public var isContinuous: Int64
    public var scrollPhase: Int64
    public var momentumPhase: Int64
    public var scrollCount: Int64
    public var auxiliaryIntegerFields: [String: Int64]
    public var auxiliaryDoubleFields: [String: Double]

    static let pointFields: [CGEventField] = [
        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3
    ]
    static let fixedFields: [CGEventField] = [
        .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis3
    ]
    static let lineFields: [CGEventField] = [
        .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3
    ]

    public init(event: CGEvent) {
        pointDelta = Self.pointFields.map { event.getIntegerValueField($0) }
        // The integer accessor preserves the exact signed 16.16 representation.
        fixedDeltaRaw = Self.fixedFields.map { event.getIntegerValueField($0) }
        lineDelta = Self.lineFields.map { event.getIntegerValueField($0) }
        isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
        scrollPhase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        momentumPhase = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        scrollCount = event.getIntegerValueField(.scrollWheelEventScrollCount)
        auxiliaryIntegerFields = [:]
        auxiliaryDoubleFields = [:]
        for raw: UInt32 in [14, 173, 175, 176, 177, 178] {
            if let field = CGEventField(rawValue: raw) {
                auxiliaryIntegerFields[String(raw)] = event.getIntegerValueField(field)
                if raw >= 175 { auxiliaryDoubleFields[String(raw)] = event.getDoubleValueField(field) }
            }
        }
    }

    func apply(to event: CGEvent) {
        for (fields, values) in [
            (Self.lineFields, lineDelta), (Self.fixedFields, fixedDeltaRaw), (Self.pointFields, pointDelta)
        ] {
            for (field, value) in zip(fields, values) { event.setIntegerValueField(field, value: value) }
        }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: isContinuous)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.setIntegerValueField(.scrollWheelEventScrollCount, value: scrollCount)
        for (raw, value) in auxiliaryIntegerFields {
            if let number = UInt32(raw), let field = CGEventField(rawValue: number) {
                event.setIntegerValueField(field, value: value)
            }
        }
        for (raw, value) in auxiliaryDoubleFields {
            if let number = UInt32(raw), let field = CGEventField(rawValue: number),
               event.getDoubleValueField(field) != value {
                event.setDoubleValueField(field, value: value)
            }
        }
    }
}

public struct RecordedEvent: Codable, Equatable, Sendable {
    public var type: EventKind
    public var timeNS: UInt64
    public var location: Position
    public var flags: UInt64
    public var button: Int64
    public var clickState: Int64
    public var pressure: Double
    public var deltaX: Int64
    public var deltaY: Int64
    public var mouseEventNumber: Int64
    public var sourceUserData: Int64
    public var scroll: ScrollFields?
    public var nativeData: Data
    public var rawTimestamp: UInt64?
    public var timestampUnit: EventTimestampUnit?

    public init(
        event: CGEvent, relativeTo origin: UInt64,
        normalizedTimestampNS: UInt64? = nil, timestampUnit: EventTimestampUnit = .nanoseconds
    ) throws {
        guard let kind = EventKind(event.type) else {
            throw MouseRecorderError("Unsupported event type \(event.type.rawValue).")
        }
        let timestamp = normalizedTimestampNS ?? event.timestamp
        guard timestamp >= origin else {
            throw MouseRecorderError("An event timestamp moved backwards before the recording origin.")
        }
        guard let data = event.data else {
            throw MouseRecorderError("CoreGraphics could not serialize a captured event.")
        }
        type = kind
        timeNS = timestamp - origin
        location = Position(event.location)
        flags = event.flags.rawValue
        button = event.getIntegerValueField(.mouseEventButtonNumber)
        clickState = event.getIntegerValueField(.mouseEventClickState)
        pressure = event.getDoubleValueField(.mouseEventPressure)
        deltaX = event.getIntegerValueField(.mouseEventDeltaX)
        deltaY = event.getIntegerValueField(.mouseEventDeltaY)
        mouseEventNumber = event.getIntegerValueField(.mouseEventNumber)
        sourceUserData = event.getIntegerValueField(.eventSourceUserData)
        scroll = kind == .scrollWheel ? ScrollFields(event: event) : nil
        nativeData = data as Data
        rawTimestamp = event.timestamp
        self.timestampUnit = timestampUnit
    }

    public func makeEvent(source: CGEventSource, userData: Int64? = nil) throws -> CGEvent {
        guard let archived = CGEvent(withDataAllocator: nil, data: nativeData as CFData) else {
            throw MouseRecorderError("Could not restore a \(type.rawValue) event from its native payload.")
        }
        let effectiveUserData = userData ?? sourceUserData
        source.userData = effectiveUserData
        let created: CGEvent?
        if let scroll {
            created = CGEvent(
                scrollWheelEvent2Source: source, units: scroll.isContinuous == 0 ? .line : .pixel,
                wheelCount: 3, wheel1: 0, wheel2: 0, wheel3: 0
            )
        } else {
            created = CGEvent(
                mouseEventSource: source, mouseType: type.cgType,
                mouseCursorPosition: location.cgPoint,
                mouseButton: button == 0 ? .left : button == 1 ? .right : .center
            )
        }
        guard let event = created else {
            throw MouseRecorderError("CoreGraphics could not create a fresh \(type.rawValue) event.")
        }
        // Native events retain source metadata. Set it before construction, not just before posting.
        for field in [CGEventField.mouseEventSubtype, .mouseEventInstantMouser] where type != .scrollWheel {
            event.setIntegerValueField(field, value: archived.getIntegerValueField(field))
        }
        event.location = location.cgPoint
        event.flags = CGEventFlags(rawValue: flags)
        if type != .scrollWheel {
            event.setIntegerValueField(.mouseEventButtonNumber, value: button)
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
            if event.getDoubleValueField(.mouseEventPressure) != pressure {
                event.setDoubleValueField(.mouseEventPressure, value: pressure)
            }
            event.setIntegerValueField(.mouseEventDeltaX, value: deltaX)
            event.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
            event.setIntegerValueField(.mouseEventNumber, value: mouseEventNumber)
        }
        event.setIntegerValueField(.eventSourceUserData, value: effectiveUserData)
        scroll?.apply(to: event)
        return event
    }
}

public struct RecordingHeader: Codable, Sendable {
    public var formatVersion: Int
    public var recordedAt: String
    public var macOSVersion: String
    public var displays: [DisplayFrame]
    public var timestampOriginNS: UInt64?
    public var tapInterruptions: Int
    public var captureError: String?
    public var stopReason: String
    public var coordinateSpace: String
    public var timebaseNumerator: UInt64?
    public var timebaseDenominator: UInt64?
    public var timestampNormalization: String?
    public var captureStartedNS: UInt64?
    public var captureEndedNS: UInt64?

    public init(displays: [DisplayFrame]) {
        formatVersion = 3
        recordedAt = ISO8601DateFormatter().string(from: Date())
        macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
        self.displays = displays
        timestampOriginNS = nil
        tapInterruptions = 0
        captureError = nil
        stopReason = "completed"
        coordinateSpace = "CoreGraphics global display coordinates, logical pixels; do not apply Retina scaling"
        let clock = MachClock()
        timebaseNumerator = clock.numerator
        timebaseDenominator = clock.denominator
        timestampNormalization = nil
        captureStartedNS = nil
        captureEndedNS = nil
    }
}

public struct Recording: Codable, Sendable {
    public var header: RecordingHeader
    public var events: [RecordedEvent]
    public var durationNS: UInt64 { events.last?.timeNS ?? 0 }
    public var sessionDurationNS: UInt64? {
        guard let start = header.captureStartedNS, let end = header.captureEndedNS, end >= start else { return nil }
        return end - start
    }
    public var leadingIdleNS: UInt64 {
        guard let start = header.captureStartedNS, let origin = header.timestampOriginNS, origin >= start else { return 0 }
        return origin - start
    }
    public var replayDurationNS: UInt64 { sessionDurationNS ?? durationNS }

    public init(header: RecordingHeader, events: [RecordedEvent]) {
        self.header = header
        self.events = events
    }

    public func validate() throws {
        guard (1...3).contains(header.formatVersion) else {
            throw MouseRecorderError("Unsupported recording format version \(header.formatVersion).")
        }
        if header.captureStartedNS != nil || header.captureEndedNS != nil {
            guard let start = header.captureStartedNS, let end = header.captureEndedNS, end >= start else {
                throw MouseRecorderError("Capture start/end times must both be present and ordered.")
            }
            if !events.isEmpty {
                guard let origin = header.timestampOriginNS, origin >= start else {
                    throw MouseRecorderError("The first event precedes the capture start, or its origin is missing.")
                }
                let last = origin.addingReportingOverflow(durationNS)
                guard !last.overflow, last.partialValue <= end else {
                    throw MouseRecorderError("The last event exceeds the capture end.")
                }
            }
        }
        var previous: UInt64 = 0
        for (index, event) in events.enumerated() {
            guard event.timeNS >= previous, index != 0 || event.timeNS == 0 else {
                throw MouseRecorderError("Event \(index) has a non-monotonic timestamp or the first time is not zero.")
            }
            guard event.location.x.isFinite, event.location.y.isFinite, event.pressure.isFinite,
                  (0...31).contains(event.button), !event.nativeData.isEmpty else {
                throw MouseRecorderError("Event \(index) has invalid coordinates, pressure, button, or native data.")
            }
            if event.type == .scrollWheel {
                guard let scroll = event.scroll,
                      scroll.pointDelta.count == 3, scroll.fixedDeltaRaw.count == 3, scroll.lineDelta.count == 3 else {
                    throw MouseRecorderError("Scroll event \(index) must contain three axes of all delta representations.")
                }
                for raw in scroll.auxiliaryIntegerFields.keys {
                    guard let value = UInt32(raw), [14, 173, 175, 176, 177, 178].contains(value),
                          CGEventField(rawValue: value) != nil else {
                        throw MouseRecorderError("Scroll event \(index) has an unsupported auxiliary field \(raw).")
                    }
                }
                for (raw, delta) in scroll.auxiliaryDoubleFields {
                    guard let value = UInt32(raw), [175, 176, 177, 178].contains(value), delta.isFinite else {
                        throw MouseRecorderError("Scroll event \(index) has an invalid auxiliary floating-point delta.")
                    }
                }
            } else if event.scroll != nil {
                throw MouseRecorderError("Non-scroll event \(index) contains unexpected scroll fields.")
            }
            let requiredButton: Int64?
            switch event.type {
            case .leftMouseDown, .leftMouseUp, .leftMouseDragged: requiredButton = 0
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged: requiredButton = 1
            default: requiredButton = nil
            }
            if let requiredButton, event.button != requiredButton {
                throw MouseRecorderError("Event \(index) has a button number inconsistent with \(event.type.rawValue).")
            }
            previous = event.timeNS
        }
    }

    public static func load(from path: String) throws -> Recording {
        var recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try recording.validate()
        if recording.header.formatVersion == 1, !recording.events.isEmpty {
            let clock = MachClock()
            guard let date = ISO8601DateFormatter().date(from: recording.header.recordedAt) else {
                throw MouseRecorderError("Legacy recording has no valid recording date. Re-record with this version.")
            }
            let age = Date().timeIntervalSince(date)
            guard age >= 0, age < Double(clock.nowNS) / 1_000_000_000 else {
                throw MouseRecorderError("Cannot establish this legacy recording's clock epoch. Original file unchanged; re-record with this version.")
            }
            let reference = clock.nowNS - UInt64(age * 1_000_000_000)
            recording = try recording.normalizingLegacyTimestamps(near: reference, clock: clock)
        }
        return recording
    }

    func normalizingLegacyTimestamps(near referenceNS: UInt64, clock: MachClock) throws -> Recording {
        guard let rawOrigin = header.timestampOriginNS else {
            throw MouseRecorderError("Legacy recording has no timestamp origin. Re-record with this version.")
        }
        let first = clock.eventTimestamp(rawOrigin, near: referenceNS)
        let distance = first.ns >= referenceNS ? first.ns - referenceNS : referenceNS - first.ns
        guard distance < 300_000_000_000 else {
            throw MouseRecorderError("Legacy timestamp units are ambiguous, possibly due to sleep, reboot, or a different Mac. Original file unchanged; re-record with this version.")
        }
        var result = self
        for index in events.indices {
            let raw = rawOrigin.addingReportingOverflow(events[index].timeNS)
            guard !raw.overflow else { throw MouseRecorderError("Legacy timestamp overflow at event \(index).") }
            let normalized = clock.eventTimestamp(raw.partialValue, near: first.ns)
            guard normalized.ns >= first.ns else { throw MouseRecorderError("Legacy event \(index) precedes the normalized origin.") }
            result.events[index].timeNS = normalized.ns - first.ns
            result.events[index].rawTimestamp = raw.partialValue
            result.events[index].timestampUnit = normalized.unit
        }
        result.header.formatVersion = 2
        result.header.timestampOriginNS = first.ns
        result.header.timebaseNumerator = clock.numerator
        result.header.timebaseDenominator = clock.denominator
        result.header.timestampNormalization = "Legacy v1 timing normalized in memory using clock epoch and timebase \(clock.numerator)/\(clock.denominator). Original file unchanged."
        try result.validate()
        return result
    }

    public func save(to path: String) throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public var captureWarnings: [String] {
        var warnings: [String] = []
        if header.tapInterruptions > 0 {
            warnings.append("The event tap was disabled \(header.tapInterruptions) time(s); events may be missing.")
        }
        if let error = header.captureError { warnings.append("Capture ended with an error: \(error)") }
        var held = Set<Int64>()
        var incomplete = false
        for event in events where event.type != .scrollWheel {
            if event.type.isDown { held.insert(event.button) }
            if (event.type.isUp || event.type.isDrag) && !held.contains(event.button) { incomplete = true }
            if event.type.isUp { held.remove(event.button) }
        }
        if incomplete { warnings.append("The recording contains a release or drag without its preceding button-down.") }
        if !held.isEmpty { warnings.append("The recording ends with held buttons; playback will append safety releases.") }
        var input = HeldInput()
        for event in events { input.observe(event) }
        if input.scrollActive || input.momentumActive {
            warnings.append("The recording ends during scrolling or momentum; playback will append zero-delta phase ends.")
        }
        return warnings
    }
}
