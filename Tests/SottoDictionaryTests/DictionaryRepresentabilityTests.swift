import Testing
@testable import SottoDictionary

@Suite struct DictionaryRepresentabilityTests {
    @Test func validTermAndCorrectionHaveNoIssues() {
        #expect(DictionaryFile.representabilityIssues(for: .term("Supabase")).isEmpty)
        #expect(DictionaryFile.representabilityIssues(for: .correction(hear: "super base", write: "Supabase")).isEmpty)
    }

    @Test func blankWriteIsRefused() {
        #expect(DictionaryFile.representabilityIssues(for: .term("   ")) == [.blankWrite])
    }

    @Test func correctionWithBlankHearIsRefused() {
        #expect(DictionaryFile.representabilityIssues(for: .correction(hear: " ", write: "Sotto")) == [.blankHear])
    }

    @Test func termsIgnoreHear() {
        let entry = DictionaryEntry(kind: .term, write: "Sotto", hear: "# -> whatever")
        #expect(DictionaryFile.representabilityIssues(for: entry).isEmpty)
    }

    @Test func commentPrefixIsRefusedOnEitherSide() {
        #expect(DictionaryFile.representabilityIssues(for: .term("#tag")) == [.commentPrefix])
        #expect(DictionaryFile.representabilityIssues(for: .correction(hear: "# off", write: "x")) == [.commentPrefix])
    }

    @Test func arrowIsRefusedOnEitherSide() {
        #expect(DictionaryFile.representabilityIssues(for: .term("a -> b")) == [.containsArrow])
        #expect(DictionaryFile.representabilityIssues(for: .correction(hear: "x", write: "y -> z")) == [.containsArrow])
    }

    @Test func issuesAccumulate() {
        let issues = DictionaryFile.representabilityIssues(for: .correction(hear: "", write: "#a -> b"))
        #expect(issues == [.blankHear, .commentPrefix, .containsArrow])
    }

    @Test func everyIssueHasAMessage() {
        for issue in DictionaryRepresentabilityIssue.allCases {
            #expect(!issue.message.isEmpty)
        }
    }
}
