import CoreGraphics
import Foundation
import Synchronization

public struct ObservedEvent: Sendable {
    public var event: RecordedEvent
    public var timestampNS: UInt64
    public var arrivalNS: UInt64
    public var tag: Int64
}

public struct Capture: Sendable {
    public var recording: Recording
    public var observations: [ObservedEvent]
    public var ignoredEvents: Int
    public var ignoredTagSamples: [Int64] = []
}

public final class Recorder: Sendable {
    private struct State {
        var started = false
        var stop = false
        var readyError: String?
        var captureError: String?
        var origin: UInt64?
        var captureStartedNS: UInt64?
        var captureEndedNS: UInt64?
        var observations: [ObservedEvent] = []
        var tapInterruptions = 0
        var reenable = false
        var ignoredEvents = 0
        var ignoredTagSamples: [Int64] = []
    }

    private let state = Mutex(State())
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchGroup()
    private let cancellation: Cancellation
    private let tagRange: ClosedRange<Int64>?
    private let captureInput: Bool
    private let clock = MachClock()

    public init(cancellation: Cancellation, tagRange: ClosedRange<Int64>? = nil, captureInput: Bool = true) {
        self.cancellation = cancellation
        self.tagRange = tagRange
        self.captureInput = captureInput
    }

    public func start() throws {
        let fresh = state.withLock { state in
            guard !state.started else { return false }
            state.started = true
            return true
        }
        guard fresh else { throw MouseRecorderError("An event recorder cannot be started twice.") }
        finished.enter()
        let thread = Thread { [self] in run() }
        thread.name = "cursor-replay.event-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        if let error = state.withLock({ $0.readyError }) {
            finished.wait()
            throw MouseRecorderError(error)
        }
    }

    public func stop(header: RecordingHeader) -> Capture {
        let stopTime = clock.nowNS
        state.withLock {
            if !$0.stop { $0.captureEndedNS = stopTime }
            $0.stop = true
        }
        finished.wait()
        return state.withLock { state in
            var header = header
            header.timestampOriginNS = state.origin
            header.tapInterruptions = state.tapInterruptions
            header.captureError = state.captureError
            header.stopReason = state.captureError ?? cancellation.reason ?? "completed"
            if let start = state.captureStartedNS {
                header.captureStartedNS = min(start, state.origin ?? start)
                header.captureEndedNS = max(state.captureEndedNS ?? stopTime, state.observations.last?.timestampNS ?? 0)
            }
            return Capture(
                recording: Recording(header: header, events: state.observations.map(\.event)),
                observations: state.observations, ignoredEvents: state.ignoredEvents,
                ignoredTagSamples: state.ignoredTagSamples
            )
        }
    }

    public var hasFailed: Bool { state.withLock { $0.captureError != nil } }
    public var eventCount: Int { state.withLock { $0.observations.count } }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            state.withLock { $0.tapInterruptions += 1; $0.reenable = true }
            return
        }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { cancellation.cancel("Escape") }
            return
        }
        guard captureInput, EventKind(type) != nil else { return }
        let tag = event.getIntegerValueField(.eventSourceUserData)
        if let tagRange, !tagRange.contains(tag) {
            state.withLock { state in
                state.ignoredEvents += 1
                if state.ignoredTagSamples.count < 8, !state.ignoredTagSamples.contains(tag) {
                    state.ignoredTagSamples.append(tag)
                }
            }
            return
        }
        let arrival = clock.nowNS
        // Physical HID events on this system carry mach ticks; posted events carry ns.
        // The current epoch chooses units only; event time is never replaced by callback time.
        let timestamp = clock.eventTimestamp(event.timestamp, near: arrival)
        state.withLock { state in
            guard !state.stop, state.captureError == nil else { return }
            let origin = state.origin ?? timestamp.ns
            do {
                let sample = try RecordedEvent(
                    event: event, relativeTo: origin,
                    normalizedTimestampNS: timestamp.ns, timestampUnit: timestamp.unit
                )
                if let previous = state.observations.last, previous.event.timeNS > sample.timeNS {
                    throw MouseRecorderError("Non-monotonic event timestamps detected; capture stopped without reordering.")
                }
                state.origin = origin
                state.observations.append(ObservedEvent(
                    event: sample, timestampNS: timestamp.ns, arrivalNS: arrival, tag: tag
                ))
            } catch {
                state.captureError = error.localizedDescription
            }
        }
    }

    private func run() {
        defer { finished.leave() }
        var mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        if captureInput {
            for kind in EventKind.allCases { mask |= CGEventMask(1) << kind.cgType.rawValue }
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                if let context {
                    let recorder = Unmanaged<Recorder>.fromOpaque(context).takeUnretainedValue()
                    autoreleasepool { recorder.receive(type: type, event: event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            state.withLock { $0.readyError = "Could not create the listen-only HID event tap. Run cursor-replay doctor." }
            ready.signal()
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            state.withLock { $0.readyError = "Could not create the event tap run loop source." }
            ready.signal()
            return
        }
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes)
        state.withLock { $0.captureStartedNS = clock.nowNS }
        CGEvent.tapEnable(tap: tap, enable: true)
        ready.signal()
        defer {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFMachPortInvalidate(tap)
        }
        while !state.withLock({ $0.stop || $0.captureError != nil }) {
            CFRunLoopRunInMode(.defaultMode, 0.01, true)
            let reenable = state.withLock { state in
                let requested = state.reenable
                state.reenable = false
                return requested
            }
            if reenable { CGEvent.tapEnable(tap: tap, enable: true) }
        }
    }
}
