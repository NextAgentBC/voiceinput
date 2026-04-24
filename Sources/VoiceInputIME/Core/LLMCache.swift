import Foundation
import SQLite3
import CryptoKit
import os.log

private let cacheLog = Logger(subsystem: "com.voiceinput.app", category: "LLMCache")

/// SQLite-backed cache for LLM refiner results.
/// Key: SHA256(raw + model + lang). Value: refined text.
/// Zero-latency return on repeat phrases like "好的", "测试一下", "收到".
final class LLMCache {
    static let shared = LLMCache()

    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.voiceinput.llmcache", qos: .utility)

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voiceinput")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("llm_cache.db").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            cacheLog.error("Failed to open cache at \(self.dbPath, privacy: .public)")
            return
        }

        createTable()
        pruneSuspiciousEntries()
        cacheLog.info("Opened at \(self.dbPath, privacy: .public), \(self.count()) entries")
    }

    deinit { sqlite3_close(db) }

    private func createTable() {
        let sql = """
            CREATE TABLE IF NOT EXISTS llm_cache (
              key TEXT PRIMARY KEY,
              raw_text TEXT NOT NULL,
              refined_text TEXT NOT NULL,
              model TEXT,
              lang TEXT,
              hit_count INTEGER NOT NULL DEFAULT 0,
              reject_count INTEGER NOT NULL DEFAULT 0,
              created_at REAL NOT NULL,
              last_hit REAL NOT NULL
            );
        """
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let e = err {
            cacheLog.error("Create table: \(String(cString: e), privacy: .public)")
        }
        sqlite3_free(err)

        // Migration: add reject_count for DBs created before v0.3. Only run
        // it if the column doesn't already exist — avoids log noise on every
        // launch.
        if !columnExists(table: "llm_cache", column: "reject_count") {
            sqlite3_exec(db, "ALTER TABLE llm_cache ADD COLUMN reject_count INTEGER NOT NULL DEFAULT 0;", nil, nil, nil)
        }
    }

    /// Clean up entries where `refined_text` is wildly longer than
    /// `raw_text` — those are poisoned rewrites, not corrections.
    private func pruneSuspiciousEntries() {
        let sql = """
            DELETE FROM llm_cache
            WHERE LENGTH(refined_text) > MAX(LENGTH(raw_text) * 3, LENGTH(raw_text) + 80);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func columnExists(table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "PRAGMA table_info(\(table));"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 1) {
                if String(cString: cStr) == column { return true }
            }
        }
        return false
    }

    // MARK: - API

    /// Cache hit result. `key` is exposed so a caller can later report rejection.
    struct Hit {
        let key: String
        let refinedText: String
    }

    /// Cache lookup. Bumps hit_count + last_hit on hit. Skips entries with
    /// non-zero reject_count (those failed before and should re-query).
    func get(raw: String, model: String, lang: String) -> Hit? {
        let key = cacheKey(raw: raw, model: model, lang: lang)
        return queue.sync { () -> Hit? in
            let sql = "SELECT refined_text FROM llm_cache WHERE key = ? AND reject_count = 0;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let cStr = sqlite3_column_text(stmt, 0) else { return nil }
            let refined = String(cString: cStr)
            bumpHit(key: key)
            return Hit(key: key, refinedText: refined)
        }
    }

    /// User signalled the cached result was wrong. Increments reject_count.
    /// When reject_count reaches 2 the entry is deleted so next query re-hits LLM.
    func reject(key: String) {
        queue.async {
            let update = "UPDATE llm_cache SET reject_count = reject_count + 1 WHERE key = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, update, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)

            let delete = "DELETE FROM llm_cache WHERE key = ? AND reject_count >= 2;"
            var del: OpaquePointer?
            if sqlite3_prepare_v2(self.db, delete, -1, &del, nil) == SQLITE_OK {
                sqlite3_bind_text(del, 1, (key as NSString).utf8String, -1, nil)
                sqlite3_step(del)
            }
            sqlite3_finalize(del)
            cacheLog.info("rejected key=\(key.prefix(8), privacy: .public)")
        }
    }

    /// Store a (raw → refined) mapping. Upserts on conflict. Returns the key
    /// so the caller can pass it to `reject(key:)` later if needed.
    @discardableResult
    func put(raw: String, refined: String, model: String, lang: String) -> String {
        let key = cacheKey(raw: raw, model: model, lang: lang)
        // Sanity guard: a refined text that's vastly longer than the raw is
        // almost always a full rewrite, not a STT correction. Storing it
        // means next time the same raw shows up we paste a paragraph.
        if refined.count > max(raw.count * 3, raw.count + 80) {
            cacheLog.warning("Refused to cache (refined much longer than raw)")
            return key
        }
        queue.async {
            let now = Date().timeIntervalSince1970
            let sql = """
                INSERT INTO llm_cache (key, raw_text, refined_text, model, lang, hit_count, created_at, last_hit)
                VALUES (?, ?, ?, ?, ?, 0, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                  refined_text = excluded.refined_text,
                  last_hit = excluded.last_hit;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (raw as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (refined as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (model as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (lang as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 6, now)
            sqlite3_bind_double(stmt, 7, now)
            sqlite3_step(stmt)
        }
        return key
    }

    /// Evict entries older than `days` with hit_count below `minHits`.
    func evict(olderThanDays days: Int, minHits: Int = 1) {
        guard days > 0 else { return }
        queue.async {
            let cutoff = Date().timeIntervalSince1970 - TimeInterval(days * 86400)
            let sql = "DELETE FROM llm_cache WHERE last_hit < ? AND hit_count < ?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_bind_int(stmt, 2, Int32(minHits))
            sqlite3_step(stmt)
        }
    }

    /// Clear everything. For Settings "Reset Cache" button.
    func clear() {
        queue.async {
            sqlite3_exec(self.db, "DELETE FROM llm_cache;", nil, nil, nil)
        }
    }

    func count() -> Int {
        queue.sync { () -> Int in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM llm_cache;", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    // MARK: - Private

    private func bumpHit(key: String) {
        let sql = "UPDATE llm_cache SET hit_count = hit_count + 1, last_hit = ? WHERE key = ?;"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, (key as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
    }

    private func cacheKey(raw: String, model: String, lang: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let material = "\(trimmed)|\(model)|\(lang)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
