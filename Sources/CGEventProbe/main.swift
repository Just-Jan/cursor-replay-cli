import ApplicationServices
import CoreGraphics
import Foundation
import Synchronization

final class Observation: Sendable {
    let event = Mutex<CGPoint?>(nil)
}

let probeTag: Int64 = 0x4D5250524F4245

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

let terminal = ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "the terminal running this executable"
print("Compiled CoreGraphics single-event probe")
print("Terminal: \(terminal)")
print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "missing")")
print("Input Monitoring: \(CGPreflightListenEventAccess() ? "granted" : "missing")")
print("Post Event Access: \(CGPreflightPostEventAccess() ? "granted" : "missing")")

if !CGPreflightListenEventAccess() {
    _ = CGRequestListenEventAccess()
}
if !CGPreflightPostEventAccess() {
    _ = CGRequestPostEventAccess()
}
guard AXIsProcessTrusted(), CGPreflightListenEventAccess(), CGPreflightPostEventAccess() else {
    fail("""
    Permission check failed. In System Settings > Privacy & Security, grant \
    Accessibility and Input Monitoring to \(terminal). macOS may instead list \
    this compiled executable; enable it if shown. Restart the terminal if needed, \
    then rerun this same executable. No event was posted.
    """)
}

guard let source = CGEventSource(stateID: .hidSystemState),
      let cursor = CGEvent(source: source) else {
    fail("CoreGraphics could not create the HID event source or cursor query event.")
}
let point = cursor.location
guard let move = CGEvent(
    mouseEventSource: source,
    mouseType: .mouseMoved,
    mouseCursorPosition: point,
    mouseButton: .left
) else {
    fail("CoreGraphics could not create the single mouse-move event.")
}
move.setIntegerValueField(.eventSourceUserData, value: probeTag)
let observation = Observation()
let context = Unmanaged.passUnretained(observation).toOpaque()
guard let tap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .tailAppendEventTap,
    options: .listenOnly,
    eventsOfInterest: CGEventMask(1) << CGEventType.mouseMoved.rawValue,
    callback: { _, _, event, context in
        if event.getIntegerValueField(.eventSourceUserData) == 0x4D5250524F4245,
           let context {
            let observation = Unmanaged<Observation>.fromOpaque(context).takeUnretainedValue()
            observation.event.withLock { $0 = event.location }
        }
        return Unmanaged.passUnretained(event)
    },
    userInfo: context
), let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
    fail("Could not create the listen-only event tap for observing the posted event.")
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("Posting exactly one mouseMoved event at the current cursor location (\(point.x), \(point.y)).")
fflush(nil)
move.post(tap: .cghidEventTap)
let deadline = ProcessInfo.processInfo.systemUptime + 2
while observation.event.withLock({ $0 == nil }), ProcessInfo.processInfo.systemUptime < deadline {
    CFRunLoopRunInMode(.defaultMode, 0.02, true)
}
CGEvent.tapEnable(tap: tap, enable: false)
CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
CFMachPortInvalidate(tap)
guard let received = observation.event.withLock({ $0 }) else {
    fail("The event post returned, but the listen-only HID tap did not observe it. Posting is unverified.")
}
guard received == point else {
    fail("The observed event position \(received) differs from the requested position \(point).")
}
print("REAL RUN: one tagged mouseMoved event posted and observed at the HID tap, exact position match.")
print("This does not verify visible app response, continuous movement, clicks, drags, or scrolling.")
