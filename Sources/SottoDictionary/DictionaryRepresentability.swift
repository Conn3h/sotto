import Foundation

/// A reason an entry cannot survive a round trip through the dictionary file.
///
/// The file format has no escaping: a line starting with `#` is a comment and the first
/// `->` on a line is structural. An entry that would be misread on reload must be refused
/// before it is saved, with a message the UI can show.
public enum DictionaryRepresentabilityIssue: Sendable, Equatable, CaseIterable {
    case blankWrite
    case blankHear
    case commentPrefix
    case containsArrow

    public var message: String {
        switch self {
        case .blankWrite: "The text to write cannot be empty."
        case .blankHear: "A correction needs the text the engine tends to hear."
        case .commentPrefix: "An entry cannot start with #, which marks a comment in the dictionary file."
        case .containsArrow: "An entry cannot contain ->, which separates hear from write in the dictionary file."
        }
    }
}

public extension DictionaryFile {
    /// Every issue that would make `entry` unrepresentable in the file. Empty means safe.
    static func representabilityIssues(for entry: DictionaryEntry) -> [DictionaryRepresentabilityIssue] {
        let write = entry.write.trimmingCharacters(in: .whitespacesAndNewlines)
        let hear = entry.hear.trimmingCharacters(in: .whitespacesAndNewlines)
        var issues: [DictionaryRepresentabilityIssue] = []

        if write.isEmpty {
            issues.append(.blankWrite)
        }
        if entry.kind == .correction, hear.isEmpty {
            issues.append(.blankHear)
        }
        if write.hasPrefix("#") || (entry.kind == .correction && hear.hasPrefix("#")) {
            issues.append(.commentPrefix)
        }
        if write.contains("->") || (entry.kind == .correction && hear.contains("->")) {
            issues.append(.containsArrow)
        }
        return issues
    }
}
