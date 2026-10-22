import Foundation
import MouseRecorderCore

enum AppIdentity {
    static let displayName = "Cursor Replay CLI"
    static let command = "cursor-replay"
    static let version = "0.2.0"

    static func recordingsDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        if let override = environment["CURSOR_REPLAY_DATA_DIR"] {
            guard !override.isEmpty, override.hasPrefix("/") else {
                throw MouseRecorderError("CURSOR_REPLAY_DATA_DIR must be a nonempty absolute directory path.")
            }
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("recordings", isDirectory: true)
        }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        return support.appendingPathComponent(displayName, isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
    }
}
