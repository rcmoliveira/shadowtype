// WordCompletion — FlowIn-style "auto show word alternatives" core logic. Pure, fully testable:
// no engine, no UI, no settings reads. The coordinator wires these pieces together (trigger →
// stem-constrained generation → branch-menu render), exactly like EmojiCompletion is pure logic
// wired by the coordinator's .emoji fire branch.
//
// Interaction class difference vs the sentence ghost: the sentence ghost fires on a typing PAUSE
// and emits 5-16 tokens; word alternatives fire WHILE typing (the stem is incomplete) and emit
// only the rest of one word. That is why FlowIn feels instant — 1-3 tokens generated, not because
// its engine is faster (it runs the same llama.cpp on an E2B-class model).
enum WordCompletion {

    // Minimum stem length before firing. 1-letter stems ("a", "I") match hundreds of words and the
    // menu churns every keystroke; FlowIn's behavior starts completing around 2 characters.
    static let minStemLength = 2

    // Cap on menu rows — a branch menu longer than this stops being scannable mid-flow.
    static let maxBranches = 5

    // The word stem immediately before the caret, or nil when a word-completion ghost must not
    // fire. Returns the trailing token (up to the last whitespace), leading punctuation trimmed
    // so "— wo" yields "wo", and rejects contexts where a word menu would be wrong:
    //   - too short (< minStemLength letters)
    //   - emoji shortcodes (`:smil`) and snippets (`;sig`) — those own their own ghost path
    //   - URL-ish tokens (`http`, `https://…`, any `//`) — completing domains/paths as prose words
    //     is noise
    //   - tokens that are pure digits (`4521`) — number runs want no word menu
    static func stem(beforeCaret prefix: String) -> String? {
        // Last whitespace-delimited token. Unicode-aware Character iteration keeps composed
        // graphemes (accents, emoji-adjacent marks) intact. No whitespace at all = first word of
        // the document — still a word, still completes ("Thanks" typed into an empty mail body).
        let tokenSlice: Substring
        if let lastSpace = prefix.lastIndex(where: { $0.isWhitespace }) {
            tokenSlice = prefix[prefix.index(after: lastSpace)...]
        } else {
            tokenSlice = prefix[...]
        }
        var token = tokenSlice
        // Trim leading punctuation (quotes, brackets, dashes) but never letters/digits.
        while let f = token.first, !f.isLetter, !f.isNumber {
            token = token[token.index(after: token.startIndex)...]
        }
        let stem = String(token)
        guard stem.count >= minStemLength else { return nil }
        // Context exclusions on the raw token (pre-trim colon check needs the untrimmed form too).
        let raw = String(tokenSlice)
        if raw.hasPrefix(":") || raw.hasPrefix(";") { return nil }   // emoji shortcode / snippet
        if stem.contains("//") || raw.contains("//") { return nil }   // URL path fragment
        if stem.allSatisfy({ $0.isNumber }) { return nil }            // pure number
        return stem
    }

    // One model continuation of the stem. `remainder` is what the model would insert after the
    // caret to complete the word (stem-constrained decode output), with its generation probability.
    struct Candidate: Equatable {
        var remainder: String
        var probability: Float
    }

    // Build the branch menu: deduped, full-word completions (stem + remainder), highest
    // probability first, at most `maxBranches` rows. Rules:
    //   - a remainder is cut at its first whitespace — the menu completes ONE word; the model may
    //     happily continue "…tion and the", the menu wants "tion" only
    //   - empty remainder after the cut == the model's top choice equals the typed stem itself →
    //     not an alternative, dropped
    //   - dedupe by the resulting full word, keeping the highest-probability occurrence (input is
    //     assumed probability-sorted; a later duplicate can never outrank an earlier one)
    //   - case-sensitive dedupe on purpose: "England" vs "england" are different completions of
    //     "eng" in prose (proper noun vs common); a capitalised duplicate at row 3 is fine
    static func branchMenu(candidates: [Candidate], stem: String) -> [String] {
        var seen: Set<String> = []
        var menu: [String] = []
        for c in candidates {
            // Cut to one word; also strip trailing punctuation the model glued on ("tion," → "tion"
            // is WRONG to strip blindly — "tion," may be the only grammatical completion; keep
            // punctuation, only whitespace cuts).
            let wordRemainder = String(c.remainder.prefix(while: { !$0.isWhitespace }))
            if wordRemainder.isEmpty { continue }
            let full = stem + wordRemainder
            if seen.contains(full) { continue }
            seen.insert(full)
            menu.append(full)
            if menu.count == maxBranches { break }
        }
        return menu
    }
}
