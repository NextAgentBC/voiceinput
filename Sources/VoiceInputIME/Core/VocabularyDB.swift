import Foundation
import SQLite3
import os.log

private let vocabLog = Logger(subsystem: "com.voiceinput.app", category: "VocabDB")

/// SQLite-based vocabulary database with frequency tracking,
/// fuzzy matching, and auto-learning from AI corrections.
final class VocabularyDB {
    static let shared = VocabularyDB()

    private var db: OpaquePointer?
    private let dbPath: String

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voiceinput")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("vocabulary.db").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            vocabLog.error("Failed to open database at \(self.dbPath, privacy: .public)")
            return
        }

        createTables()
        migrateFromJSON()
        pruneGarbageEntries()

        vocabLog.info("Opened at \(self.dbPath, privacy: .public), \(self.totalCount()) entries")
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func createTables() {
        execute("""
            CREATE TABLE IF NOT EXISTS corrections (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                original TEXT NOT NULL,
                corrected TEXT NOT NULL,
                frequency INTEGER DEFAULT 1,
                confidence REAL DEFAULT 1.0,
                source TEXT DEFAULT 'manual',
                created_at REAL DEFAULT (strftime('%s','now')),
                last_used REAL DEFAULT (strftime('%s','now')),
                UNIQUE(original, corrected)
            );
            CREATE INDEX IF NOT EXISTS idx_original ON corrections(original);
            CREATE INDEX IF NOT EXISTS idx_frequency ON corrections(frequency DESC);
        """)
    }

    // MARK: - Core Operations

    /// Look up corrections for a given text. Returns matches sorted by frequency.
    func lookup(_ original: String) -> [(corrected: String, frequency: Int, confidence: Double)] {
        var results: [(String, Int, Double)] = []
        let sql = "SELECT corrected, frequency, confidence FROM corrections WHERE original = ? ORDER BY frequency DESC"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (original as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let corrected = String(cString: sqlite3_column_text(stmt, 0))
                let freq = Int(sqlite3_column_int(stmt, 1))
                let conf = sqlite3_column_double(stmt, 2)
                results.append((corrected, freq, conf))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// Look up the best (highest frequency) correction. Returns nil if not found.
    func bestCorrection(for original: String) -> String? {
        let matches = lookup(original)
        return matches.first?.corrected
    }

    /// Apply all known corrections to a text. For ASCII-only originals
    /// we use word-boundary regex so "Sub" doesn't match inside "Super".
    /// Non-ASCII (CJK) originals still use plain substring replacement
    /// since Chinese has no word boundaries.
    func applyCorrections(_ text: String) -> (text: String, applied: [(original: String, corrected: String)]) {
        var result = text
        var applied: [(String, String)] = []

        let allCorrections = allEntries().sorted { $0.original.count > $1.original.count }

        for entry in allCorrections {
            let isASCII = entry.original.allSatisfy { $0.isASCII }
            if isASCII {
                let pattern = "\\b\(NSRegularExpression.escapedPattern(for: entry.original))\\b"
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                    let range = NSRange(result.startIndex..., in: result)
                    if regex.firstMatch(in: result, range: range) != nil {
                        result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: entry.corrected))
                        applied.append((entry.original, entry.corrected))
                    }
                }
            } else {
                if result.range(of: entry.original, options: .caseInsensitive) != nil {
                    result = result.replacingOccurrences(of: entry.original, with: entry.corrected, options: .caseInsensitive)
                    applied.append((entry.original, entry.corrected))
                }
            }
        }

        return (result, applied)
    }

    /// Learn a new correction from AI or user. Increments frequency if already exists.
    func learn(original: String, corrected: String, source: String = "ai", confidence: Double = 1.0) {
        let trimOrig = original.trimmingCharacters(in: .whitespaces)
        let trimCorr = corrected.trimmingCharacters(in: .whitespaces)

        guard !trimOrig.isEmpty, !trimCorr.isEmpty, trimOrig != trimCorr else { return }
        guard trimOrig.count >= 2 else { return } // Skip single char corrections

        // For ASCII originals, require ≥4 chars to avoid learning fragments
        // like "Sub" that match inside unrelated words ("Super", "Subset").
        // CJK chars carry more meaning per character so 2 is enough.
        let isASCII = trimOrig.allSatisfy { $0.isASCII }
        if isASCII && trimOrig.count < 4 { return }

        // Sanity guard: a vocabulary entry maps one short fragment to another.
        // If the corrected text contains newlines or is massively longer than
        // the original, the pair is almost certainly a full-text rewrite, not
        // a word-level correction. Persisting it causes a cascade: every time
        // STT produces the short fragment, applyCorrections will explode it
        // into the whole paragraph.
        if trimCorr.contains("\n") { return }
        if trimCorr.count > 60 { return }
        if trimCorr.count > 4 * max(trimOrig.count, 3) { return }

        let sql = """
            INSERT INTO corrections (original, corrected, frequency, confidence, source, last_used)
            VALUES (?, ?, 1, ?, ?, strftime('%s','now'))
            ON CONFLICT(original, corrected) DO UPDATE SET
                frequency = frequency + 1,
                confidence = MAX(confidence, ?),
                last_used = strftime('%s','now')
        """

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (trimOrig as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (trimCorr as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 3, confidence)
            sqlite3_bind_text(stmt, 4, (source as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 5, confidence)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)

        vocabLog.info("Learned: \(trimOrig, privacy: .public) → \(trimCorr, privacy: .public) (source=\(source, privacy: .public))")
    }

    /// Learn from a full text diff (AI correction result).
    /// Extracts individual word-level corrections and stores them.
    func learnFromDiff(original: String, corrected: String, source: String = "ai") {
        guard original != corrected else { return }

        // Always learn the full pair — guarantees the canonical corrected
        // form (e.g. "Hubery") enters the vocab verbatim, so contextualStrings
        // and LLM prompts can use it. Length-sanity guards inside `learn`
        // handle the "user rewrote everything" case.
        learn(original: original, corrected: corrected, source: source)

        // Also store any narrower word-level substitutions found in the diff.
        let diffs = extractDifferences(original: original, corrected: corrected)
        for (orig, corr) in diffs {
            learn(original: orig, corrected: corr, source: source)
        }
    }

    /// Get candidates for fuzzy matching (similar to original, sorted by frequency)
    func fuzzyLookup(_ text: String, maxResults: Int = 5) -> [(original: String, corrected: String, frequency: Int)] {
        var results: [(String, String, Int)] = []

        // Look for substrings of text that match known originals
        let allEntries = self.allEntries()
        for entry in allEntries {
            if text.range(of: entry.original, options: .caseInsensitive) != nil {
                results.append((entry.original, entry.corrected, entry.frequency))
            }
        }

        results.sort { $0.2 > $1.2 }
        return Array(results.prefix(maxResults))
    }

    // MARK: - Management

    func allEntries() -> [(original: String, corrected: String, frequency: Int, source: String)] {
        var results: [(String, String, Int, String)] = []
        let sql = "SELECT original, corrected, frequency, source FROM corrections ORDER BY frequency DESC"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let orig = String(cString: sqlite3_column_text(stmt, 0))
                let corr = String(cString: sqlite3_column_text(stmt, 1))
                let freq = Int(sqlite3_column_int(stmt, 2))
                let src = String(cString: sqlite3_column_text(stmt, 3))
                results.append((orig, corr, freq, src))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    /// Return the top-N most frequent CORRECTED terms — feed these to
    /// SFSpeechRecognizer's `contextualStrings` so Apple Speech has a prior
    /// on the user's personal vocabulary (names, tech terms, project names).
    func topCorrectedTerms(limit: Int = 50) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let sql = """
            SELECT corrected FROM corrections
            GROUP BY corrected
            ORDER BY SUM(frequency) DESC
            LIMIT ?;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let term = String(cString: sqlite3_column_text(stmt, 0))
                let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
                seen.insert(trimmed)
                out.append(trimmed)
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    /// Remove entries where the corrected text is absurdly long or multi-line.
    /// These are historic bad pairs from before the sanity guards in `learn`.
    private func pruneGarbageEntries() {
        let sql = """
            DELETE FROM corrections
            WHERE LENGTH(corrected) > 60
               OR corrected LIKE '%' || char(10) || '%';
        """
        var err: UnsafeMutablePointer<CChar>?
        let before = totalCount()
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let msg = err { vocabLog.error("Prune failed: \(String(cString: msg), privacy: .public)") }
        }
        sqlite3_free(err)
        let after = totalCount()
        if before != after {
            vocabLog.info("Pruned \(before - after) garbage entries")
        }
    }

    func totalCount() -> Int {
        var count = 0
        let sql = "SELECT COUNT(*) FROM corrections"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    func delete(original: String, corrected: String) {
        let sql = "DELETE FROM corrections WHERE original = ? AND corrected = ?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (original as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (corrected as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Remove entries with frequency below threshold that haven't been used recently
    func pruneStale(minFrequency: Int = 1, olderThanDays: Int = 90) {
        let sql = """
            DELETE FROM corrections
            WHERE frequency <= ? AND last_used < strftime('%s','now') - ? * 86400
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(minFrequency))
            sqlite3_bind_int(stmt, 2, Int32(olderThanDays))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Migration from JSON

    private func migrateFromJSON() {
        let jsonPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voiceinput/dictionary.json")

        guard FileManager.default.fileExists(atPath: jsonPath.path) else { return }
        guard totalCount() == 0 else { return } // Already migrated

        do {
            let data = try Data(contentsOf: jsonPath)
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                for (original, corrected) in dict {
                    learn(original: original, corrected: corrected, source: "manual", confidence: 1.0)
                }
                vocabLog.info("Migrated \(dict.count) entries from JSON")
            }
        } catch {
            vocabLog.error("JSON migration failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Diff Extraction

    private func extractDifferences(original: String, corrected: String) -> [(String, String)] {
        var results: [(String, String)] = []
        let origChars = Array(original)
        let corrChars = Array(corrected)

        var prefixLen = 0
        while prefixLen < origChars.count && prefixLen < corrChars.count
              && origChars[prefixLen] == corrChars[prefixLen] {
            prefixLen += 1
        }

        var suffixLen = 0
        while suffixLen < (origChars.count - prefixLen) && suffixLen < (corrChars.count - prefixLen)
              && origChars[origChars.count - 1 - suffixLen] == corrChars[corrChars.count - 1 - suffixLen] {
            suffixLen += 1
        }

        let origMiddle = String(origChars[prefixLen..<(origChars.count - suffixLen)])
        let corrMiddle = String(corrChars[prefixLen..<(corrChars.count - suffixLen)])

        if !origMiddle.isEmpty && !corrMiddle.isEmpty && origMiddle != corrMiddle {
            let trimOrig = origMiddle.trimmingCharacters(in: .whitespaces)
            let trimCorr = corrMiddle.trimmingCharacters(in: .whitespaces)
            if !trimOrig.isEmpty && !trimCorr.isEmpty {
                results.append((trimOrig, trimCorr))
            }
        }

        return results
    }

    // MARK: - Helpers

    private func execute(_ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let msg = errMsg {
                vocabLog.error("SQL error: \(String(cString: msg), privacy: .public)")
                sqlite3_free(msg)
            }
        }
    }
}
