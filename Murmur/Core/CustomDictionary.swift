import AppKit

struct DictionaryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var spoken: String
    var replacement: String
    var context: String
    var isSafe: Bool
    var safeOverridden: Bool

    init(spoken: String = "", replacement: String = "", context: String = "", isSafe: Bool = true, safeOverridden: Bool = false) {
        self.spoken = spoken
        self.replacement = replacement
        self.context = context
        self.isSafe = isSafe
        self.safeOverridden = safeOverridden
    }

    // Backward-compatible decoding: existing entries get context="", isSafe=true, safeOverridden=false
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        spoken = try container.decode(String.self, forKey: .spoken)
        replacement = try container.decode(String.self, forKey: .replacement)
        context = try container.decodeIfPresent(String.self, forKey: .context) ?? ""
        isSafe = try container.decodeIfPresent(Bool.self, forKey: .isSafe) ?? true
        safeOverridden = try container.decodeIfPresent(Bool.self, forKey: .safeOverridden) ?? false
    }
}

struct CustomDictionary {
    /// Apply dictionary replacements using case-insensitive word boundary matching.
    static func apply(entries: [DictionaryEntry], to text: String) -> String {
        guard !entries.isEmpty else { return text }
        var result = text
        for entry in entries where !entry.spoken.isEmpty && !entry.replacement.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: entry.spoken)
            guard let regex = try? NSRegularExpression(
                pattern: "\\b\(escaped)\\b",
                options: .caseInsensitive
            ) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: entry.replacement
            )
        }
        return result
    }

    /// Apply only safe (non-contextual) entries via regex.
    static func applySafe(entries: [DictionaryEntry], to text: String) -> String {
        let safe = entries.filter { $0.isSafe }
        return apply(entries: safe, to: text)
    }

    /// Partition entries into safe (regex-replaceable) and contextual (needs LLM).
    static func partition(_ entries: [DictionaryEntry]) -> (safe: [DictionaryEntry], contextual: [DictionaryEntry]) {
        var safe: [DictionaryEntry] = []
        var contextual: [DictionaryEntry] = []
        for entry in entries where !entry.spoken.isEmpty && !entry.replacement.isEmpty {
            if entry.isSafe {
                safe.append(entry)
            } else {
                contextual.append(entry)
            }
        }
        return (safe, contextual)
    }

    /// Return only contextual entries whose spoken form actually appears in the text.
    /// Uses case-insensitive word boundary matching to avoid false positives.
    static func relevantContextualEntries(from entries: [DictionaryEntry], in text: String) -> [DictionaryEntry] {
        let lowered = text.lowercased()
        return entries.filter { entry in
            guard !entry.spoken.isEmpty else { return false }
            let spoken = entry.spoken.lowercased()
            // Quick check before regex
            guard lowered.contains(spoken) else { return false }
            let escaped = NSRegularExpression.escapedPattern(for: spoken)
            guard let regex = try? NSRegularExpression(
                pattern: "\\b\(escaped)\\b",
                options: .caseInsensitive
            ) else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    /// Check if a word is a recognized English word using macOS spell checker.
    /// Words recognized by NSSpellChecker are contextual (need LLM judgment).
    static func isRealWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let checker = NSSpellChecker.shared
        let range = checker.checkSpelling(of: trimmed, startingAt: 0)
        // If no misspelling found, it's a real word
        return range.location == NSNotFound
    }

    /// Auto-classify an entry: real English words are contextual, others are safe.
    /// Does not override user's manual classification.
    static func autoClassify(_ entry: inout DictionaryEntry) {
        guard !entry.safeOverridden else { return }
        entry.isSafe = !isRealWord(entry.spoken)
    }

    /// Build a WhisperKit prompt hint string from dictionary entries.
    /// This helps the model recognize proper nouns and technical terms.
    static func promptHint(from entries: [DictionaryEntry]) -> String? {
        let terms = entries
            .filter { !$0.replacement.isEmpty }
            .map(\.replacement)
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: ", ")
    }
}
