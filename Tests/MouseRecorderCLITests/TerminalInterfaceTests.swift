import Foundation
import Testing
@testable import MouseRecorderCLI

struct TerminalInterfaceTests {
    @Test func arrowsDecodeWithoutLeakingEscapeOrShortcutCharacters() {
        var decoder = TerminalKeyDecoder()
        let bytes: [UInt8] = [
            27, 91, 65, 27, 91, 66,
            27, 79, 65, 27, 79, 66,
            27, 91, 49, 59, 53, 65,
            27, 79, 83, 27, 91, 49, 50, 126,
            112, 76, 115, 81
        ]
        let keys = bytes.compactMap { decoder.consume($0) }
        #expect(keys == [.up, .down, .up, .down, .up, .character(112), .character(76), .character(115), .character(81)])
    }

    @Test func fragmentedArrowSequencesAndStandaloneEscapeRemainDistinct() {
        var decoder = TerminalKeyDecoder()
        #expect(decoder.consume(27) == nil)
        #expect(decoder.consume(91) == nil)
        #expect(decoder.finishEscape() == nil)
        #expect(decoder.consume(66) == .down)
        #expect(decoder.consume(27) == nil)
        #expect(decoder.finishEscape() == .character(27))
        #expect(decoder.consume(80) == .character(80))
    }

    @Test func backspaceAndForwardDeleteDecodeWithoutConfusingOtherTildeKeys() {
        var decoder = TerminalKeyDecoder()
        let bytes: [UInt8] = [
            8, 127, 27, 91, 51, 126,
            27, 91, 49, 50, 126,
            27, 91, 51, 49, 126,
            27, 91, 65, 121, 110
        ]
        #expect(bytes.compactMap { decoder.consume($0) } == [
            .delete, .delete, .delete, .up, .character(121), .character(110)
        ])
    }

    @Test func libraryFindsAllRecordingsNewestFirstAndPreservesSelection() throws {
        try withTemporaryDirectory { root in
            let directory = root.appendingPathComponent("private/recordings")
            let working = root.appendingPathComponent("working")
            let legacy = working.appendingPathComponent("recordings")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            let newest = try write("newest.json", in: directory, modifiedAt: 4)
            let oldest = try write("oldest.json", in: legacy, modifiedAt: 1)
            let direct = try write("recording.json", in: working, modifiedAt: 3)
            let movement = try write("movement.json", in: working, modifiedAt: 2)
            _ = try write("ignored.verification.json", in: directory, modifiedAt: 10)
            _ = try write(".hidden.json", in: directory, modifiedAt: 10)
            _ = try write("notes.txt", in: directory, modifiedAt: 10)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.json"), withIntermediateDirectories: false)

            var library = try RecordingLibrary(in: directory, workingDirectory: working)
            #expect(library.recordings == [newest, direct, movement, oldest])
            #expect(library.selectedURL == newest)
            library.moveSelection(-1)
            #expect(library.selectedIndex == 0)
            library.moveSelection(1)
            #expect(library.selectedURL == direct)
            library.moveSelection(1)
            library.moveSelection(1)
            library.moveSelection(1)
            #expect(library.selectedURL == oldest)
            library.moveSelection(-1)
            #expect(library.selectedURL == movement)

            let saved = try write("just-saved.json", in: directory, modifiedAt: 5)
            library = try RecordingLibrary(in: directory, workingDirectory: working, selecting: library.selectedURL)
            #expect(library.selectedURL == movement)
            #expect(library.selectedIndex == 3)
            library = try RecordingLibrary(in: directory, workingDirectory: working, selecting: saved)
            #expect(library.selectedURL == saved)
            #expect(library.selectedIndex == 0)
        }
    }

    @Test func overlappingDiscoveryIsDeduplicatedWithStableDateTies() throws {
        try withTemporaryDirectory { root in
            let recording = try write("recording.json", in: root, modifiedAt: 1)
            let movement = try write("movement.json", in: root, modifiedAt: 1)
            let library = try RecordingLibrary(in: root, workingDirectory: root)
            #expect(library.recordings == [movement, recording])
        }
    }

    @Test func emptyLibraryCanBeNavigatedWithoutASelection() throws {
        try withTemporaryDirectory { root in
            var library = try RecordingLibrary(in: root.appendingPathComponent("missing"), workingDirectory: root)
            library.moveSelection(1)
            library.moveSelection(-1)
            #expect(library.recordings.isEmpty)
            #expect(library.selectedURL == nil)
            #expect(library.selectedIndex == nil)
        }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-replay-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record(error) }
        }
        try body(root)
    }

    private func write(_ name: String, in directory: URL, modifiedAt time: TimeInterval) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path)
        return url.standardizedFileURL
    }
}
