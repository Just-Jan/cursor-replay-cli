import Darwin
import Foundation
import MouseRecorderCore
import Synchronization

enum TerminalKey: Equatable {
    case character(UInt8), up, down, delete
}

struct TerminalKeyDecoder {
    private enum State {
        case normal, escape, sequence
    }
    private var state = State.normal
    private var parameters: [UInt8] = []

    mutating func consume(_ byte: UInt8) -> TerminalKey? {
        switch state {
        case .normal:
            if byte == 8 || byte == 127 { return .delete }
            if byte == 27 {
                state = .escape
                return nil
            }
            return .character(byte)
        case .escape:
            if byte == 91 || byte == 79 {
                state = .sequence
                parameters.removeAll(keepingCapacity: true)
                return nil
            }
            state = .normal
            return consume(byte)
        case .sequence:
            if byte == 27 {
                state = .escape
            } else if (64...126).contains(byte) {
                state = .normal
                if byte == 65 { return .up }
                if byte == 66 { return .down }
                if byte == 126, parameters == [51] { return .delete }
            } else if parameters.count < 16 {
                parameters.append(byte)
            }
            return nil
        }
    }

    mutating func finishEscape() -> TerminalKey? {
        guard state == .escape else { return nil }
        state = .normal
        return .character(27)
    }
}

struct RecordingLibrary {
    let recordings: [URL]
    private(set) var selectedIndex: Int?
    var selectedURL: URL? { selectedIndex.map { recordings[$0] } }

    init(in directory: URL, workingDirectory: URL, selecting selection: URL? = nil) throws {
        var candidates: [URL] = []
        let legacyDirectory = workingDirectory.appendingPathComponent("recordings", isDirectory: true)
        for folder in Set([directory, legacyDirectory]) where FileManager.default.fileExists(atPath: folder.path) {
            candidates += try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".verification.json") }
        }
        for name in ["recording.json", "movement.json"] {
            let path = workingDirectory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) { candidates.append(path) }
        }
        let dated = try Set(candidates.map(\.standardizedFileURL)).compactMap { url -> (URL, Date)? in
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { return nil }
            guard let date = values.contentModificationDate else {
                throw MouseRecorderError("Could not read the modification date for \(url.path).")
            }
            return (url, date)
        }
        recordings = dated.sorted {
            $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1
        }.map(\.0)
        selectedIndex = selection.flatMap { recordings.firstIndex(of: $0.standardizedFileURL) }
            ?? (recordings.isEmpty ? nil : 0)
    }

    mutating func moveSelection(_ offset: Int) {
        guard let selectedIndex else { return }
        self.selectedIndex = min(recordings.count - 1, max(0, selectedIndex + offset))
    }
}

private final class TerminalInput: Sendable {
    private let original: termios
    private let decoder = Mutex(TerminalKeyDecoder())

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

    func readKey(timeoutMS: Int32) throws -> TerminalKey? {
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, timeoutMS)
        if result == 0 { return decoder.withLock { $0.finishEscape() } }
        if result < 0 && errno == EINTR { return nil }
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
        return decoder.withLock { $0.consume(byte) }
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
                    case .character(115), .character(83):
                        action.cancel(isRecording ? "Stop and save" : "Stop playback")
                    case .character(113), .character(81):
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
        var library = try RecordingLibrary(in: recordingsDirectory, workingDirectory: directory)
        var pendingDeletion: URL?
        let screen = TerminalScreen(title: AppIdentity.displayName)
        try screen.start()
        var farewell = "All done. See you next time."
        defer { screen.stop(finalMessage: farewell) }
        screen.update(TerminalViewState(phase: .ready, message: "Ready when you are."))
        screen.updateRecordings(library.recordings.map(\.lastPathComponent), selectedIndex: library.selectedIndex)
        do {
            while !session.isCancelled {
                if let error = screen.error { throw MouseRecorderError(error) }
                guard let choice = try input.readKey(timeoutMS: 100) else { continue }
                guard !session.isCancelled else { break }
                if let recording = pendingDeletion {
                    switch choice {
                    case .character(121), .character(89):
                        let index = library.selectedIndex
                        let deletionError: Int32? = unlink(recording.path) == 0 ? nil : errno
                        library = try RecordingLibrary(in: recordingsDirectory, workingDirectory: directory)
                        if let index { library.moveSelection(index) }
                        pendingDeletion = nil
                        if let deletionError {
                            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(deletionError))
                            screen.update(TerminalViewState(
                                phase: .error, message: "Couldn't delete this take: \(error.localizedDescription)"
                            ))
                        } else {
                            screen.update(TerminalViewState(phase: .ready, message: "Take deleted. Room for the next one."))
                        }
                    case .character(110), .character(78), .character(27):
                        pendingDeletion = nil
                        screen.update(TerminalViewState(phase: .ready, message: "Kept your take. Ready when you are."))
                    case .character(113), .character(81):
                        session.cancel("Exit")
                    default:
                        continue
                    }
                    screen.updateRecordings(library.recordings.map(\.lastPathComponent), selectedIndex: library.selectedIndex)
                    continue
                }
                switch choice {
                case .character(113), .character(81):
                    session.cancel("Exit")
                case .up, .down:
                    library.moveSelection(choice == .up ? -1 : 1)
                    screen.update(TerminalViewState(phase: .ready))
                case .delete:
                    if let recording = library.selectedURL {
                        pendingDeletion = recording
                        screen.update(TerminalViewState(
                            phase: .confirmingDeletion,
                            message: "Delete \"\(recording.lastPathComponent)\" forever? N keeps it safe."
                        ))
                    } else {
                        screen.update(TerminalViewState(phase: .ready, message: "Nothing to delete. Your next take starts with R."))
                    }
                case .character(114), .character(82), .character(112), .character(80), .character(108), .character(76):
                    let isRecording = choice == .character(114) || choice == .character(82)
                    let isLooping = choice == .character(108) || choice == .character(76)
                    if !isRecording, library.selectedURL == nil {
                        screen.update(TerminalViewState(phase: .ready, message: "Your first take is one R away."))
                        continue
                    }
                    var output: URL?
                    var controls: ActionControls?
                    var selection = library.selectedURL
                    do {
                        var arguments: Arguments
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
                        } else if let recording = library.selectedURL {
                            arguments = try Arguments(["play", recording.path])
                            if isLooping { arguments.loops = nil }
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
                                selection = output
                                if session.isCancelled { farewell = "All good. Your recording is saved. See you next time." }
                            } else {
                                screen.update(TerminalViewState(
                                    phase: .ready, message: "No mouse input this time. Press R to try again.",
                                    lastRecording: library.selectedURL?.lastPathComponent
                                ))
                                if session.isCancelled { farewell = "Stopped. The empty take was saved. See you next time." }
                            }
                        }
                    } catch {
                        controls?.stop()
                        if session.isCancelled { throw error }
                        let fileSaved = output.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
                        if fileSaved { selection = output }
                        screen.update(TerminalViewState(
                            phase: .error,
                            message: fileSaved ? "Take saved with a problem: \(error.localizedDescription)" : "Couldn't finish: \(error.localizedDescription)",
                            lastRecording: selection?.lastPathComponent
                        ))
                    }
                    if let selection {
                        library = try RecordingLibrary(
                            in: recordingsDirectory, workingDirectory: directory, selecting: selection
                        )
                    }
                case .character(115), .character(83), .character(27):
                    screen.update(TerminalViewState(
                        phase: .ready, message: "Nothing to stop. Press R when you're ready.",
                        lastRecording: library.selectedURL?.lastPathComponent
                    ))
                case .character(10), .character(13):
                    continue
                default:
                    screen.update(TerminalViewState(
                        phase: .ready, message: "Use Up/Down, R, S, P, L or Q. No Enter needed.",
                        lastRecording: library.selectedURL?.lastPathComponent
                    ))
                }
                screen.updateRecordings(library.recordings.map(\.lastPathComponent), selectedIndex: library.selectedIndex)
            }
        } catch {
            farewell = ""
            throw error
        }
        screen.stop(finalMessage: farewell)
        if let error = screen.error { throw MouseRecorderError(error) }
        return session.reason == "Ctrl+C" || session.reason == "SIGTERM" ? 130 : 0
    }
}
