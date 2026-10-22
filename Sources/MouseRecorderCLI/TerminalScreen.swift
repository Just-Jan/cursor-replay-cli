import Darwin
import Foundation
import Synchronization

enum TerminalPhase: Sendable {
    case ready, countdown, recording, playing, looping, confirmingDeletion, saving, error
}

struct TerminalViewState: Sendable {
    var phase: TerminalPhase = .ready
    var message: String = "Ready when you are."
    var lastRecording: String? = nil
    var countdown: Int? = nil
    var startedAt: TimeInterval? = nil
    var duration: TimeInterval? = nil
    var eventCount: Int? = nil
    var recordings: [String] = []
    var selectedRecordingIndex: Int? = nil
}

final class TerminalScreen: Sendable {
    private struct ScreenFailure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private enum Lifecycle {
        case idle, running, stopped
    }

    private struct Storage {
        var view = TerminalViewState()
        var lifecycle = Lifecycle.idle
        var thread: Thread?
        var didStart = false
        var finalMessage: String?
        var failure: String?
    }

    private final class Presentation: Sendable {
        let title: String
        let storage = Mutex(Storage())
        let started = DispatchGroup()
        let finished = DispatchGroup()

        init(title: String) {
            self.title = title
        }

        func record(_ failure: ScreenFailure) {
            storage.withLock {
                if let previous = $0.failure {
                    $0.failure = previous + " " + failure.message
                } else {
                    $0.failure = failure.message
                }
            }
        }
    }

    private let presentation: Presentation

    init(title: String) {
        presentation = Presentation(title: title)
    }

    deinit {
        stop(finalMessage: "Closed.")
    }

    /// Starts once. A second call while running is harmless; a stopped screen cannot restart.
    func start() throws {
        let presentation = presentation
        try presentation.storage.withLock { storage in
            switch storage.lifecycle {
            case .idle:
                presentation.started.enter()
                presentation.finished.enter()
                let thread = Thread {
                    Self.present(presentation)
                }
                thread.name = "mouserec.terminal-screen"
                thread.qualityOfService = .utility
                storage.thread = thread
                storage.didStart = true
                storage.lifecycle = .running
                thread.start()
            case .running:
                break
            case .stopped:
                throw ScreenFailure(message: storage.failure ?? "The terminal screen has already stopped.")
            }
        }
        presentation.started.wait()
        if let error {
            throw ScreenFailure(message: error)
        }
    }

    /// This is the only operation needed on recording and replay worker paths.
    func update(_ state: TerminalViewState) {
        presentation.storage.withLock {
            if $0.lifecycle != .stopped, $0.finalMessage == nil {
                $0.view = state
            }
        }
    }

    func updateRecordings(_ recordings: [String], selectedIndex: Int?) {
        presentation.storage.withLock {
            guard $0.lifecycle != .stopped, $0.finalMessage == nil else { return }
            $0.view.recordings = recordings
            $0.view.selectedRecordingIndex = selectedIndex
            $0.view.lastRecording = selectedIndex.flatMap { recordings.indices.contains($0) ? recordings[$0] : nil }
        }
    }

    /// The first stop message wins. Waiting also joins a worker that failed asynchronously.
    func stop(finalMessage: String) {
        let shouldWait = presentation.storage.withLock { storage in
            if storage.lifecycle == .idle {
                storage.lifecycle = .stopped
            } else if storage.lifecycle == .running, storage.finalMessage == nil {
                storage.finalMessage = finalMessage
            }
            return storage.didStart
        }
        if shouldWait {
            presentation.finished.wait()
        }
    }

    var error: String? {
        presentation.storage.withLock { $0.failure }
    }

    private enum OutputMode {
        case ansi, singleLine, plain
    }

    private struct Capabilities {
        let mode: OutputMode
        let color: Bool
        let unicode: Bool

        init() {
            let environment = ProcessInfo.processInfo.environment
            let tty = isatty(STDOUT_FILENO) == 1
            let term = environment["TERM"]?.lowercased() ?? ""
            let ansi = tty && !["", "dumb", "unknown"].contains(term)
            mode = ansi ? .ansi : (tty ? .singleLine : .plain)
            color = TerminalScreen.colorEnabled(environment: environment, ansi: ansi)
            let locale = ["LC_ALL", "LC_CTYPE", "LANG"]
                .compactMap { environment[$0] }
                .first { !$0.isEmpty }?
                .uppercased() ?? ""
            unicode = locale.contains("UTF-8") || locale.contains("UTF8")
        }
    }

    static func colorEnabled(environment: [String: String], ansi: Bool) -> Bool {
        ansi && environment["NO_COLOR"] == nil && environment["CLICOLOR"] != "0"
    }

    private static func present(_ presentation: Presentation) {
        let capabilities = Capabilities()
        var startupSignalled = false
        var restoreAlternateScreen = false
        var singleLineWidth = 0
        var lastFrame: String?
        var lastSize: (width: Int, height: Int)?
        var plainErrorWritten = false
        var tick = 0

        defer {
            presentation.storage.withLock {
                $0.lifecycle = .stopped
                $0.thread = nil
            }
            if !startupSignalled {
                presentation.started.leave()
            }
            presentation.finished.leave()
        }

        do throws(ScreenFailure) {
            // A closed pipe must report EPIPE, not terminate the process with SIGPIPE.
            var mask = sigset_t()
            sigemptyset(&mask)
            sigaddset(&mask, SIGPIPE)
            let maskResult = pthread_sigmask(SIG_BLOCK, &mask, nil)
            guard maskResult == 0 else {
                throw ScreenFailure(message: "Could not protect terminal output (error \(maskResult)).")
            }
            if capabilities.mode == .ansi {
                // Even a partial setup write needs a matching restoration attempt.
                restoreAlternateScreen = true
                try write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J")
            }
            while true {
                let snapshot = presentation.storage.withLock { ($0.view, $0.finalMessage) }
                if snapshot.1 != nil { break }
                let size = terminalSize()
                let resized = lastSize.map { $0.width != size.width || $0.height != size.height } ?? false
                let now = ProcessInfo.processInfo.systemUptime
                switch capabilities.mode {
                case .ansi:
                    let frame = render(
                        title: presentation.title, state: snapshot.0,
                        width: size.width, height: size.height,
                        frame: tick / 2, now: now,
                        color: capabilities.color, unicode: capabilities.unicode
                    )
                    if frame != lastFrame || resized {
                        try write(changedRows(previous: lastFrame, current: frame, height: size.height, resized: resized))
                        lastFrame = frame
                    }
                case .singleLine:
                    let message = snapshot.0.phase == .ready
                        ? (selectedRecording(snapshot.0)?.name ?? friendlyMessage(snapshot.0))
                        : friendlyMessage(snapshot.0)
                    let line = clipped(
                        status(snapshot.0, now: now, frame: 0, unicode: false)
                            + "  " + controls(snapshot.0, width: size.width, compact: true)
                            + "  " + message,
                        width: size.width, unicode: false, isError: snapshot.0.phase == .error
                    )
                    if line != lastFrame || resized {
                        let oldWidth = min(singleLineWidth, size.width)
                        let padding = String(repeating: " ", count: max(0, oldWidth - cellWidth(line)))
                        try write("\r" + line + padding + "\r")
                        singleLineWidth = cellWidth(line)
                        lastFrame = line
                    }
                case .plain:
                    // Redirected output is a summary, not an animation or an event log.
                    if lastFrame == nil {
                        try write(clipped(
                            sanitized(presentation.title) + ": "
                                + summary(snapshot.0, now: now, frame: 0, unicode: false),
                            width: 160, unicode: false, isError: snapshot.0.phase == .error
                        ) + "\n")
                        lastFrame = ""
                        plainErrorWritten = snapshot.0.phase == .error
                    } else if snapshot.0.phase == .error, !plainErrorWritten {
                        try write(clipped(
                            "ERROR: " + friendlyMessage(snapshot.0), width: 160, unicode: false, isError: true
                        ) + "\n")
                        plainErrorWritten = true
                    }
                }
                lastSize = size
                if !startupSignalled {
                    presentation.started.leave()
                    startupSignalled = true
                }
                tick = tick == Int.max ? 0 : tick + 1
                Thread.sleep(forTimeInterval: 0.125)
            }
        } catch {
            // The do block only throws ScreenFailure, including partial writes.
            presentation.record(error)
        }

        if restoreAlternateScreen {
            do {
                try write("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
            } catch {
                presentation.record(error)
            }
        }

        let final = presentation.storage.withLock { ($0.view, $0.finalMessage, $0.failure) }
        if final.1 != nil || final.2 != nil {
            let finalText: String
            if let failure = final.2 {
                finalText = "ERROR: " + failure
            } else if final.0.phase == .error {
                let goodbye = sanitized(final.1 ?? "")
                finalText = "ERROR: " + friendlyMessage(final.0) + (goodbye.isEmpty ? "" : " " + goodbye)
            } else {
                let goodbye = sanitized(final.1 ?? "")
                finalText = goodbye.isEmpty ? "Closed." : goodbye
            }
            let width = capabilities.mode == .plain ? 160 : terminalSize().width
            let line = clipped(
                sanitized(finalText), width: width, unicode: capabilities.unicode,
                isError: final.2 != nil || final.0.phase == .error
            )
            let padding = capabilities.mode == .singleLine
                ? String(repeating: " ", count: max(0, min(singleLineWidth, width) - cellWidth(line)))
                : ""
            do {
                try write((capabilities.mode == .singleLine ? "\r" : "") + line + padding + "\n")
            } catch {
                presentation.record(error)
                do {
                    try write("ERROR: " + sanitized(error.message) + "\n", descriptor: STDERR_FILENO)
                } catch {
                    presentation.record(error)
                }
            }
        }
    }

    private static func write(
        _ text: String, descriptor: Int32 = STDOUT_FILENO
    ) throws(ScreenFailure) {
        let bytes = Array(text.utf8)
        let failure: ScreenFailure? = bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return nil }
            var offset = 0
            while offset < buffer.count {
                var output = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&output, 1, 250)
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else {
                    let detail = ready == 0 ? "output timed out" : "errno \(errno)"
                    return ScreenFailure(message: "Could not write the terminal screen (\(detail)).")
                }
                guard output.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
                    return ScreenFailure(message: "The terminal output connection closed.")
                }
                let count = Darwin.write(descriptor, base.advanced(by: offset), min(512, buffer.count - offset))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    return ScreenFailure(message: "Could not write the terminal screen (errno \(errno)).")
                }
                offset += count
            }
            return nil
        }
        if let failure {
            throw failure
        }
    }

    private static func terminalSize() -> (width: Int, height: Int) {
        var size = winsize()
        let valid = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0
        let columns = valid && size.ws_col > 0 ? Int(size.ws_col) : 80
        let rows = valid && size.ws_row > 0 ? Int(size.ws_row) : 24
        // Leaving the final column unused avoids automatic wrapping and scrolling.
        return (max(1, columns - 1), max(1, rows))
    }

    private enum Tone {
        case normal, title, muted, controls, ready, recording, playing, error

        var escape: String {
            switch self {
            case .normal: ""
            case .title: "\u{1B}[1m"
            case .muted: "\u{1B}[2m"
            case .controls: "\u{1B}[97m"
            case .ready: "\u{1B}[32m"
            case .recording: "\u{1B}[31m"
            case .playing: "\u{1B}[36m"
            case .error: "\u{1B}[1;31m"
            }
        }
    }

    private struct Row {
        var text: String
        var tone: Tone = .normal
    }

    static func changedRows(previous: String?, current: String, height: Int, resized: Bool = false) -> String {
        guard height > 0 else { return "" }
        let old = resized ? [] : (previous?.components(separatedBy: "\n") ?? [])
        let new = current.components(separatedBy: "\n")
        let count = min(height, max(old.count, new.count))
        // Terminal reflow invalidates every old row position after a resize.
        var output = resized ? "\u{1B}[2J\u{1B}[H" : ""
        for index in 0..<count {
            let before = index < old.count ? old[index] : nil
            let after = index < new.count ? new[index] : ""
            if before != after {
                output += "\u{1B}[\(index + 1);1H" + after + "\u{1B}[K"
            }
        }
        return output
    }

    /// A pure frame: no cursor movement, environment reads, terminal I/O, or clock reads.
    static func render(
        title: String,
        state: TerminalViewState,
        width: Int,
        height: Int = 24,
        frame: Int = 0,
        now: TimeInterval,
        color: Bool = false,
        unicode: Bool = true
    ) -> String {
        guard width > 0, height > 0 else { return "" }
        let available = min(width, 512)
        let height = min(height, 256)
        let contentWidth = min(62, available)
        let inset = String(repeating: " ", count: (available - contentWidth) / 2)
        let tone: Tone
        switch state.phase {
        case .ready: tone = .ready
        case .recording, .confirmingDeletion: tone = .recording
        case .playing, .looping: tone = .playing
        case .error: tone = .error
        default: tone = .normal
        }

        var rows: [Row]
        if height <= 2 {
            rows = [
                Row(text: summary(state, now: now, frame: frame, unicode: unicode), tone: tone),
                Row(text: controls(state, width: contentWidth, compact: true), tone: .controls)
            ]
            rows = Array(rows.prefix(height))
        } else {
            var detail = status(state, now: now, frame: frame, unicode: unicode)
            if state.phase == .recording, let count = state.eventCount {
                detail += "   \(max(0, count)) events"
            }
            let count = min(10, height)
            rows = Array(repeating: Row(text: ""), count: count)
            let footer = count - 1
            let statusRow = count >= 8 ? 2 : 0
            let fileRow = count >= 8 ? footer - 2 : nil
            let progressRow: Int? = count >= 9 ? footer - 4 : (count >= 6 && count < 8 ? footer - 2 : nil)
            let messageStart = statusRow + 1
            let messageEnd = min(progressRow ?? footer, fileRow ?? footer, footer)
            let messageCount = min(2, max(0, messageEnd - messageStart))

            if count >= 8 { rows[0] = Row(text: sanitized(title), tone: .title) }
            rows[statusRow] = Row(text: detail, tone: tone)
            let messages = messageLines(
                friendlyMessage(state), width: contentWidth, count: messageCount, unicode: unicode
            )
            for (offset, message) in messages.enumerated() {
                rows[messageStart + offset] = Row(text: message, tone: state.phase == .error ? .error : .normal)
            }
            if let progressRow, state.phase == .playing,
               let duration = finiteDuration(state), duration > 0 {
                let fraction = min(1, elapsed(state, now: now) / duration)
                let length = min(24, max(0, contentWidth - 9))
                if length > 0 {
                    let filled = Int((Double(length) * fraction).rounded(.down))
                    let bar = String(repeating: unicode ? "━" : "=", count: filled)
                        + String(repeating: unicode ? "·" : ".", count: length - filled)
                    rows[progressRow] = Row(
                        text: "[\(bar)] \(Int((fraction * 100).rounded(.down)))%",
                        tone: .muted
                    )
                }
            }
            if let fileRow, let recording = savedName(state) {
                rows[fileRow] = Row(text: (state.phase == .confirmingDeletion ? "Take: " : "Last: ") + recording, tone: .muted)
            }
            if (state.phase == .ready || state.phase == .error), let selected = selectedRecording(state) {
                if let fileRow { rows[fileRow] = Row(text: "") }
                if let progressRow {
                    let arrows = unicode ? "↑/↓" : "Up/Down"
                    let hint = state.recordings.count > 1 ? "\(arrows) Select recording" : "Recording"
                    rows[progressRow] = Row(
                        text: "\(hint)  \(selected.index + 1)/\(state.recordings.count)  Backspace/Del deletes", tone: .muted
                    )
                }
                let listStart = max(messageStart + messageCount, progressRow.map { $0 + 1 } ?? footer - 3)
                let visibleCount = min(2, footer - listStart, state.recordings.count)
                if visibleCount > 0 {
                    let first = min(max(0, selected.index - 1), state.recordings.count - visibleCount)
                    for offset in 0..<visibleCount {
                        let index = first + offset
                        rows[listStart + offset] = Row(
                            text: (index == selected.index ? "> " : "  ") + "\(index + 1). " + sanitized(state.recordings[index]),
                            tone: index == selected.index ? .normal : .muted
                        )
                    }
                } else if state.phase == .ready {
                    rows[statusRow] = Row(
                        text: "Ready  \(selected.index + 1)/\(state.recordings.count): \(selected.name)", tone: tone
                    )
                }
            }
            rows[footer] = Row(
                text: controls(state, width: contentWidth, compact: height < 6),
                tone: .controls
            )
        }

        let top = min(3, max(0, (height - rows.count) / 3))
        var lines = Array(repeating: "", count: top)
        for row in rows {
            let text = clipped(
                row.text, width: contentWidth, unicode: unicode,
                isError: state.phase == .error && row.tone == .error
            )
            if text.isEmpty {
                lines.append("")
            } else if color, !row.tone.escape.isEmpty {
                lines.append(inset + row.tone.escape + text + "\u{1B}[0m")
            } else {
                lines.append(inset + text)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func messageLines(_ text: String, width: Int, count: Int, unicode: Bool) -> [String] {
        guard count > 0 else { return [] }
        let characters = Array(text)
        var start = 0
        var lines: [String] = []
        for row in 0..<count where start < characters.count {
            if row == count - 1 {
                lines.append(clipped(String(characters[start...]), width: width, unicode: unicode))
                break
            }
            var end = start
            var cells = 0
            var lastSpace: Int?
            while end < characters.count {
                let next = cellWidth(characters[end])
                if cells + next > width { break }
                cells += next
                if characters[end] == " " { lastSpace = end }
                end += 1
            }
            if end == characters.count {
                lines.append(String(characters[start..<end]))
                break
            }
            if end == start {
                lines.append(clipped(String(characters[start]), width: width, unicode: unicode))
                start += 1
            } else {
                let cut = lastSpace ?? end
                lines.append(String(characters[start..<cut]))
                start = cut
                while start < characters.count, characters[start] == " " { start += 1 }
            }
        }
        return lines
    }

    private static func status(
        _ state: TerminalViewState, now: TimeInterval, frame: Int, unicode: Bool
    ) -> String {
        switch state.phase {
        case .ready:
            if let selected = selectedRecording(state) {
                return "Ready  \(selected.index + 1)/\(state.recordings.count)"
            }
            return "Ready"
        case .countdown:
            if let count = state.countdown {
                return "Starting in \(max(0, count))..."
            }
            return "Getting ready..."
        case .recording:
            let frames = unicode ? ["·", "•", "●", "•"] : [".", "o", "O", "o"]
            let dot = frames[((frame % frames.count) + frames.count) % frames.count]
            return "\(dot) Recording  \(timestamp(elapsed(state, now: now)))"
        case .playing:
            let duration = finiteDuration(state)
            let position = min(elapsed(state, now: now), duration ?? .greatestFiniteMagnitude)
            return "Playing  " + timestamp(position) + (duration.map { " / " + timestamp($0) } ?? "")
        case .looping:
            return "Looping  " + timestamp(elapsed(state, now: now))
        case .confirmingDeletion:
            return "Let this take go?"
        case .saving:
            return "Saving..."
        case .error:
            return "ERROR"
        }
    }

    private static func summary(
        _ state: TerminalViewState, now: TimeInterval, frame: Int, unicode: Bool
    ) -> String {
        let label = status(state, now: now, frame: frame, unicode: unicode)
        if state.phase == .ready, let selected = selectedRecording(state) {
            return label + " | " + selected.name
        }
        return label + (state.phase == .error ? ": " : " | ") + friendlyMessage(state)
    }

    private static func selectedRecording(_ state: TerminalViewState) -> (index: Int, name: String)? {
        guard let index = state.selectedRecordingIndex, state.recordings.indices.contains(index) else { return nil }
        return (index, sanitized(state.recordings[index]))
    }

    private static func friendlyMessage(_ state: TerminalViewState) -> String {
        let message = sanitized(state.message)
        if state.phase == .error, message.isEmpty || message == TerminalViewState().message {
            return "Something went wrong."
        }
        if !message.isEmpty { return message }
        return "Ready when you are."
    }

    private static func savedName(_ state: TerminalViewState) -> String? {
        guard let path = state.lastRecording else { return nil }
        let clean = sanitized(path)
        guard !clean.isEmpty else { return nil }
        let name = (clean as NSString).lastPathComponent
        return name.isEmpty ? clean : name
    }

    private static func controls(_ state: TerminalViewState, width: Int, compact: Bool) -> String {
        let action: String
        let keys: String
        switch state.phase {
        case .ready, .error:
            action = savedName(state) == nil ? "[R] Record" : "[R] Record   [P] Play   [L] Loop"
            keys = savedName(state) == nil ? "R Q" : "R P L Q"
        case .countdown:
            action = "[S] Cancel"
            keys = "S Q"
        case .recording:
            action = "[S] Stop + save"
            keys = "S Q"
        case .playing, .looping:
            action = "[S] Stop playback"
            keys = "S Q"
        case .confirmingDeletion:
            action = "[Y] Delete   [N] Keep"
            keys = "Y N Q"
        case .saving:
            action = ""
            keys = "Q"
        }
        if width < 20 { return keys }
        if compact || width < 44 {
            return keys.split(separator: " ").map { "[\($0)]" }.joined(separator: " ")
        }
        return action.padding(toLength: 36, withPad: " ", startingAt: 0) + "[Q] Quit"
    }

    private static func elapsed(_ state: TerminalViewState, now: TimeInterval) -> TimeInterval {
        guard let start = state.startedAt, start.isFinite, now.isFinite else { return 0 }
        let difference = now - start
        return difference.isFinite ? max(0, difference) : 0
    }

    private static func finiteDuration(_ state: TerminalViewState) -> TimeInterval? {
        guard let duration = state.duration, duration.isFinite, duration >= 0 else { return nil }
        return duration
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = Int(min(359_999, max(0, seconds.isFinite ? seconds : 0)))
        let minutes = (total / 60) % 60
        let remainder = total % 60
        let tail = String(format: "%02d:%02d", minutes, remainder)
        return total >= 3_600 ? "\(total / 3_600):" + tail : tail
    }

    private enum EscapeState {
        case text, escape, csi, string, stringEscape
    }

    private static func sanitized(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var mode = EscapeState.text
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch mode {
            case .escape:
                switch value {
                case 0x5B: mode = .csi
                case 0x5D, 0x50, 0x58, 0x5E, 0x5F: mode = .string
                case 0x20...0x2F: break
                default: mode = .text
                }
            case .csi:
                if value == 0x1B { mode = .escape }
                else if (0x40...0x7E).contains(value) { mode = .text }
            case .string:
                if value == 0x07 || value == 0x9C { mode = .text }
                else if value == 0x1B { mode = .stringEscape }
            case .stringEscape:
                if value == 0x5C { mode = .text }
                else if value != 0x1B { mode = .string }
            case .text:
                switch value {
                case 0x1B: mode = .escape
                case 0x9B: mode = .csi
                case 0x90, 0x98, 0x9D, 0x9E, 0x9F: mode = .string
                default:
                    let category = scalar.properties.generalCategory
                    if scalar.properties.isWhitespace {
                        if output.last != " " { output.append(" ") }
                    } else if category != .control && (category != .format || value == 0x200D) {
                        output.append(scalar)
                    }
                }
            }
        }
        return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clipped(
        _ text: String, width: Int, unicode: Bool, isError: Bool = false
    ) -> String {
        guard width > 0 else { return "" }
        if isError, width < 6 {
            return width == 1 ? "!" : "!" + clipped(text, width: width - 1, unicode: unicode)
        }
        guard cellWidth(text) > width else { return text }
        let marker = unicode ? "…" : "~"
        var result = ""
        var used = 0
        for character in text {
            let cells = cellWidth(character)
            if used + cells > width - 1 { break }
            result.append(character)
            used += cells
        }
        return result + marker
    }

    private static func cellWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + cellWidth($1) }
    }

    private static func cellWidth(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        if scalars.contains(where: { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }) {
            return 2
        }
        return scalars.reduce(0) { width, scalar in
            let category = scalar.properties.generalCategory
            if category == .nonspacingMark || category == .enclosingMark || category == .format {
                return width
            }
            let value = scalar.value
            let wide = (0x1100...0x115F).contains(value) || value == 0x2329 || value == 0x232A
                || ((0x2E80...0xA4CF).contains(value) && value != 0x303F)
                || (0xAC00...0xD7A3).contains(value) || (0xF900...0xFAFF).contains(value)
                || (0xFE10...0xFE19).contains(value) || (0xFE30...0xFE6F).contains(value)
                || (0xFF00...0xFF60).contains(value) || (0xFFE0...0xFFE6).contains(value)
                || (0x20000...0x3FFFD).contains(value)
            return max(width, wide ? 2 : 1)
        }
    }
}
