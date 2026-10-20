import Darwin
import Foundation
import MouseRecorderCore
import Synchronization

private final class TerminalInput: Sendable {
    private let original: termios

    init() throws {
        guard isatty(STDIN_FILENO) == 1 else {
            throw MouseRecorderError("The interactive app needs a terminal. Use cursor-replay --help for non-interactive commands.")
        }
        var attributes = termios()
        guard tcgetattr(STDIN_FILENO, &attributes) == 0 else {
            throw MouseRecorderError("Could not read terminal settings (errno \(errno)).")
        }
        original = attributes
        attributes.c_lflag &= ~tcflag_t(ICANON | ECHO)
        withUnsafeMutableBytes(of: &attributes.c_cc) { bytes in
            bytes[Int(VMIN)] = 1
            bytes[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSANOW, &attributes) == 0 else {
            throw MouseRecorderError("Could not enable single-key terminal input (errno \(errno)).")
        }
    }

    func restore() {
        var attributes = original
        if tcsetattr(STDIN_FILENO, TCSANOW, &attributes) != 0 {
            FileHandle.standardError.write(Data("ERROR: Could not restore terminal settings (errno \(errno)).\n".utf8))
        }
    }

    func readKey(timeoutMS: Int32) throws -> UInt8? {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, timeoutMS)
        if result == 0 || (result < 0 && errno == EINTR) { return nil }
        guard result > 0 else {
            throw MouseRecorderError("Terminal input polling failed (errno \(errno)).")
        }
        guard descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
            throw MouseRecorderError("The terminal input connection closed.")
        }
        var byte: UInt8 = 0
        let count = read(STDIN_FILENO, &byte, 1)
        if count < 0 && errno == EINTR { return nil }
        guard count == 1 else {
            throw MouseRecorderError("Could not read a terminal key (errno \(errno)).")
        }
        return byte
    }
}

private final class ActionControls: Sendable {
    private struct State {
        var stopped = false
        var error: String?
    }
    private let state = Mutex(State())
    private let finished = DispatchGroup()
    private let input: TerminalInput
    private let action: Cancellation
    private let session: Cancellation
    private let isRecording: Bool
    private let screen: TerminalScreen

    init(input: TerminalInput, action: Cancellation, session: Cancellation, isRecording: Bool, screen: TerminalScreen) {
        self.input = input
        self.action = action
        self.session = session
        self.isRecording = isRecording
        self.screen = screen
        finished.enter()
        let thread = Thread { [self] in
            defer { finished.leave() }
            while !state.withLock({ $0.stopped }) {
                if let error = screen.error {
                    state.withLock { $0.error = error }
                    session.cancel("Terminal display error")
                    action.cancel("Terminal display error")
                    return
                }
                if session.isCancelled {
                    action.cancel(session.reason ?? "Exit")
                    return
                }
                do {
                    guard let key = try input.readKey(timeoutMS: 20) else { continue }
                    switch key {
                    case 115, 83:
                        action.cancel(isRecording ? "Stop and save" : "Stop playback")
                    case 113, 81:
                        session.cancel("Exit")
                        action.cancel("Exit")
                    default:
                        break
                    }
                } catch {
                    state.withLock { $0.error = error.localizedDescription }
                    session.cancel("Terminal input error")
                    action.cancel("Terminal input error")
                    return
                }
            }
        }
        thread.name = "cursor-replay.terminal-controls"
        thread.start()
    }

    func stop() {
        state.withLock { $0.stopped = true }
        finished.wait()
    }

    var error: String? { state.withLock { $0.error } }
}

extension MouseRecorderCLI {
    static func terminalMenu(cancellation session: Cancellation) throws -> Int32 {
        let input = try TerminalInput()
        defer { input.restore() }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let recordingsDirectory = try AppIdentity.recordingsDirectory()
        var lastRecording = try latestRecording(in: recordingsDirectory, workingDirectory: directory)
        let screen = TerminalScreen(title: AppIdentity.displayName)
        try screen.start()
        var farewell = "All done. See you next time."
        defer { screen.stop(finalMessage: farewell) }
        screen.update(TerminalViewState(phase: .ready, message: "Ready when you are.", lastRecording: lastRecording?.lastPathComponent))
        do {
            while !session.isCancelled {
                if let error = screen.error { throw MouseRecorderError(error) }
                guard let choice = try input.readKey(timeoutMS: 100) else { continue }
                guard !session.isCancelled else { break }
                switch choice {
                case 113, 81:
                    session.cancel("Exit")
                case 114, 82, 112, 80:
                    let isRecording = choice == 114 || choice == 82
                    if !isRecording, lastRecording == nil {
                        screen.update(TerminalViewState(phase: .ready, message: "Your first take is one R away."))
                        continue
                    }
                    var output: URL?
                    var controls: ActionControls?
                    do {
                        let arguments: Arguments
                        if isRecording {
                            try FileManager.default.createDirectory(
                                at: recordingsDirectory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700]
                            )
                            let formatter = DateFormatter()
                            formatter.locale = Locale(identifier: "en_US_POSIX")
                            formatter.dateFormat = "yyyyMMdd-HHmmss"
                            let name = "recording-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).json"
                            let file = recordingsDirectory.appendingPathComponent(name)
                            output = file
                            arguments = try Arguments(["record", "-o", file.path])
                        } else if let recording = lastRecording {
                            arguments = try Arguments(["play", recording.path])
                        } else {
                            continue
                        }
                        let action = Cancellation()
                        controls = ActionControls(input: input, action: action, session: session, isRecording: isRecording, screen: screen)
                        _ = try run(arguments, cancellation: action, screen: screen)
                        controls?.stop()
                        if let error = controls?.error { throw MouseRecorderError(error) }
                        if let output, FileManager.default.fileExists(atPath: output.path) {
                            let saved = try Recording.load(from: output.path)
                            if !saved.events.isEmpty {
                                lastRecording = output
                                if session.isCancelled { farewell = "All good. Your recording is saved. See you next time." }
                            } else {
                                screen.update(TerminalViewState(
                                    phase: .ready, message: "No mouse input this time. Press R to try again.",
                                    lastRecording: lastRecording?.lastPathComponent
                                ))
                                if session.isCancelled { farewell = "Stopped. The empty take was saved. See you next time." }
                            }
                        }
                    } catch {
                        controls?.stop()
                        if session.isCancelled { throw error }
                        let fileSaved = output.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                        if fileSaved { lastRecording = output }
                        screen.update(TerminalViewState(
                            phase: .error,
                            message: fileSaved ? "Take saved with a problem: \(error.localizedDescription)" : "Couldn't finish: \(error.localizedDescription)",
                            lastRecording: lastRecording?.lastPathComponent
                        ))
                    }
                case 115, 83, 27:
                    screen.update(TerminalViewState(
                        phase: .ready, message: "Nothing to stop. Press R when you're ready.",
                        lastRecording: lastRecording?.lastPathComponent
                    ))
                case 10, 13:
                    continue
                default:
                    screen.update(TerminalViewState(
                        phase: .ready, message: "Just R, S, P or Q. No Enter needed.",
                        lastRecording: lastRecording?.lastPathComponent
                    ))
                }
            }
        } catch {
            farewell = ""
            throw error
        }
        screen.stop(finalMessage: farewell)
        if let error = screen.error { throw MouseRecorderError(error) }
        return session.reason == "Ctrl+C" || session.reason == "SIGTERM" ? 130 : 0
    }

    private static func latestRecording(in recordings: URL, workingDirectory: URL) throws -> URL? {
        var candidates: [URL] = []
        let legacyDirectory = workingDirectory.appendingPathComponent("recordings", isDirectory: true)
        for folder in Set([recordings, legacyDirectory]) where FileManager.default.fileExists(atPath: folder.path) {
            candidates += try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".verification.json") }
        }
        for name in ["recording.json", "movement.json"] {
            let path = workingDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) { candidates.append(path) }
        }
        let dated = try candidates.compactMap { url -> (URL, Date)? in
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            guard let date = values.contentModificationDate else {
                throw MouseRecorderError("Could not read the modification date for \(url.path).")
            }
            return (url, date)
        }
        return dated.max { $0.1 < $1.1 }?.0
    }
}
