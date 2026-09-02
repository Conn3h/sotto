import SottoDictionary
import SwiftUI

/// The Dictionary tab (spec §6.14): search, an add row with inline `DictionaryWarning`
/// messages, and editable rows for every entry.
@MainActor
struct DictionaryPanel: View {
    @State private var query = ""

    private var filtered: [DictionaryEntry] {
        DictionaryStore.shared.filtered(by: query)
    }

    var body: some View {
        VStack(spacing: DS.Space.none) {
            SearchField(text: $query, placeholder: "Search dictionary")
                .padding(.horizontal, DS.Space.roomy)
                .padding(.top, DS.Space.base)
                .padding(.bottom, DS.Space.snug)

            AddEntryRow()
                .padding(.horizontal, DS.Space.roomy)
                .padding(.bottom, DS.Space.roomy)

            if filtered.isEmpty {
                EmptyStateView(
                    systemImage: "book",
                    title: query.isEmpty ? "No entries yet" : "No matches",
                    message: query.isEmpty
                        ? "Add a term the engine should know, or a correction for something it mishears."
                        : "Try a different search."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.snug) {
                        ForEach(filtered) { entry in
                            DictionaryRow(entry: entry)
                        }
                    }
                    .padding(.horizontal, DS.Space.roomy)
                    .padding(.bottom, DS.Space.roomy)
                }
            }
        }
    }
}

/// The `DictionaryFile.representabilityIssues` messages for a draft entry. Unlike
/// `DictionaryWarning` (advisory, never blocks), an issue means the file format cannot
/// round-trip this entry, so it is shown with a glyph and full-contrast `DS.Color.ink`
/// rather than the warnings' plain, secondary-ink text — visually distinct, and blocking.
@MainActor
private struct RepresentabilityIssueList: View {
    let issues: [DictionaryRepresentabilityIssue]

    var body: some View {
        ForEach(issues.indices, id: \.self) { index in
            HStack(alignment: .top, spacing: DS.Space.tight) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(DS.Color.ink)
                Text(issues[index].message)
                    .foregroundStyle(DS.Color.ink)
            }
            .font(DS.Font.caption)
        }
    }
}

/// Composes a new entry: a term/correction kind toggle, the hear/write fields (hear hidden
/// for terms), inline representability issues and warnings for the entry as typed, and Add.
@MainActor
private struct AddEntryRow: View {
    private static let kinds: [DictionaryEntry.Kind] = [.term, .correction]

    @State private var kind: DictionaryEntry.Kind = .term
    @State private var hear = ""
    @State private var write = ""

    private var draftEntry: DictionaryEntry {
        DictionaryEntry(kind: kind, write: write, hear: hear)
    }

    private var warnings: [DictionaryWarning] {
        DictionaryWarning.check(draftEntry)
    }

    private var issues: [DictionaryRepresentabilityIssue] {
        DictionaryFile.representabilityIssues(for: draftEntry)
    }

    private var trimmedWrite: String {
        write.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedHear: String {
        hear.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        issues.isEmpty && !DictionaryStore.shared.loadFailed
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: DS.Space.base) {
                SectionHeader(title: "Add to dictionary")

                SegmentedChoice(options: Self.kinds, selection: $kind) { option in
                    option == .term ? "Term" : "Correction"
                }

                if kind == .correction {
                    field("Hear (what the engine mishears)", text: $hear)
                }
                field(kind == .term ? "Term" : "Write (what it should say)", text: $write)

                RepresentabilityIssueList(issues: issues)

                if DictionaryStore.shared.loadFailed {
                    Text(Self.loadFailedMessage)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.ink)
                }

                ForEach(warnings) { warning in
                    Text(warning.message)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                }

                Button("Add") {
                    DictionaryStore.shared.add(DictionaryEntry(kind: kind, write: trimmedWrite, hear: trimmedHear))
                    write = ""
                    hear = ""
                }
                .disabled(!canAdd)
            }
        }
    }

    static let loadFailedMessage =
        "The dictionary file could not be read, so edits are paused. Choose File > Reload Dictionary once it is readable."

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(DS.Font.body)
            .foregroundStyle(DS.Color.ink)
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.panelRaised))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .stroke(DS.Color.hairline, lineWidth: DS.Border.hairline)
            )
    }
}

/// One entry: an enable toggle, the term or "heard → written" text (inline-editable), and
/// delete.
///
/// `draftWrite`/`draftHear` are refreshed from `entry` every time Edit begins (not only at
/// `init`), so a hand edit to the dictionary file that `reloadFromDisk()` picks up under a
/// preserved id is never overwritten by a draft left over from before the reload.
@MainActor
private struct DictionaryRow: View {
    let entry: DictionaryEntry

    @State private var isEditing = false
    @State private var draftWrite: String
    @State private var draftHear: String

    private var draftEntry: DictionaryEntry {
        var updated = entry
        updated.write = draftWrite
        updated.hear = draftHear
        return updated
    }

    private var issues: [DictionaryRepresentabilityIssue] {
        DictionaryFile.representabilityIssues(for: draftEntry)
    }

    init(entry: DictionaryEntry) {
        self.entry = entry
        _draftWrite = State(initialValue: entry.write)
        _draftHear = State(initialValue: entry.hear)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.base) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { newValue in
                    var updated = entry
                    updated.isEnabled = newValue
                    DictionaryStore.shared.update(updated)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(DS.Color.ink)
            .accessibilityLabel(entry.isEnabled ? "Disable entry" : "Enable entry")

            content

            Spacer(minLength: DS.Space.none)

            if !isEditing {
                Button {
                    draftWrite = entry.write
                    draftHear = entry.hear
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit entry")
            }

            Button {
                DictionaryStore.shared.delete(id: entry.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete entry")
        }
        .padding(DS.Space.base)
        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.panelRaised))
        .opacity(entry.isEnabled ? 1 : DS.Metric.disabledEntryOpacity)
    }

    @ViewBuilder
    private var content: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                if entry.kind == .correction {
                    TextField("Hear", text: $draftHear)
                        .textFieldStyle(.plain)
                        .font(DS.Font.body)
                }
                TextField("Write", text: $draftWrite)
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)

                RepresentabilityIssueList(issues: issues)

                HStack(spacing: DS.Space.snug) {
                    Button("Save") {
                        var updated = entry
                        updated.write = draftWrite.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.hear = draftHear.trimmingCharacters(in: .whitespacesAndNewlines)
                        DictionaryStore.shared.update(updated)
                        isEditing = false
                    }
                    .disabled(!issues.isEmpty || DictionaryStore.shared.loadFailed)
                    Button("Cancel") {
                        draftWrite = entry.write
                        draftHear = entry.hear
                        isEditing = false
                    }
                }
                .font(DS.Font.caption)
            }
        } else if entry.kind == .correction {
            HStack(spacing: DS.Space.tight) {
                Text(entry.hear).strikethrough().foregroundStyle(DS.Color.inkSecondary)
                Image(systemName: "arrow.right").foregroundStyle(DS.Color.inkTertiary)
                Text(entry.write).foregroundStyle(DS.Color.ink)
            }
            .font(DS.Font.body)
        } else {
            Text(entry.write)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
        }
    }
}
