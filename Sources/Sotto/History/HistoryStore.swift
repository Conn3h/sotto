import Foundation
import Observation

/// The UI's view of `HistoryLog`: newest run first. `HistoryLog` reloads it after every
/// write, so a panel only ever reads `runs`.
@MainActor
@Observable
final class HistoryStore {
    static let shared = HistoryStore()

    /// Newest first.
    private(set) var runs: [DictationRun] = []

    init() {
        reload()
    }

    func reload() {
        runs = HistoryLog.load().reversed()
        Log.history.debug("history store reloaded: \(self.runs.count, privacy: .public) runs")
    }
}
