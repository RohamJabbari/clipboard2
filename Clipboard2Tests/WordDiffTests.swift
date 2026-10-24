import Testing
import Foundation
@testable import Clipboard2

struct WordDiffTests {
    @Test func showsEachFixedWord() {
        let parts = WordDiff.diff("Their going to finish the panel design tomorow.",
                                  "They’re going to finish the panel design tomorrow.")
        #expect(parts == [
            .removed("Their"), .added("They’re"),
            .same(" going to finish the panel design "),
            .removed("tomorow"), .added("tomorrow"),
            .same("."),
        ])
        #expect(WordDiff.changeCount(parts) == 2)
    }

    @Test func identicalTextHasNoChanges() {
        let parts = WordDiff.diff("Nothing to fix here.", "Nothing to fix here.")
        #expect(parts == [.same("Nothing to fix here.")])
        #expect(WordDiff.changeCount(parts) == 0)
    }

    @Test func insertionsAndDeletions() {
        #expect(WordDiff.diff("see you", "see you soon") == [.same("see you"), .added(" soon")])
        #expect(WordDiff.diff("a very big deal", "a big deal") == [.same("a "), .removed("very "), .same("big deal")])
    }

    @Test func apostrophesStayInsideWords() {
        #expect(WordDiff.tokens("don't stop") == ["don't", " ", "stop"])
        #expect(WordDiff.tokens("’quoted’") == ["’", "quoted", "’"])
    }
}
