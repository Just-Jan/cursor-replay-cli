import Foundation
import Testing
@testable import MouseRecorderCLI

struct TerminalScreenTests {
    @Test func readyStatusIsGreenAndRespectsNoColor() {
        let state = TerminalViewState(lastRecording: "session.json")
        let colored = render(state, color: true)
        #expect(colored.contains("\u{1B}[32mReady\u{1B}[0m"))
        #expect(colored.contains("\u{1B}[97m[R] Record"))
        #expect(!render(state, color: false).contains("\u{1B}[32m"))
    }

    private func render(
        _ state: TerminalViewState = TerminalViewState(),
        width: Int = 80, height: Int = 24, frame: Int = 0,
        now: TimeInterval = 112, color: Bool = false, unicode: Bool = true
    ) -> String {
        TerminalScreen.render(
            title: "Test title", state: state, width: width, height: height,
            frame: frame, now: now, color: color, unicode: unicode
        )
    }

    @Test func readyOffersPlaybackOnlyWhenARecordingExists() {
        var state = TerminalViewState()
        let empty = render(state)
        #expect(empty.contains("Test title"))
        #expect(empty.contains("Ready when you are."))
        #expect(empty.contains("[R] Record"))
        #expect(!empty.contains("[P] Play"))
        #expect(empty.contains("[Q] Quit"))
        #expect(!empty.contains("Ctrl+C"))

        state.lastRecording = "/some/private/folder/session.json"
        let saved = render(state)
        #expect(saved.contains("[P] Play"))
        #expect(saved.contains("Last: session.json"))
        #expect(!saved.contains("/some/private/folder"))
    }

    @Test func recordingPulsesWithoutMovingTheStatusOrLosingElapsedTime() {
        let state = TerminalViewState(phase: .recording, startedAt: 100, eventCount: 42)
        let small = render(state, frame: 0)
        let medium = render(state, frame: 1)
        let large = render(state, frame: 2)
        #expect(small.contains("· Recording  00:12"))
        #expect(medium.contains("• Recording  00:12"))
        #expect(large.contains("● Recording  00:12"))
        #expect(large.contains("42 events"))
        #expect(large.contains("[S] Stop + save"))
        #expect(!large.contains("[R] Record"))
        #expect(render(state, frame: -2).contains("● Recording"))
        #expect(render(state, frame: 2, unicode: false).contains("O Recording"))
    }

    @Test func playbackProgressIsBoundedAndMissingDurationIsNotInvented() {
        var state = TerminalViewState(phase: .playing, startedAt: 100, duration: 48)
        let quarter = render(state)
        #expect(quarter.contains("Playing  00:12 / 00:48"))
        #expect(quarter.contains("25%"))
        #expect(quarter.contains("[S] Stop playback"))
        #expect(render(state, now: 200).contains("100%"))
        #expect(render(state, now: 99).contains("0%"))
        #expect(render(state, now: 200).contains("00:48 / 00:48"))

        state.duration = nil
        #expect(!render(state).contains("%"))
        #expect(!render(state).contains(" / "))
        state.duration = 0
        #expect(!render(state).contains("%"))
    }

    @Test func errorsAreExplicitEvenWithAnEmptyMessageOrNoColor() {
        var state = TerminalViewState(phase: .error, message: "Permission was denied.")
        let error = render(state)
        #expect(error.contains("ERROR"))
        #expect(error.contains("Permission was denied."))
        #expect(!error.contains("Ready when you are."))
        #expect(!error.contains("\u{1B}"))

        state.message = "\n\t"
        #expect(render(state).contains("Something went wrong."))
        #expect(!render(state).contains("Ready when you are."))
        #expect(render(state, height: 1).contains("ERROR: Something went wrong."))
        #expect(render(state, width: 1, height: 1) == "!")
        #expect(render(state, width: 2, height: 1).hasPrefix("!"))
        #expect(!render(TerminalViewState(phase: .error)).contains("Ready when you are."))
    }

    @Test func onlyTheLatestMessageAppearsInAReplacementFrame() {
        var state = TerminalViewState(message: "The old notification.")
        #expect(render(state).contains("The old notification."))
        state.message = "The new notification."
        let replacement = render(state)
        #expect(replacement.contains("The new notification."))
        #expect(!replacement.contains("The old notification."))
        #expect(replacement.components(separatedBy: "The new notification.").count == 2)
    }

    @Test func narrowAndShortTerminalsStayWithinTheirBounds() {
        let state = TerminalViewState(
            phase: .recording, message: String(repeating: "A long message ", count: 50),
            lastRecording: String(repeating: "recording", count: 50),
            startedAt: 100, eventCount: 100_000
        )
        for width in [1, 2, 8, 19, 32, 80] {
            for height in [1, 2, 3, 6, 24] {
                let frame = render(state, width: width, height: height, unicode: false)
                let lines = frame.components(separatedBy: "\n")
                #expect(lines.count <= height)
                #expect(lines.allSatisfy { $0.count <= width })
            }
        }
        #expect(render(state, width: 0).isEmpty)
        #expect(render(state, height: -1).isEmpty)
        #expect(render(state, width: 19, height: 3).contains("S Q"))
    }

    @Test func wideGraphemesAndCombiningMarksAreClippedAsWholeCharacters() {
        let state = TerminalViewState(message: "界界界界界界界界界界")
        let frame = render(state, width: 9, height: 3)
        #expect(frame.contains("界界界界…"))
        #expect(!frame.contains("界界界界界"))

        let emoji = TerminalViewState(message: String(repeating: "👩‍💻", count: 10))
        #expect(render(emoji, width: 7, height: 3).contains("👩‍💻👩‍💻👩‍💻…"))
        let combining = TerminalViewState(message: String(repeating: "e\u{301}", count: 10))
        #expect(render(combining, width: 5, height: 3).contains("e\u{301}e\u{301}e\u{301}e\u{301}…"))
    }

    @Test func terminalSequencesAndControlCharactersCannotEscapeTheFrame() {
        let state = TerminalViewState(
            phase: .error,
            message: "Before\u{1B}[31m red\u{1B}[0m\nnext\tline\u{07}\u{08}"
                + "\u{1B}]0;hidden title\u{07}"
                + "\u{1B}]8;;https://invalid.test\u{1B}\\link\u{1B}]8;;\u{1B}\\"
                + "\u{9B}2J\u{202E} end",
            lastRecording: "file\u{1B}[2J.json"
        )
        let frame = TerminalScreen.render(
            title: "Safe\u{1B}[2J title\r\nonly", state: state,
            width: 100, height: 24, now: 112
        )
        #expect(frame.contains("Before red next line"))
        #expect(frame.contains("link end"))
        #expect(frame.contains("Safe title only"))
        #expect(!frame.contains("hidden title"))
        #expect(!frame.contains("invalid.test"))
        #expect(!frame.contains("[31m"))
        #expect(!frame.contains("[2J"))
        #expect(!frame.unicodeScalars.contains {
            ($0.properties.generalCategory == .control && $0 != "\n") || $0.value == 0x202E
        })
    }

    @Test func ansiStylingChangesNoVisibleContentAndHonorsNoColor() {
        let state = TerminalViewState(phase: .error, message: "Cannot open the recording.")
        let plain = render(state, color: false)
        let styled = render(state, color: true)
        let unstyled = styled.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression
        )
        #expect(unstyled == plain)
        #expect(styled.contains("\u{1B}[1;31mERROR\u{1B}[0m"))
        #expect(!styled.contains("\u{1B}[?"))
        #expect(TerminalScreen.colorEnabled(environment: [:], ansi: true))
        #expect(!TerminalScreen.colorEnabled(environment: ["NO_COLOR": ""], ansi: true))
        #expect(!TerminalScreen.colorEnabled(environment: ["NO_COLOR": "1"], ansi: true))
        #expect(!TerminalScreen.colorEnabled(environment: [:], ansi: false))
        #expect(!TerminalScreen.colorEnabled(environment: ["CLICOLOR": "0"], ansi: true))
    }

    @Test func invalidTimingDataDoesNotProduceNanOrTrap() {
        for duration in [Double.nan, .infinity, -.infinity, -1] {
            let state = TerminalViewState(
                phase: .playing, startedAt: .nan, duration: duration, eventCount: .min
            )
            let frame = render(state, frame: .min, now: .infinity)
            #expect(frame.contains("Playing  00:00"))
            #expect(!frame.contains("%"))
            #expect(!frame.lowercased().contains("nan"))
        }
        let state = TerminalViewState(phase: .recording, startedAt: 100, eventCount: .min)
        #expect(render(state, now: 99).contains("00:00"))
        #expect(render(state, now: .greatestFiniteMagnitude).contains("99:59:59"))
        #expect(render(state).contains("0 events"))
    }

    @Test func quitShortcutRemainsAvailableWithoutAnExtraHintSentence() {
        for phase: TerminalPhase in [.ready, .countdown, .recording, .playing, .saving, .error] {
            let state = TerminalViewState(phase: phase, lastRecording: "session.json")
            for width in [19, 32, 80] {
                let output = render(state, width: width)
                #expect(output.contains("Q"))
                #expect(!output.contains("Ctrl+C"))
                #expect(!output.contains("^C"))
            }
        }
    }

    @Test func shortcutRowsAreWhiteInEveryInteractivePhase() {
        for phase: TerminalPhase in [.ready, .countdown, .recording, .playing, .saving, .error] {
            let state = TerminalViewState(phase: phase, lastRecording: "session.json")
            let styled = render(state, color: true)
            let row = styled.components(separatedBy: "\n").first { $0.contains("[Q]") }
            #expect(row?.contains("\u{1B}[97m") == true)
            #expect(row?.hasSuffix("\u{1B}[0m") == true)
            #expect(!render(state, color: false).contains("\u{1B}[97m"))
        }
    }

    @Test func shortcutFooterStaysOnTheSameRowAcrossStatesAndContentChanges() {
        let phases: [TerminalPhase] = [.ready, .countdown, .recording, .playing, .saving, .error]
        for width in [8, 19, 32, 80] {
            for height in [3, 4, 6, 8, 9, 10, 24] {
                var positions: [Int] = []
                for (index, phase) in phases.enumerated() {
                    let state = TerminalViewState(
                        phase: phase,
                        message: index.isMultiple(of: 2) ? "Short." : String(repeating: "A much longer message ", count: 20),
                        lastRecording: index.isMultiple(of: 2) ? nil : "session.json",
                        duration: phase == .playing ? 24 : nil
                    )
                    let lines = render(state, width: width, height: height).components(separatedBy: "\n")
                    if let footer = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        positions.append(footer)
                        #expect(lines[footer].contains("Q"))
                    } else {
                        Issue.record("The shortcut footer was missing.")
                    }
                }
                #expect(Set(positions).count == 1)
            }
        }
    }

    @Test func messageAreaWrapsWithoutDisplacingTheProgressOrFooter() {
        let short = TerminalViewState(phase: .playing, message: "Short.", duration: 24)
        let long = TerminalViewState(
            phase: .playing,
            message: "A recording was saved with a note. This extra detail belongs in the fixed message area.",
            lastRecording: "session.json", duration: 24
        )
        let first = render(short).components(separatedBy: "\n")
        let second = render(long).components(separatedBy: "\n")
        #expect(first.count == second.count)
        #expect(first.firstIndex { $0.contains("%") } == second.firstIndex { $0.contains("%") })
        #expect(first.firstIndex { $0.contains("[S]") } == second.firstIndex { $0.contains("[S]") })
        #expect(second.contains { $0.contains("A recording was saved with a note.") })
        #expect(second.contains { $0.contains("fixed message area.") })
    }

    @Test func quitControlKeepsItsColumnAcrossPhases() {
        var columns: [Int] = []
        for phase: TerminalPhase in [.ready, .countdown, .recording, .playing, .saving, .error] {
            let state = TerminalViewState(phase: phase, lastRecording: "session.json")
            let line = render(state).components(separatedBy: "\n").last ?? ""
            if let range = line.range(of: "[Q]") {
                columns.append(line.distance(from: line.startIndex, to: range.lowerBound))
            } else {
                Issue.record("The quit control was missing.")
            }
        }
        #expect(Set(columns).count == 1)
    }

    @Test func animationRedrawsOnlyTheChangingActivityRow() {
        let state = TerminalViewState(phase: .recording, message: "Recording.", startedAt: 100, eventCount: 42)
        let first = render(state, frame: 0)
        let second = render(state, frame: 1)
        let patch = TerminalScreen.changedRows(previous: first, current: second, height: 24)
        #expect(patch.contains("• Recording"))
        #expect(!patch.contains("Test title"))
        #expect(!patch.contains("[S]"))
        #expect(!patch.contains("[Q]"))
        #expect(!patch.contains("\u{1B}[J"))
        #expect(!patch.contains("\n"))
        #expect(TerminalScreen.changedRows(previous: second, current: second, height: 24).isEmpty)
    }

    @Test func rowChangesClearShorterContentAndRespectViewportHeight() {
        let patch = TerminalScreen.changedRows(previous: "title\nlong old message\nfooter", current: "title\nshort", height: 3)
        #expect(patch == "\u{1B}[2;1Hshort\u{1B}[K\u{1B}[3;1H\u{1B}[K")
        let resized = TerminalScreen.changedRows(previous: "a\nb\nc", current: "x", height: 1)
        #expect(resized == "\u{1B}[1;1Hx\u{1B}[K")
        #expect(TerminalScreen.changedRows(previous: "a", current: "b", height: 0).isEmpty)
    }
}
