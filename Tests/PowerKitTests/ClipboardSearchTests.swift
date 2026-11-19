import XCTest
@testable import PowerKit

/// Searching the Clipboard History, and the "5 min ago" under each row.
final class ClipboardSearchTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// An entry as the list holds it, made directly: no store and no disk, because the search reads nothing else.
    private func entry(_ text: String, kind: ClipboardKind = .text, app: String? = nil, preview: String? = nil,
                       minutesAgo: Double = 0, pinned: Bool = false) -> ClipboardEntry {
        ClipboardEntry(id: UUID(), kind: kind, text: text, preview: preview ?? text, detail: nil, parts: [],
                       date: base.addingTimeInterval(-minutesAgo * 60), pinned: pinned, sourceBundleID: nil, sourceName: app,
                       byteSize: text.utf8.count, fingerprint: UUID().uuidString)
    }

    private func found(_ entries: [ClipboardEntry], _ query: String) -> [String] {
        ClipboardSearch.results(entries, query: query).map(\.text)
    }

    // ── Searching ───────────────────────────────────────────────────────────

    /// With nothing typed the list is everything: what is pinned first, and each group newest first.
    func testAnEmptyQueryListsPinnedFirstThenNewest() {
        let entries = [
            entry("old", minutesAgo: 50),
            entry("new", minutesAgo: 5),
            entry("pinned recent", minutesAgo: 20, pinned: true),
            entry("pinned old", minutesAgo: 90, pinned: true),
            entry("middle", minutesAgo: 25),
        ]
        XCTAssertEqual(found(entries, ""), ["pinned recent", "pinned old", "new", "middle", "old"])
        XCTAssertEqual(found([], ""), [])
    }

    /// Spaces typed and nothing else are nothing typed.
    func testAQueryOfOnlySpacesIsAnEmptyQuery() {
        let entries = [entry("first", minutesAgo: 10), entry("second", minutesAgo: 1), entry("third", minutesAgo: 5, pinned: true)]
        XCTAssertEqual(found(entries, "   "), found(entries, ""))
        XCTAssertEqual(found(entries, " \t "), ["third", "second", "first"])
    }

    /// Each word has to be there, in any order and anywhere in the text: an entry that has some of them is not a match.
    func testEveryWordOfTheQueryMustMatch() {
        let entries = [
            entry("meeting notes for monday", app: "Calendar", minutesAgo: 1),
            entry("meeting agenda", app: "Mail", minutesAgo: 2),
            entry("shopping list", app: "Reminders", minutesAgo: 3),
        ]
        XCTAssertEqual(found(entries, "meeting notes"), ["meeting notes for monday"])
        XCTAssertEqual(found(entries, "notes meeting"), ["meeting notes for monday"], "the order of the words is nobody's business")
        XCTAssertEqual(found(entries, "meeting"), ["meeting notes for monday", "meeting agenda"])
        XCTAssertEqual(found(entries, "meeting shopping"), [])
        XCTAssertEqual(found(entries, "  meeting   monday  "), ["meeting notes for monday"], "extra spaces make no difference")
    }

    /// The app a copy came from is searched too, so "mail" finds what was copied in Mail.
    func testTheNameOfTheAppItCameFromCounts() {
        let entries = [
            entry("meeting agenda", app: "Mail", minutesAgo: 2),
            entry("shopping list", app: "Reminders", minutesAgo: 1),
        ]
        XCTAssertEqual(found(entries, "mail"), ["meeting agenda"])
        XCTAssertEqual(found(entries, "agenda mail"), ["meeting agenda"], "a word of the text and a word of the app")
        XCTAssertEqual(found(entries, "reminders list"), ["shopping list"])
        XCTAssertEqual(found(entries, "mail list"), [])
    }

    /// The kind is a word of the entry: "link" finds links though the link itself does not say so.
    func testTheKindOfTheEntryIsAWordToSearchFor() {
        let entries = [
            entry("https://example.org/page", kind: .link, minutesAgo: 4),
            entry("Image", kind: .image, minutesAgo: 3),
            entry("/Users/example/budget.xlsx", kind: .file, preview: "budget.xlsx", minutesAgo: 2),
            entry("plain words", kind: .text, minutesAgo: 1),
        ]
        XCTAssertEqual(found(entries, "link"), ["https://example.org/page"])
        XCTAssertEqual(found(entries, "image"), ["Image"])
        XCTAssertEqual(found(entries, "file"), ["/Users/example/budget.xlsx"])
        XCTAssertEqual(found(entries, "link example"), ["https://example.org/page"], "the kind and a word of the text together")
    }

    /// Capital letters make no difference, in the text, the app or the query.
    func testCaseDoesNotMatter() {
        let entries = [entry("Hello World", app: "TextEdit")]
        XCTAssertEqual(found(entries, "hello"), ["Hello World"])
        XCTAssertEqual(found(entries, "HELLO wORLD"), ["Hello World"])
        XCTAssertEqual(found(entries, "textedit"), ["Hello World"])
        XCTAssertEqual(found([entry("hello world")], "HELLO"), ["hello world"])
    }

    /// Accents make no difference either way: a search without them finds a word that has them, and the other way round.
    func testAccentsDoNotMatter() {
        let entries = [entry("Caf\u{00E9} au lait", minutesAgo: 2), entry("cafe racer", minutesAgo: 1), entry("na\u{00EF}ve idea", app: "Messages")]
        XCTAssertEqual(Set(found(entries, "cafe")), ["Caf\u{00E9} au lait", "cafe racer"])
        XCTAssertEqual(Set(found(entries, "caf\u{00E9}")), ["Caf\u{00E9} au lait", "cafe racer"])
        XCTAssertEqual(Set(found(entries, "CAF\u{00C9}")), ["Caf\u{00E9} au lait", "cafe racer"])
        XCTAssertEqual(found([entry("hello", app: "\u{00C9}cran")], "ecran"), ["hello"], "in the app's name too")
        XCTAssertEqual(found([entry("r\u{00E9}sum\u{00E9} draft")], "resume"), ["r\u{00E9}sum\u{00E9} draft"])
        XCTAssertEqual(found([entry("a na\u{00EF}ve idea")], "naive"), ["a na\u{00EF}ve idea"])
    }

    // ── Ranking ─────────────────────────────────────────────────────────────

    /// The start of the text outranks the start of a word, which outranks the middle of one, whatever the dates: the newest
    /// of the three is the weakest match here and comes last.
    func testAPrefixOfTheTextOutranksAWordPrefixOutranksASubstring() {
        let entries = [
            entry("login page", minutesAgo: 30),
            entry("see the log file", minutesAgo: 20),
            entry("catalog", minutesAgo: 1),
        ]
        XCTAssertEqual(found(entries, "log"), ["login page", "see the log file", "catalog"])
        XCTAssertEqual(found(Array(entries.reversed()), "log"), ["login page", "see the log file", "catalog"], "the order of the list does not matter")
    }

    /// A word that starts a later line is the start of a word too.
    func testAWordThatStartsALaterLineCountsAsTheStartOfAWord() {
        let entries = [entry("alpha\nlog entry", minutesAgo: 10), entry("catalog", minutesAgo: 1)]
        XCTAssertEqual(found(entries, "log"), ["alpha\nlog entry", "catalog"])
    }

    /// The same match twice: the newer copy first.
    func testTiesGoToTheNewer() {
        let entries = [
            entry("log one", minutesAgo: 30),
            entry("log three", minutesAgo: 1),
            entry("log two", minutesAgo: 10),
        ]
        XCTAssertEqual(found(entries, "log"), ["log three", "log two", "log one"])
    }

    /// Every word adds to the score: the entry that starts with the words beats one that only has them inside.
    func testMoreOfTheQueryAtTheStartOfWordsRanksHigher() {
        let entries = [entry("a red car", minutesAgo: 1), entry("red car", minutesAgo: 30)]
        XCTAssertEqual(found(entries, "red car"), ["red car", "a red car"])
    }

    /// A pin is a small lift: it wins a tie with a newer copy, but does not beat a better match.
    func testAPinnedEntryWinsATieButNotABetterMatch() {
        let tie = [entry("see the log again", minutesAgo: 1), entry("see the log", minutesAgo: 60, pinned: true)]
        XCTAssertEqual(found(tie, "log"), ["see the log", "see the log again"])

        let better = [entry("login page", minutesAgo: 30), entry("catalog", minutesAgo: 1, pinned: true)]
        XCTAssertEqual(found(better, "log"), ["login page", "catalog"])
    }

    // ── No match, and no text ───────────────────────────────────────────────

    /// A word that is nowhere gives an empty list, not the nearest thing.
    func testNothingMatchingGivesNothing() {
        let entries = [entry("meeting notes", app: "Notes"), entry("shopping list", kind: .text), entry("https://example.org", kind: .link)]
        XCTAssertEqual(found(entries, "zzzz"), [])
        XCTAssertEqual(found(entries, "meeting zzzz"), [], "one word that is nowhere is enough")
        XCTAssertEqual(found([], "anything"), [])
    }

    /// An entry that keeps no text (formatted text, a picture) is found by what its row says.
    func testAnEntryWithNoTextIsFoundByItsPreview() {
        let formatted = entry("", preview: "Formatted text", minutesAgo: 2)
        let other = entry("plain words", minutesAgo: 1)
        XCTAssertEqual(ClipboardSearch.results([formatted, other], query: "formatted").map(\.preview), ["Formatted text"])
    }

    // ── How long ago ────────────────────────────────────────────────────────

    private func ago(_ seconds: TimeInterval) -> String {
        ClipboardSearch.ago(from: base.addingTimeInterval(-seconds), to: base)
    }

    /// A copy made this minute has nothing better to say than "now".
    func testUnderAMinuteIsNow() {
        XCTAssertEqual(ago(0), "now")
        XCTAssertEqual(ago(5), "now")
        XCTAssertEqual(ago(59), "now")
    }

    /// Minutes, rounded down, up to the hour.
    func testUnderAnHourIsMinutes() {
        XCTAssertEqual(ago(60), "1 min ago")
        XCTAssertEqual(ago(5 * 60 + 30), "5 min ago")
        XCTAssertEqual(ago(3599), "59 min ago")
    }

    /// Hours, rounded down, up to the day.
    func testUnderADayIsHours() {
        XCTAssertEqual(ago(3600), "1 hr ago")
        XCTAssertEqual(ago(3 * 3600 + 1200), "3 hr ago")
        XCTAssertEqual(ago(86_399), "23 hr ago")
    }

    /// A day old is "yesterday" until it is two; then it is counted in days, up to two weeks.
    func testTheDayBeforeIsYesterdayAndThenItIsDays() {
        XCTAssertEqual(ago(86_400), "yesterday")
        XCTAssertEqual(ago(86_400 * 1.9), "yesterday")
        XCTAssertEqual(ago(86_400 * 2), "2 days ago")
        XCTAssertEqual(ago(86_400 * 4 + 3600), "4 days ago")
        XCTAssertEqual(ago(86_400 * 13.9), "13 days ago")
    }

    /// Two weeks and older is a date, not a count: none of the words above, and something to read.
    func testAfterTwoWeeksItIsADateNotAWord() {
        for days in [14.0, 15, 30, 400] {
            let text = ago(86_400 * days)
            XCTAssertFalse(text.isEmpty)
            XCTAssertNotEqual(text, "now")
            XCTAssertNotEqual(text, "yesterday")
            XCTAssertFalse(text.hasSuffix(" ago"), text)
            XCTAssertFalse(text.hasSuffix("yesterday"), text)
        }
    }

    /// A date in the future (the clock was set back) is "now", never a negative number.
    func testADateInTheFutureIsNow() {
        XCTAssertEqual(ClipboardSearch.ago(from: base.addingTimeInterval(500), to: base), "now")
    }
}
