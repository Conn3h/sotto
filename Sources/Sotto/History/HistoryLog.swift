import Foundation

/// `history.jsonl`: one JSON object per line, appended per run, rewritten whole on delete
/// or clear. Dates are ISO-8601 with fractional seconds.
@MainActor
enum HistoryLog {
    private static let fileName = "history.jsonl"
    private static let newline = Data([UInt8(ascii: "\n")])

    nonisolated private static let fractionalDate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    nonisolated private static let wholeSecondDate = Date.ISO8601FormatStyle()

    /// Tests point the log at a temporary directory.
    static var directoryOverride: URL?

    static var directoryURL: URL {
        directoryOverride ?? AppSupportDirectory.url
    }

    /// App Support/Sotto/history.jsonl
    static var fileURL: URL {
        directoryURL.appending(path: fileName)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalDate.format(date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            // Lines written before fractional seconds were used still decode.
            let style = string.contains(".") ? fractionalDate : wholeSecondDate
            return try style.parse(string)
        }
        return decoder
    }()

    // MARK: Writes

    /// Appends one line, then reloads `HistoryStore`.
    static func record(_ run: DictationRun) {
        do {
            let data = try encoder.encode(run)
            try AppSupportDirectory.ensureExists(directoryURL)
            try append(data + newline)
            Log.history.info(
                "recorded run \(run.id.uuidString, privacy: .public): \(run.text.count, privacy: .public) chars, source \(run.source, privacy: .public), \(run.corrections?.count ?? 0, privacy: .public) corrections"
            )
        } catch {
            Log.history.error(
                "record failed for run \(run.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        HistoryStore.shared.reload()
    }

    /// Rewrites the file without the given runs, then reloads `HistoryStore`.
    static func delete(ids: Set<UUID>) {
        let report = loadReport()
        let remaining = report.runs.filter { !ids.contains($0.id) }
        rewrite(remaining, reason: "deleted \(report.runs.count - remaining.count) of \(report.runs.count)")
        HistoryStore.shared.reload()
    }

    /// Rewrites the file empty, then reloads `HistoryStore`.
    static func clear() {
        rewrite([], reason: "cleared")
        HistoryStore.shared.reload()
    }

    // MARK: Reads

    /// The runs in file order. Undecodable lines are skipped and counted in the log.
    static func load() -> [DictationRun] {
        loadReport().runs
    }

    /// A decoded line plus whether it carried an id. A run without one gets a fresh id, and
    /// the file is rewritten right away so the id stays stable across loads (otherwise a
    /// later `delete(ids:)`, which re-reads the file, could never match it).
    private struct StoredRun: Decodable {
        private enum IDKey: String, CodingKey {
            case id
        }

        let run: DictationRun
        let hadID: Bool

        init(from decoder: any Decoder) throws {
            run = try DictationRun(from: decoder)
            hadID = try decoder.container(keyedBy: IDKey.self).contains(.id)
        }
    }

    /// The runs in file order plus how many lines could not be decoded. Blank lines are
    /// neither runs nor skips.
    static func loadReport() -> (runs: [DictationRun], skipped: Int) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ([], 0)
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            Log.history.error("history read failed: \(error.localizedDescription, privacy: .public)")
            return ([], 0)
        }

        var runs: [DictationRun] = []
        var skipped = 0
        var minted = 0
        for line in data.split(separator: UInt8(ascii: "\n")) where !isBlank(line) {
            do {
                let stored = try decoder.decode(StoredRun.self, from: Data(line))
                runs.append(stored.run)
                if !stored.hadID {
                    minted += 1
                }
            } catch {
                skipped += 1
                Log.history.debug("history line skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
        if skipped > 0 {
            Log.history.error(
                "history load skipped \(skipped, privacy: .public) undecodable lines; \(runs.count, privacy: .public) runs loaded"
            )
        }
        if minted > 0 {
            rewrite(runs, reason: "assigned \(minted) missing ids")
        }
        return (runs, skipped)
    }

    private static func isBlank(_ line: Data) -> Bool {
        line.allSatisfy { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") || $0 == UInt8(ascii: "\r") }
    }

    // MARK: File access

    private static func append(_ data: Data) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try data.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private static func rewrite(_ runs: [DictationRun], reason: String) {
        do {
            var data = Data()
            for run in runs {
                data.append(try encoder.encode(run))
                data.append(newline)
            }
            try AppSupportDirectory.ensureExists(directoryURL)
            try data.write(to: fileURL, options: .atomic)
            Log.history.info("history rewritten (\(reason, privacy: .public)): \(runs.count, privacy: .public) runs kept")
        } catch {
            Log.history.error(
                "history rewrite failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
