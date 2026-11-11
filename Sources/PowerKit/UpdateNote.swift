import Foundation

/// The two plain sentences that say what an update is, shown on the update screen instead of only commit numbers.
///
/// They live in `UPDATE-NOTE.md` at the top of the repo and are written by whoever pushes, so the person updating reads
/// what changed in words rather than `7f6bb21`. The updater reads the file from the UPSTREAM commit (`git show
/// @{upstream}:UPDATE-NOTE.md`) before pulling anything, so the panel can say what is about to be installed.
public enum UpdateNote {

    public static let fileName = "UPDATE-NOTE.md"

    /// What fits a small panel: two ordinary sentences. Longer text is cut, at a sentence end where there is one.
    public static let maxLength = 320

    /// The note's text from the file's contents: one paragraph, no markdown headings or comments, whitespace
    /// collapsed, and at most `maxLength` characters. Nil when there is nothing to say.
    public static func text(from raw: String?) -> String? {
        guard let raw else { return nil }
        var inComment = false
        var kept: [Substring] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if inComment {
                if t.contains("-->") { inComment = false }
                continue
            }
            if t.hasPrefix("<!--") {
                if !t.contains("-->") { inComment = true }
                continue
            }
            if t.isEmpty || t.hasPrefix("#") { continue }
            kept.append(Substring(t))
        }
        let joined = kept.joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return shortened(joined)
    }

    /// Cut at the last full sentence inside the limit, else at the last word with an ellipsis.
    static func shortened(_ s: String) -> String {
        guard s.count > maxLength else { return s }
        let head = String(s.prefix(maxLength))
        if let end = head.lastIndex(where: { ".!?".contains($0) }), head.distance(from: head.startIndex, to: end) > 40 {
            return String(head[...end])
        }
        let words = head.split(separator: " ").dropLast()
        return words.joined(separator: " ") + "…"
    }

    /// How many sentences the text has, counting a sentence as text ending in . ! or ?. For the check that the note
    /// in the repo stays the length it is meant to be.
    public static func sentenceCount(_ text: String) -> Int {
        let chars = Array(text)
        var n = 0, pending = false
        for (i, ch) in chars.enumerated() {
            if ".!?".contains(ch) {
                // A full stop ends a sentence only before a space or the end: the dots in "1.15.0" do not.
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if pending, next == nil || next!.isWhitespace { n += 1; pending = false }
            } else if !ch.isWhitespace { pending = true }
        }
        return n + (pending ? 1 : 0)
    }

    /// `VERSION="1.1.0"` from `build-app.sh`: the number About shows, read from the upstream copy of the script.
    public static func version(inBuildScript script: String?) -> String? {
        guard let script else { return nil }
        for line in script.split(separator: "\n") where line.hasPrefix("VERSION=") {
            let value = line.dropFirst("VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            let parts = value.split(separator: ".")
            if (2...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                return value
            }
        }
        return nil
    }
}
