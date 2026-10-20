import Testing
@testable import MouseRecorderCLI

struct AppIdentityTests {
    @Test func explicitDataDirectoryKeepsRecordingsTogether() throws {
        let path = try AppIdentity.recordingsDirectory(
            environment: ["CURSOR_REPLAY_DATA_DIR": "/tmp/cursor-replay-test/"]
        )
        #expect(path.path == "/tmp/cursor-replay-test/recordings")
    }

    @Test func invalidDataDirectoryDoesNotSilentlyFallBack() {
        for path in ["", "relative/path"] {
            #expect(throws: (any Error).self) {
                try AppIdentity.recordingsDirectory(environment: ["CURSOR_REPLAY_DATA_DIR": path])
            }
        }
    }
}
