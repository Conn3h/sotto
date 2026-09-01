import Foundation

/// `~/Library/Application Support/Sotto/`, home of `dictionary.txt` and `history.jsonl`.
enum AppSupportDirectory {
    static let url = URL.applicationSupportDirectory.appending(path: "Sotto", directoryHint: .isDirectory)

    /// Creates `directory` (and any missing parents) if it does not exist yet. Callers log
    /// the thrown error together with what they were trying to write.
    static func ensureExists(_ directory: URL = url) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
