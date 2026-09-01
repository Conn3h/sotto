import Foundation
import Observation
import SottoDictionary

/// The personal dictionary in memory, backed by `dictionary.txt`. Every edit saves the whole
/// file atomically. There is no live file watcher in v1 (spec 6.12): `reloadFromDisk()` is
/// called when the app becomes active and from the "Reload Dictionary" menu item.
@MainActor
@Observable
final class DictionaryStore {
    /// Size and modification date at the last load or save. A reload whose stamp matches
    /// is skipped without reading the file.
    private struct FileStamp {
        /// Modification dates round-trip through the file system with sub-microsecond
        /// noise; anything closer than this is the same write.
        static let dateTolerance: TimeInterval = 0.001

        let size: UInt64
        let modified: Date

        func matches(_ other: FileStamp) -> Bool {
            size == other.size && abs(modified.timeIntervalSince(other.modified)) < Self.dateTolerance
        }
    }

    static let shared = DictionaryStore(fileURL: fileURL)

    /// App Support/Sotto/dictionary.txt
    static var fileURL: URL {
        AppSupportDirectory.url.appending(path: "dictionary.txt")
    }

    private(set) var entries: [DictionaryEntry] = []
    /// Bumps on every change to `entries`.
    private(set) var revision = 0
    /// How many times the file has been read. Exposed so tests can see a skipped reload.
    @ObservationIgnored private(set) var diskReadCount = 0

    @ObservationIgnored private let location: URL
    @ObservationIgnored private var lastStamp: FileStamp?

    /// `shared` uses `fileURL`; tests pass a file in a temporary directory.
    init(fileURL: URL) {
        location = fileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            lastStamp = stamp()
            if let loaded = read() {
                entries = loaded
            }
            Log.dictionary.info("dictionary loaded: \(self.entries.count, privacy: .public) entries")
        } else {
            // Write the header now so "Reveal Dictionary File" has a file to show and a
            // hand edit has a format to follow.
            Log.dictionary.info("no dictionary file yet; creating an empty one")
            save()
        }
    }

    // MARK: Edits

    func add(_ entry: DictionaryEntry) {
        entries = entries + [entry]
        commit("added a \(entry.kind.rawValue)")
    }

    /// Matched by id; an unknown id is a logged no-op.
    func update(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            Log.dictionary.error("update ignored: no entry with id \(entry.id.uuidString, privacy: .public)")
            return
        }
        var updated = entries
        updated[index] = entry
        entries = updated
        commit("updated a \(entry.kind.rawValue)")
    }

    /// An unknown id is a logged no-op.
    func delete(id: UUID) {
        guard entries.contains(where: { $0.id == id }) else {
            Log.dictionary.error("delete ignored: no entry with id \(id.uuidString, privacy: .public)")
            return
        }
        entries = entries.filter { $0.id != id }
        commit("deleted 1 entry")
    }

    func delete(ids: Set<UUID>) {
        let remaining = entries.filter { !ids.contains($0.id) }
        let removed = entries.count - remaining.count
        guard removed > 0 else {
            Log.dictionary.error("delete ignored: none of \(ids.count, privacy: .public) ids found")
            return
        }
        entries = remaining
        commit("deleted \(removed) entries")
    }

    private func commit(_ what: String) {
        revision += 1
        Log.dictionary.info(
            "dictionary \(what, privacy: .public); \(self.entries.count, privacy: .public) entries, revision \(self.revision, privacy: .public)"
        )
        save()
    }

    // MARK: Reload

    /// Re-reads the file unless its size and modification date match the last load or
    /// save. Ids survive for entries whose (kind, hear, write) triple is already in memory;
    /// new lines get fresh ids. `revision` bumps only when the entry list actually changed.
    func reloadFromDisk() {
        guard let current = stamp() else {
            Log.dictionary.error(
                "dictionary reload skipped: file missing or unreadable; keeping \(self.entries.count, privacy: .public) entries in memory"
            )
            return
        }
        if let lastStamp, lastStamp.matches(current) {
            Log.dictionary.debug("dictionary reload skipped: file unchanged")
            return
        }
        guard let parsed = read() else {
            return
        }
        lastStamp = current
        let merged = Self.preservingIds(from: entries, in: parsed)
        guard merged != entries else {
            Log.dictionary.info("dictionary reloaded: no changes")
            return
        }
        entries = merged
        revision += 1
        Log.dictionary.info(
            "dictionary reloaded: \(merged.count, privacy: .public) entries, revision \(self.revision, privacy: .public)"
        )
    }

    /// Each parsed entry takes the id of the first still-unclaimed in-memory entry with
    /// the same (kind, hear, write); the rest keep the fresh ids `DictionaryFile` minted.
    /// Claiming keeps duplicate lines from sharing one id.
    private static func preservingIds(
        from existing: [DictionaryEntry],
        in parsed: [DictionaryEntry]
    ) -> [DictionaryEntry] {
        var unclaimed = existing
        return parsed.map { entry in
            guard let index = unclaimed.firstIndex(where: {
                $0.kind == entry.kind && $0.hear == entry.hear && $0.write == entry.write
            }) else {
                return entry
            }
            let match = unclaimed.remove(at: index)
            return DictionaryEntry(
                id: match.id,
                kind: entry.kind,
                write: entry.write,
                hear: entry.hear,
                isEnabled: entry.isEnabled
            )
        }
    }

    // MARK: Queries

    /// `localizedStandardContains` on both sides; a blank query returns everything.
    func filtered(by query: String) -> [DictionaryEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return entries
        }
        return entries.filter {
            $0.write.localizedStandardContains(needle) || $0.hear.localizedStandardContains(needle)
        }
    }

    /// Rebuilt on demand; cheap.
    var corrector: DictionaryCorrector {
        DictionaryCorrector(entries: entries)
    }

    var biasPhrases: [String] {
        DictionaryCorrector.biasPhrases(from: entries)
    }

    // MARK: File access

    private func read() -> [DictionaryEntry]? {
        diskReadCount += 1
        do {
            let text = try String(contentsOf: location, encoding: .utf8)
            return DictionaryFile.parse(text)
        } catch {
            Log.dictionary.error("dictionary read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A failed save is an error: the UI shows an entry that will be gone on relaunch.
    private func save() {
        let text = DictionaryFile.serialize(entries)
        do {
            try AppSupportDirectory.ensureExists(location.deletingLastPathComponent())
            try text.write(to: location, atomically: true, encoding: .utf8)
            lastStamp = stamp()
            Log.dictionary.info("dictionary saved: \(self.entries.count, privacy: .public) entries")
        } catch {
            Log.dictionary.error(
                "dictionary save failed, \(self.entries.count, privacy: .public) entries will be gone on relaunch: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func stamp() -> FileStamp? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard let size = (attributes[.size] as? NSNumber)?.uint64Value,
                  let modified = attributes[.modificationDate] as? Date
            else {
                Log.dictionary.error("dictionary file attributes are missing size or modification date")
                return nil
            }
            return FileStamp(size: size, modified: modified)
        } catch {
            Log.dictionary.error("dictionary file attributes unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
