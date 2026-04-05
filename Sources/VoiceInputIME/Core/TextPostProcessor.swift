import Foundation

final class TextPostProcessor {
    private var dictionary: [String: String] = [:]
    private let dictionaryURL: URL

    /// Separator tokens that mean "." in URL context.
    /// Order matters: longer patterns first to avoid partial matches.
    private static let dotSynonyms = ["dot", "点", "。"]

    /// Separator tokens for other URL symbols
    private static let slashSynonyms  = ["slash", "斜杠", "斜线"]
    private static let colonSynonyms  = ["colon", "冒号"]
    private static let atSynonyms     = ["at", "艾特"]
    private static let dashSynonyms   = ["dash", "杠", "横杠", "横线"]

    /// Known TLDs to help confirm a URL pattern
    private static let knownTLDs: Set<String> = [
        "com", "ca", "cn", "org", "net", "io", "dev", "app", "co", "me",
        "uk", "jp", "de", "fr", "ai", "cc", "tv", "xyz", "info", "tech",
    ]

    init() {
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voiceinput")
        self.dictionaryURL = configDir.appendingPathComponent("dictionary.json")

        ensureConfigDir(configDir)
        loadDictionary()
    }

    func process(_ text: String) -> String {
        var result = text

        // Step 1: Apply personal dictionary (longest match first)
        result = applyDictionary(result)

        // Step 2: Detect and normalize URL/domain-like patterns
        result = normalizeURLPatterns(result)

        return result
    }

    // MARK: - Personal Dictionary

    func loadDictionary() {
        guard FileManager.default.fileExists(atPath: dictionaryURL.path) else {
            let defaults: [String: String] = [
                "BORUI": "borui",
                "博瑞": "borui",
            ]
            saveDictionary(defaults)
            dictionary = defaults
            return
        }

        do {
            let data = try Data(contentsOf: dictionaryURL)
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                dictionary = dict
            }
        } catch {
            print("Failed to load dictionary: \(error)")
        }
    }

    private func saveDictionary(_ dict: [String: String]) {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: dictionaryURL)
        } catch {
            print("Failed to save dictionary: \(error)")
        }
    }

    private func applyDictionary(_ text: String) -> String {
        var result = text
        let sorted = dictionary.sorted { $0.key.count > $1.key.count }

        for (spoken, replacement) in sorted {
            result = result.replacingOccurrences(
                of: spoken, with: replacement, options: .caseInsensitive)
        }

        return result
    }

    // MARK: - URL Normalization (regex-based, handles mixed CJK/Latin without spaces)

    /// Main entry: find sequences of segments joined by dot-synonyms and normalize them.
    private func normalizeURLPatterns(_ text: String) -> String {
        // Build a master regex that matches:
        //   <segment> <sep> <segment> (<sep> <segment>)*
        // where <segment> is Chinese chars or Latin alphanumerics
        // and <sep> is a dot-synonym with optional surrounding whitespace
        //
        // This correctly handles "AP dot博瑞dot CA", "ap.borui.ca",
        // "AP DOT BORUI DOT CA", "AP点博瑞点CA", etc.

        let segmentPat = "(?:[A-Za-z0-9]+|[\\u4e00-\\u9fff]+)"
        let dotSepPat  = buildSepPattern(Self.dotSynonyms + ["."])

        // Match: segment + (sep + segment){1,}  →  at least 2 dots = 3 segments, or 1 dot with known TLD
        let fullPattern = "\(segmentPat)(?:\\s*\(dotSepPat)\\s*\(segmentPat))+"

        guard let regex = try? NSRegularExpression(pattern: fullPattern, options: .caseInsensitive) else {
            return text
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        guard !matches.isEmpty else { return text }

        // Process matches in reverse order so range offsets stay valid
        var result = text
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let matched = String(result[swiftRange])

            let normalized = normalizeDomainCandidate(matched)

            // Only accept if it looks like a real domain (has known TLD or 3+ segments)
            if isDomainLike(normalized) {
                result.replaceSubrange(swiftRange, with: normalized)
            }
        }

        // Also handle other URL symbols (slash, colon, etc.) in URL contexts
        result = normalizeOtherURLSymbols(result)

        return result
    }

    /// Turn a matched candidate like "AP dot博瑞dot CA" into "ap.borui.ca"
    private func normalizeDomainCandidate(_ text: String) -> String {
        var s = text

        // Replace all dot-synonyms (with optional surrounding whitespace) with "."
        for syn in Self.dotSynonyms {
            // Pattern: optional-space + synonym + optional-space
            // Use regex to handle no-space boundaries (Chinese chars touching "dot")
            if let re = try? NSRegularExpression(
                pattern: "\\s*\(NSRegularExpression.escapedPattern(for: syn))\\s*",
                options: .caseInsensitive
            ) {
                s = re.stringByReplacingMatches(
                    in: s, range: NSRange(location: 0, length: (s as NSString).length),
                    withTemplate: ".")
            }
        }

        // Also replace literal "." that might have spaces around it: " . " → "."
        if let re = try? NSRegularExpression(pattern: "\\s*\\.\\s*", options: []) {
            s = re.stringByReplacingMatches(
                in: s, range: NSRange(location: 0, length: (s as NSString).length),
                withTemplate: ".")
        }

        // Lowercase the whole thing (URLs/domains are case-insensitive)
        s = s.lowercased()

        return s
    }

    /// Check if a normalized string looks like a domain
    private func isDomainLike(_ normalized: String) -> Bool {
        let parts = normalized.split(separator: ".")
        guard parts.count >= 2 else { return false }

        // If the last part is a known TLD, it's very likely a domain
        if let lastPart = parts.last, Self.knownTLDs.contains(String(lastPart)) {
            return true
        }

        // 3+ segments is likely a domain even without recognized TLD
        if parts.count >= 3 {
            return true
        }

        return false
    }

    /// Handle slash/colon/at/dash synonyms in text that already looks like a URL
    private func normalizeOtherURLSymbols(_ text: String) -> String {
        var result = text

        // Only apply these if the text contains a domain-like pattern (has "something.something")
        guard result.range(of: "[a-z0-9]+\\.[a-z0-9]+", options: .regularExpression) != nil else {
            return result
        }

        let replacements: [(synonyms: [String], symbol: String)] = [
            (Self.slashSynonyms, "/"),
            (Self.colonSynonyms, ":"),
            (Self.atSynonyms, "@"),
            (Self.dashSynonyms, "-"),
        ]

        for (synonyms, symbol) in replacements {
            for syn in synonyms {
                if let re = try? NSRegularExpression(
                    pattern: "\\s*\(NSRegularExpression.escapedPattern(for: syn))\\s*",
                    options: .caseInsensitive
                ) {
                    result = re.stringByReplacingMatches(
                        in: result,
                        range: NSRange(location: 0, length: (result as NSString).length),
                        withTemplate: symbol)
                }
            }
        }

        // Handle "https colon slash slash" → "https://"
        // and "http冒号斜杠斜杠" → "http://"  (already handled above)

        return result
    }

    /// Build a regex alternation from synonym list: (dot|点|。)
    private func buildSepPattern(_ synonyms: [String]) -> String {
        let escaped = synonyms.map { NSRegularExpression.escapedPattern(for: $0) }
        return "(?:" + escaped.joined(separator: "|") + ")"
    }

    // MARK: - Config

    private func ensureConfigDir(_ dir: URL) {
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    var dictionaryPath: String {
        dictionaryURL.path
    }

    // MARK: - Auto-Learning

    /// Compare original speech text with AI-corrected text,
    /// extract word-level differences, and save them to the dictionary.
    func autoLearn(original: String, corrected: String) {
        guard original != corrected else { return }

        // Find substrings that changed between original and corrected
        let newMappings = extractDifferences(original: original, corrected: corrected)

        guard !newMappings.isEmpty else { return }

        var updated = false
        for (spoken, correct) in newMappings {
            // Only learn if the mapping doesn't already exist
            let key = spoken
            if dictionary[key] == nil && key.count >= 2 && correct.count >= 1 {
                dictionary[key] = correct
                updated = true
                NSLog("[VoiceInputIME] Auto-learned: \"%@\" → \"%@\"", key, correct)
            }
        }

        if updated {
            saveDictionary(dictionary)
        }
    }

    /// Simple diff: find Chinese substrings in original that were replaced by different text in corrected.
    /// Works by aligning common prefixes/suffixes and extracting the changed middle part.
    private func extractDifferences(original: String, corrected: String) -> [(String, String)] {
        var results: [(String, String)] = []

        let origChars = Array(original)
        let corrChars = Array(corrected)

        // Find common prefix length
        var prefixLen = 0
        while prefixLen < origChars.count && prefixLen < corrChars.count
              && origChars[prefixLen] == corrChars[prefixLen] {
            prefixLen += 1
        }

        // Find common suffix length
        var suffixLen = 0
        while suffixLen < (origChars.count - prefixLen) && suffixLen < (corrChars.count - prefixLen)
              && origChars[origChars.count - 1 - suffixLen] == corrChars[corrChars.count - 1 - suffixLen] {
            suffixLen += 1
        }

        let origMiddle = String(origChars[prefixLen..<(origChars.count - suffixLen)])
        let corrMiddle = String(corrChars[prefixLen..<(corrChars.count - suffixLen)])

        // If we found a meaningful difference, record it
        if !origMiddle.isEmpty && !corrMiddle.isEmpty && origMiddle != corrMiddle {
            let trimmedOrig = origMiddle.trimmingCharacters(in: .whitespaces)
            let trimmedCorr = corrMiddle.trimmingCharacters(in: .whitespaces)
            if !trimmedOrig.isEmpty && !trimmedCorr.isEmpty {
                results.append((trimmedOrig, trimmedCorr))
            }
        }

        return results
    }
}
