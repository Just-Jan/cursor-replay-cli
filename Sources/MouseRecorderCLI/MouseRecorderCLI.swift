import CoreGraphics
import Darwin
import Foundation
import MouseRecorderCore

private let usage = """
\(AppIdentity.displayName): record a moment, replay it.

Usage:
  cursor-replay                         # interactive terminal app
  cursor-replay menu
  cursor-replay record [-o file.json] [--countdown 3] [--duration seconds] [--overwrite]
  cursor-replay play [file.json] [--countdown 3] [--speed 1.0] [--loop N]
  cursor-replay info [file.json]
  cursor-replay verify [file.json] [--countdown 3] [--overwrite]
  cursor-replay doctor
  cursor-replay --help
  cursor-replay --version

Default file: recording.json. Default speed: exactly 1.0.
Menu: S stops and saves; Escape is an alternative. Both return to the menu.
Menu: Q or Ctrl+C saves any active recording and exits.
Menu recordings: ~/Library/Application Support/Cursor Replay CLI/recordings
Override the private data folder with CURSOR_REPLAY_DATA_DIR.
Direct commands: Ctrl+C or Escape stops recording/playback.
Escape is observed, not suppressed, so the target app also receives it.
Verify posts real input into the current target app. Do not touch the mouse
during verification. Observations are saved as <name>.verification.json.
No app is launched, selected, or focused by cursor-replay.
"""

enum Command: String {
    case menu, record, play, info, verify, doctor
}

struct Arguments {
    var command: Command
    var path = "recording.json"
    var countdown = 3
    var speed = 1.0
    var loops = 1
    var duration: Double?
    var overwrite = false

    init(_ arguments: [String]) throws {
        guard let first = arguments.first, let command = Command(rawValue: first) else {
            throw MouseRecorderError("Expected menu, record, play, info, verify, or doctor. Use --help for usage.")
        }
        self.command = command
        var index = 1
        var hasPath = false
        var seen = Set<String>()
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("-") {
                let key = argument == "--output" ? "-o" : argument
                guard seen.insert(key).inserted else { throw MouseRecorderError("Duplicate option \(argument).") }
                if key == "--overwrite", command == .record || command == .verify {
                    overwrite = true
                    index += 1
                    continue
                }
                let allowed: Bool
                switch key {
                case "-o", "--duration": allowed = command == .record
                case "--countdown": allowed = [.record, .play, .verify].contains(command)
                case "--speed", "--loop": allowed = command == .play
                default: allowed = false
                }
                guard allowed else { throw MouseRecorderError("Unknown option \(argument) for \(command.rawValue).") }
                guard index + 1 < arguments.count else { throw MouseRecorderError("Missing value for \(argument).") }
                let value = arguments[index + 1]
                switch key {
                case "-o":
                    guard !value.isEmpty else { throw MouseRecorderError("Output path must not be empty.") }
                    path = value
                case "--countdown":
                    guard let number = Int(value), number >= 0 else {
                        throw MouseRecorderError("Countdown must be a nonnegative integer.")
                    }
                    countdown = number
                case "--speed":
                    guard let number = Double(value), number.isFinite, number > 0 else {
                        throw MouseRecorderError("Speed must be finite and greater than zero.")
                    }
                    speed = number
                case "--loop":
                    guard let number = Int(value), number > 0 else {
                        throw MouseRecorderError("Loop count must be a positive integer.")
                    }
                    loops = number
                case "--duration":
                    guard let number = Double(value), number.isFinite, number > 0 else {
                        throw MouseRecorderError("Duration must be finite and greater than zero.")
                    }
                    duration = number
                default: break
                }
                index += 2
            } else {
                guard [.play, .info, .verify].contains(command), !hasPath, !argument.isEmpty else {
                    throw MouseRecorderError("Unexpected argument \(argument).")
                }
                path = argument
                hasPath = true
                index += 1
            }
        }
    }
}

private final class SignalMonitor {
    private let interrupt: any DispatchSourceSignal
    private let terminate: any DispatchSourceSignal

    init(cancellation: Cancellation) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInteractive))
        terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInteractive))
        interrupt.setEventHandler { cancellation.cancel("Ctrl+C") }
        terminate.setEventHandler { cancellation.cancel("SIGTERM") }
        interrupt.resume()
        terminate.resume()
    }

    deinit {
        interrupt.cancel()
        terminate.cancel()
    }
}

@main
struct MouseRecorderCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--version"] {
            print("\(AppIdentity.command) \(AppIdentity.version)")
            return
        }
        if args == ["--help"] || args == ["-h"] || args.last == "--help" {
            print(usage)
            return
        }
        do {
            let arguments = try Arguments(args.isEmpty ? ["menu"] : args)
            let cancellation = Cancellation()
            let signals = SignalMonitor(cancellation: cancellation)
            let status = try withExtendedLifetime(signals) {
                try run(arguments, cancellation: cancellation)
            }
            if status != 0 { exit(status) }
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(
        _ args: Arguments, cancellation: Cancellation, screen: TerminalScreen? = nil
    ) throws -> Int32 {
        switch args.command {
        case .menu:
            return try terminalMenu(cancellation: cancellation)
        case .doctor:
            return try doctor()
        case .info:
            try info(Recording.load(from: args.path))
            return 0
        case .record:
            try Permissions.require()
            try checkOutput(args.path, overwrite: args.overwrite)
            try record(args, cancellation: cancellation, screen: screen)
            return 0
        case .play, .verify:
            try Permissions.require()
            let recording = try Recording.load(from: args.path)
            guard !recording.events.isEmpty else { throw MouseRecorderError("The recording contains no events.") }
            var notices: [String] = []
            if let note = recording.header.timestampNormalization {
                if screen == nil { warn(note) }
                else { notices.append("Older take: timing normalized in memory.") }
            }
            if try DisplayFrame.current() != recording.header.displays {
                notices.append("Display layout changed. Recorded coordinates will not be remapped.")
            }
            if recording.header.macOSVersion != ProcessInfo.processInfo.operatingSystemVersionString {
                notices.append("Different macOS version; native event compatibility is unverified.")
            }
            notices.append(contentsOf: recording.captureWarnings)
            if recording.sessionDurationNS == nil {
                notices.append("Older take: surrounding idle time was not saved.")
            }
            if screen == nil { for notice in notices { warn(notice) } }
            if args.command == .verify {
                return try verify(recording, args: args, cancellation: cancellation)
            }
            let message = notices.isEmpty ? "Switch to your app. Replay starts soon." : notices.joined(separator: " ")
            guard try prepare(args.countdown, cancellation: cancellation, screen: screen, message: message) else {
                if let screen {
                    screen.update(TerminalViewState(phase: .ready, message: "No rush. Replay cancelled.",
                                                   lastRecording: URL(fileURLWithPath: args.path).lastPathComponent))
                } else {
                    print("Replay cancelled before it started. No input replayed.")
                }
                return 130
            }
            let monitor = Recorder(cancellation: cancellation, captureInput: false)
            try monitor.start()
            let header = RecordingHeader(displays: [])
            defer { _ = monitor.stop(header: header) }
            if let screen {
                screen.update(TerminalViewState(
                    phase: .playing, message: notices.isEmpty ? "Sit back. Replaying your take." : notices.joined(separator: " "),
                    lastRecording: URL(fileURLWithPath: args.path).lastPathComponent,
                    startedAt: ProcessInfo.processInfo.systemUptime,
                    duration: Double(recording.replayDurationNS) / 1_000_000_000 / args.speed * Double(args.loops),
                    eventCount: recording.events.count
                ))
            } else {
                print("Playing \(recording.events.count) events at speed \(args.speed), \(args.loops) loop(s).")
                print("Stop playback with Ctrl+C or Escape.")
                fflush(nil)
            }
            let report = try Playback.run(
                recording, options: PlaybackOptions(speed: args.speed, loops: args.loops), cancellation: cancellation
            )
            if let screen {
                screen.update(TerminalViewState(
                    phase: .ready,
                    message: report.stopReason == nil ? "Replay finished. Ready for another?" : "Replay stopped. You're in control.",
                    lastRecording: URL(fileURLWithPath: args.path).lastPathComponent
                ))
            } else {
                printPlayback(report)
                print(report.stopReason == nil ? "Replay is done." : "Replay stopped.")
            }
            return cancellation.isCancelled ? 130 : 0
        }
    }

    private static func prepare(
        _ seconds: Int, cancellation: Cancellation, screen: TerminalScreen? = nil,
        message: String = "Switch to your app. Recording starts soon."
    ) throws -> Bool {
        let monitor = Recorder(cancellation: cancellation, captureInput: false)
        try monitor.start()
        defer { _ = monitor.stop(header: RecordingHeader(displays: [])) }
        if let screen {
            countdown(seconds, cancellation: cancellation) { remaining in
                screen.update(TerminalViewState(phase: .countdown, message: message, countdown: remaining))
            }
        } else {
            print("Switch to your target app now. No target app will be selected automatically.")
            countdown(seconds, cancellation: cancellation)
        }
        return !cancellation.isCancelled
    }

    private static func record(
        _ args: Arguments, cancellation: Cancellation, screen: TerminalScreen?
    ) throws {
        guard try prepare(args.countdown, cancellation: cancellation, screen: screen) else {
            if let screen {
                screen.update(TerminalViewState(phase: .ready, message: "No rush. Recording cancelled."))
            } else {
                print("Cancelled before recording. No file written.")
            }
            return
        }
        let header = try RecordingHeader(displays: DisplayFrame.current())
        let recorder = Recorder(cancellation: cancellation)
        try recorder.start()
        let start = ProcessInfo.processInfo.systemUptime
        if screen == nil {
            print("Recording all mouse events. Stop with Ctrl+C or Escape.")
            fflush(nil)
        }
        var lastUpdate = -Double.infinity
        while !cancellation.isCancelled, !recorder.hasFailed {
            let now = ProcessInfo.processInfo.systemUptime
            if let screen, now - lastUpdate >= 0.125 {
                screen.update(TerminalViewState(
                    phase: .recording, message: "Recording. Make it a good one.",
                    startedAt: start, eventCount: recorder.eventCount
                ))
                lastUpdate = now
            }
            if let duration = args.duration, now - start >= duration {
                cancellation.cancel("duration elapsed")
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let capture = recorder.stop(header: header)
        if let screen {
            screen.update(TerminalViewState(phase: .saving, message: "Wrapping up your take..."))
        } else {
            print("\nRecording stopped. Saving...")
            fflush(nil)
        }
        try capture.recording.save(to: args.path)
        let partial = capture.recording.header.captureError != nil || capture.recording.header.tapInterruptions > 0
        if screen == nil {
            print(partial ? "Recording stopped. File saved with capture errors: \(args.path)" : "Recording stopped and saved: \(args.path)")
            print(String(format: "Saved %d events. Full session: %.3f s; first-to-last event: %.3f s.",
                         capture.recording.events.count, Double(capture.recording.replayDurationNS) / 1_000_000_000,
                         Double(capture.recording.durationNS) / 1_000_000_000))
            for warning in capture.recording.captureWarnings { warn(warning) }
        }
        if let error = capture.recording.header.captureError {
            throw MouseRecorderError("Partial recording saved. \(error)")
        }
        if capture.recording.header.tapInterruptions > 0 {
            throw MouseRecorderError("Recording saved, but tap interruptions mean lossless capture cannot be claimed.")
        }
        if let screen {
            let notes = capture.recording.captureWarnings
            let message: String
            if capture.recording.events.isEmpty {
                message = "No mouse input this time. Press R to try again."
            } else if !notes.isEmpty {
                message = "Saved with a note: \(notes.joined(separator: " "))"
            } else {
                message = "All good. Your recording is saved."
            }
            screen.update(TerminalViewState(
                phase: .ready, message: message,
                lastRecording: URL(fileURLWithPath: args.path).lastPathComponent
            ))
        } else if capture.recording.events.isEmpty {
            warn("No mouse input was captured. This file cannot be replayed.")
        }
    }

    private static func verify(
        _ recording: Recording, args: Arguments, cancellation: Cancellation
    ) throws -> Int32 {
        let output = URL(fileURLWithPath: args.path).deletingPathExtension().path + ".verification.json"
        try checkOutput(output, overwrite: args.overwrite)
        print("Verification will replay REAL input into the current app. Keep physical input idle after the countdown.")
        guard try prepare(args.countdown, cancellation: cancellation) else { return 130 }
        let base = Int64.random(in: 0x1000_0000_0000...0x6FFF_FFFF_FFFF)
        let end = base.addingReportingOverflow(Int64(recording.events.count - 1))
        guard !end.overflow else { throw MouseRecorderError("Too many events for verification tags.") }
        let recorder = Recorder(cancellation: cancellation, tagRange: base...end.partialValue)
        let header = try RecordingHeader(displays: DisplayFrame.current())
        try recorder.start()
        let report: PlaybackReport
        do {
            report = try Playback.run(recording, options: PlaybackOptions(tagBase: base), cancellation: cancellation)
        } catch {
            let partial = recorder.stop(header: header)
            try partial.recording.save(to: output)
            throw MouseRecorderError("Partial observations saved to \(output). \(error.localizedDescription)")
        }
        let drainEnd = ProcessInfo.processInfo.systemUptime + 0.5
        while ProcessInfo.processInfo.systemUptime < drainEnd, !recorder.hasFailed {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let capture = recorder.stop(header: header)
        try capture.recording.save(to: output)
        let comparison = VerificationReport.compare(original: recording, capture: capture, playback: report, tagBase: base)
        printPlayback(report)
        print("Observed recording: \(output)")
        print("Event counts: expected \(comparison.expectedCount), observed \(comparison.observedCount), matched \(comparison.matchedCount)")
        print("Missing: \(comparison.missingIndices.count); duplicate tags: \(comparison.duplicateTags); reordered: \(comparison.reorderedEvents)")
        print("Position error: \(comparison.position.text(unit: "global-coordinate px"))")
        print("Event timestamp error: \(comparison.timestampTiming.text(unit: "ms"))")
        print("HID callback arrival error: \(comparison.arrivalTiming.text(unit: "ms"))")
        print("Payload mismatches (flags, buttons, click state, pressure, deltas, scroll phases): \(comparison.payloadMismatches)")
        print("Modifier-key mismatches: \(comparison.modifierMismatches); raw flag mismatches: \(comparison.rawFlagMismatches)")
        if comparison.rawFlagMismatches > 0 {
            print("Observed flag bits added: 0x\(String(comparison.addedFlagBits, radix: 16)); removed: 0x\(String(comparison.removedFlagBits, radix: 16))")
            print("Raw flag differences remain a strict-check failure even when public modifier keys match.")
        }
        print("Scroll delta sums match: \(comparison.scrollSumsMatch ? "YES" : "NO")")
        for key in comparison.expectedScrollSums.keys.sorted() {
            print("  \(key): expected \(comparison.expectedScrollSums[key] ?? 0), observed \(comparison.observedScrollSums[key] ?? 0)")
        }
        print("Unrelated input events excluded by tag: \(comparison.ignoredPhysicalEvents)")
        if comparison.observedCount != comparison.expectedCount {
            print("Expected tag range: \(base)...\(end.partialValue); excluded tag samples: \(capture.ignoredTagSamples)")
        }
        print("Tap interruptions: \(comparison.captureInterruptions)")
        for example in comparison.mismatchExamples { print("  \(example)") }
        if let error = comparison.captureError { warn("Verification capture error: \(error)") }
        let passed = comparison.passed && recording.captureWarnings.isEmpty && report.cleanupEvents == 0 && !cancellation.isCancelled
        if !passed {
            warn("Fidelity check FAILED or was inconclusive. Do not claim 1:1 replay.")
            if comparison.position.maximum > 0 { warn("At least one observed position differs from the original.") }
            if comparison.arrivalTiming.maximum > 2 || comparison.timestampTiming.maximum > 2 || comparison.postingTiming.maximum > 2 {
                warn("The maximum measured timing error exceeds 2 ms. Inspect posting vs callback errors, physical input, system load, and event coalescing.")
            }
        } else {
            print("Fidelity check PASSED at the HID event tap: exact positions/payloads/counts and maximum timing error <= 2 ms.")
        }
        print("This measures the HID event stream, not the target app's rendering or scroll response. Real app behavior remains unverified.")
        return cancellation.isCancelled ? 130 : passed ? 0 : 2
    }

    private static func doctor() throws -> Int32 {
        let permissions = Permissions()
        print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Permission owner: \(Permissions.terminal)")
        print("Executable: \(CommandLine.arguments[0])")
        print("Accessibility: \(permissions.accessibility ? "granted" : "MISSING")")
        print("Input Monitoring: \(permissions.listening ? "granted" : "MISSING")")
        print("Post Event Access: \(permissions.posting ? "granted" : "MISSING")")
        for display in try DisplayFrame.current() {
            printDisplay(display)
        }
        if !permissions.missing.isEmpty {
            print("Missing permissions: \(permissions.missing.joined(separator: ", ")).")
            print("Grant these to \(Permissions.terminal) in System Settings > Privacy & Security.")
            print("If the executable is listed separately, enable it too. Fully quit and reopen the terminal if needed.")
            return 1
        }
        print("No permissions missing. Posting and target-app response are not tested by doctor.")
        return 0
    }

    private static func info(_ recording: Recording) throws {
        print("Format version: \(recording.header.formatVersion)")
        print("Recorded: \(recording.header.recordedAt)")
        print("macOS: \(recording.header.macOSVersion)")
        print("Coordinates: \(recording.header.coordinateSpace)")
        print("Events: \(recording.events.count)")
        print(String(format: "Duration (first to last event): %.9f s", Double(recording.durationNS) / 1_000_000_000))
        if let sessionDuration = recording.sessionDurationNS {
            print(String(format: "Full session duration: %.9f s (leading idle %.9f s; trailing idle %.9f s)",
                         Double(sessionDuration) / 1_000_000_000, Double(recording.leadingIdleNS) / 1_000_000_000,
                         Double(sessionDuration - recording.leadingIdleNS - recording.durationNS) / 1_000_000_000))
        } else {
            print("Full session duration: unavailable; this file contains first-to-last event timing only.")
        }
        print("Stop reason: \(recording.header.stopReason)")
        if let note = recording.header.timestampNormalization { print("Timing: \(note)") }
        print("Tap interruptions: \(recording.header.tapInterruptions)")
        for type in EventKind.allCases {
            print("  \(type.rawValue): \(recording.events.lazy.filter { $0.type == type }.count)")
        }
        for display in recording.header.displays { printDisplay(display) }
        sampling("All events", events: recording.events)
        sampling("Movement/drag events", events: recording.events.filter { $0.type == .mouseMoved || $0.type.isDrag })
        for warning in recording.captureWarnings { warn(warning) }
    }

    private static func sampling(_ label: String, events: [RecordedEvent]) {
        let intervals = zip(events, events.dropFirst()).map { Double($1.timeNS - $0.timeNS) / 1_000_000 }
        print("\(label) interval stats: \(Statistics(intervals).text(unit: "ms"))")
        if let first = events.first, let last = events.last, last.timeNS > first.timeNS {
            print(String(format: "  Mean observed rate: %.3f Hz, %d events (no decimation)", Double(events.count - 1) * 1_000_000_000 / Double(last.timeNS - first.timeNS), events.count))
        }
    }

    private static func printDisplay(_ display: DisplayFrame) {
        print("Display \(display.id): origin (\(display.x), \(display.y)), \(display.width)x\(display.height) global units, scale \(display.scaleFactor), mode backing pixels \(display.pixelWidth)x\(display.pixelHeight)")
    }

    private static func printPlayback(_ report: PlaybackReport) {
        printReplayDuration(report)
        print("Submitted \(report.postedEvents) recorded events; completed loops \(report.completedLoops); appended safety events \(report.cleanupEvents).")
        let errors = report.samples.map {
            Double($0.postedNS >= $0.targetNS ? $0.postedNS - $0.targetNS : $0.targetNS - $0.postedNS) / 1_000_000
        }
        print("Submission deadline error: \(Statistics(errors).text(unit: "ms"))")
        let callDurations = report.samples.compactMap { sample -> Double? in
            guard let returned = sample.returnedNS else { return nil }
            return Double(returned - sample.postedNS) / 1_000_000
        }
        print("CGEvent.post call duration: \(Statistics(callDurations).text(unit: "ms"))")
        if let first = callDurations.first {
            print(String(format: "First CGEvent.post call: %.6f ms; subsequent calls: %@", first, Statistics(Array(callDurations.dropFirst())).text(unit: "ms")))
        }
        if let reason = report.stopReason { print("Stopped: \(reason).") }
    }

    private static func printReplayDuration(_ report: PlaybackReport) {
        if let elapsed = report.elapsedNS {
            print(String(format: "Replay duration: planned %.6f s; elapsed %.6f s.",
                         Double(report.plannedDurationNS) / 1_000_000_000, Double(elapsed) / 1_000_000_000))
        }
    }

    private static func checkOutput(_ path: String, overwrite: Bool) throws {
        if FileManager.default.fileExists(atPath: path), !overwrite {
            throw MouseRecorderError("File already exists: \(path). Choose a different path or use --overwrite.")
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            throw MouseRecorderError("Output directory is not writable: \(parent).")
        }
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("WARNING: \(message)\n".utf8))
    }
}
