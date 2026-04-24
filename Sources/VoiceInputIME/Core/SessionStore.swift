import Foundation
import SQLite3
import os.log

private let sessionLog = Logger(subsystem: "com.voiceinput.app", category: "SessionStore")

/// A session groups consecutive transcript entries in the same app.
/// New session starts when the app changes or after an idle gap.
struct VSession {
    let id: String
    let startedAt: Date
    var endedAt: Date?
    let appBundleID: String?
    let appDisplayName: String?
    var summary: String?
    var tags: [String]
    var entryCount: Int
}

/// A single transcription event within a session.
struct TranscriptEntry {
    let id: String
    let sessionID: String
    let timestamp: Date
    let rawText: String
    let finalText: String
    let wasCancelled: Bool
}

/// Record of a learning-agent pass (L2 / L3).
struct AgentRun {
    let id: String
    let tier: String
    let runAt: Date
    let inputCount: Int
    let correctionsAdded: Int
    let vocabAdded: Int
    let summary: String?
    let tokenCost: Int
}

/// Persistent store for voice input sessions and transcript entries.
/// SQLite-backed, resides at `~/.voiceinput/sessions.db`.
final class SessionStore {
    static let shared = SessionStore()

    /// Idle gap after which the next entry starts a new session.
    static let idleGap: TimeInterval = 10 * 60 // 10 minutes

    private var db: OpaquePointer?
    private let dbPath: String
    private let queue = DispatchQueue(label: "com.voiceinput.sessionstore", qos: .utility)

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voiceinput")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("sessions.db").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            sessionLog.error("Failed to open database at \(self.dbPath, privacy: .public)")
            return
        }

        createTables()
        sessionLog.info("Opened at \(self.dbPath, privacy: .public)")
    }

    deinit {
        sqlite3_close(db)
    }

    private func createTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS sessions (
              id TEXT PRIMARY KEY,
              started_at REAL NOT NULL,
              ended_at REAL,
              app_bundle_id TEXT,
              app_display_name TEXT,
              summary TEXT,
              tags TEXT
            );
        """)
        exec("""
            CREATE TABLE IF NOT EXISTS transcript_entries (
              id TEXT PRIMARY KEY,
              session_id TEXT NOT NULL,
              timestamp REAL NOT NULL,
              raw_text TEXT NOT NULL,
              final_text TEXT NOT NULL,
              was_cancelled INTEGER NOT NULL DEFAULT 0
            );
        """)
        exec("""
            CREATE TABLE IF NOT EXISTS agent_runs (
              id TEXT PRIMARY KEY,
              tier TEXT NOT NULL,
              run_at REAL NOT NULL,
              input_count INTEGER NOT NULL DEFAULT 0,
              corrections_added INTEGER NOT NULL DEFAULT 0,
              vocab_added INTEGER NOT NULL DEFAULT 0,
              summary TEXT,
              token_cost INTEGER NOT NULL DEFAULT 0
            );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_entries_session ON transcript_entries(session_id);")
        exec("CREATE INDEX IF NOT EXISTS idx_entries_ts ON transcript_entries(timestamp);")
        exec("CREATE INDEX IF NOT EXISTS idx_sessions_app ON sessions(app_bundle_id);")
        exec("CREATE INDEX IF NOT EXISTS idx_sessions_ts ON sessions(started_at);")
        exec("CREATE INDEX IF NOT EXISTS idx_agent_runs_at ON agent_runs(run_at);")
    }

    // MARK: - Session Routing

    /// Append a transcript entry. Routes to the current open session for the
    /// given app (or starts a new session if none is open / idle-gap exceeded).
    /// Returns the resolved session ID, or nil if persistence is disabled.
    @discardableResult
    func append(
        rawText: String,
        finalText: String,
        appBundleID: String?,
        appDisplayName: String?,
        wasCancelled: Bool = false,
        at date: Date = Date()
    ) -> String? {
        guard AppSettings.shared.sessionLoggingEnabled else { return nil }

        // Respect blacklist.
        if let id = appBundleID, AppSettings.shared.sessionBlacklist.contains(id) {
            return nil
        }

        return queue.sync { () -> String? in
            let sessionID = resolveOrCreateSession(
                appBundleID: appBundleID,
                appDisplayName: appDisplayName,
                at: date
            )
            insertEntry(
                sessionID: sessionID,
                timestamp: date,
                rawText: rawText,
                finalText: finalText,
                wasCancelled: wasCancelled
            )
            return sessionID
        }
    }

    private func resolveOrCreateSession(appBundleID: String?, appDisplayName: String?, at date: Date) -> String {
        // Look for an open session with same app and recent activity.
        let cutoff = date.timeIntervalSince1970 - SessionStore.idleGap
        let sql = """
            SELECT s.id
            FROM sessions s
            LEFT JOIN transcript_entries e ON e.session_id = s.id
            WHERE s.ended_at IS NULL
              AND (s.app_bundle_id IS ?1 OR s.app_bundle_id = ?1)
            GROUP BY s.id
            HAVING COALESCE(MAX(e.timestamp), s.started_at) >= ?2
            ORDER BY MAX(e.timestamp) DESC
            LIMIT 1;
        """

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return createSession(appBundleID: appBundleID, appDisplayName: appDisplayName, at: date) }

        if let bundleID = appBundleID {
            sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_double(stmt, 2, cutoff)

        if sqlite3_step(stmt) == SQLITE_ROW, let cStr = sqlite3_column_text(stmt, 0) {
            return String(cString: cStr)
        }

        // Close any stale open sessions for this app before creating a new one.
        closeStaleOpenSessions(appBundleID: appBundleID, cutoff: cutoff)
        return createSession(appBundleID: appBundleID, appDisplayName: appDisplayName, at: date)
    }

    private func closeStaleOpenSessions(appBundleID: String?, cutoff: TimeInterval) {
        let sql = """
            UPDATE sessions SET ended_at = ?2
            WHERE ended_at IS NULL
              AND (app_bundle_id IS ?1 OR app_bundle_id = ?1)
              AND id IN (
                SELECT s.id FROM sessions s
                LEFT JOIN transcript_entries e ON e.session_id = s.id
                WHERE s.ended_at IS NULL
                  AND (s.app_bundle_id IS ?1 OR s.app_bundle_id = ?1)
                GROUP BY s.id
                HAVING COALESCE(MAX(e.timestamp), s.started_at) < ?2
              );
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        if let bundleID = appBundleID {
            sqlite3_bind_text(stmt, 1, (bundleID as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        sqlite3_bind_double(stmt, 2, cutoff)
        sqlite3_step(stmt)
    }

    private func createSession(appBundleID: String?, appDisplayName: String?, at date: Date) -> String {
        let id = UUID().uuidString
        let sql = "INSERT INTO sessions (id, started_at, app_bundle_id, app_display_name) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return id }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 2, date.timeIntervalSince1970)
        if let b = appBundleID { sqlite3_bind_text(stmt, 3, (b as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 3) }
        if let n = appDisplayName { sqlite3_bind_text(stmt, 4, (n as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_step(stmt)
        return id
    }

    private func insertEntry(sessionID: String, timestamp: Date, rawText: String, finalText: String, wasCancelled: Bool) {
        let id = UUID().uuidString
        let sql = """
            INSERT INTO transcript_entries (id, session_id, timestamp, raw_text, final_text, was_cancelled)
            VALUES (?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (sessionID as NSString).utf8String, -1, nil)
        sqlite3_bind_double(stmt, 3, timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 4, (rawText as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 5, (finalText as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 6, wasCancelled ? 1 : 0)
        sqlite3_step(stmt)
    }

    // MARK: - Queries

    /// Sessions ordered by most recent first.
    func recentSessions(limit: Int = 100) -> [VSession] {
        queue.sync { () -> [VSession] in
            let sql = """
                SELECT s.id, s.started_at, s.ended_at, s.app_bundle_id, s.app_display_name,
                       s.summary, s.tags, COUNT(e.id)
                FROM sessions s
                LEFT JOIN transcript_entries e ON e.session_id = s.id
                GROUP BY s.id
                HAVING COUNT(e.id) > 0
                ORDER BY COALESCE(MAX(e.timestamp), s.started_at) DESC
                LIMIT ?;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var out: [VSession] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = stringCol(stmt, 0) ?? ""
                let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                let ended: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                let bundle = stringCol(stmt, 3)
                let display = stringCol(stmt, 4)
                let summary = stringCol(stmt, 5)
                let tagsJSON = stringCol(stmt, 6) ?? ""
                let tags = (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []
                let count = Int(sqlite3_column_int(stmt, 7))
                out.append(VSession(id: id, startedAt: started, endedAt: ended, appBundleID: bundle, appDisplayName: display, summary: summary, tags: tags, entryCount: count))
            }
            return out
        }
    }

    /// Entries across ALL sessions, newest first. Used as training input
    /// for the learning agent.
    func recentEntries(limit: Int = 200, since: Date? = nil) -> [TranscriptEntry] {
        queue.sync { () -> [TranscriptEntry] in
            var sql = """
                SELECT e.id, e.session_id, e.timestamp, e.raw_text, e.final_text, e.was_cancelled
                FROM transcript_entries e
            """
            if since != nil { sql += " WHERE e.timestamp >= ?" }
            sql += " ORDER BY e.timestamp DESC LIMIT ?;"

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            var idx: Int32 = 1
            if let s = since {
                sqlite3_bind_double(stmt, idx, s.timeIntervalSince1970); idx += 1
            }
            sqlite3_bind_int(stmt, idx, Int32(limit))

            var out: [TranscriptEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(TranscriptEntry(
                    id: stringCol(stmt, 0) ?? "",
                    sessionID: stringCol(stmt, 1) ?? "",
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    rawText: stringCol(stmt, 3) ?? "",
                    finalText: stringCol(stmt, 4) ?? "",
                    wasCancelled: sqlite3_column_int(stmt, 5) != 0
                ))
            }
            return out
        }
    }

    /// Total entry count. Used by the agent trigger to decide when to run.
    func entryCount() -> Int {
        queue.sync { () -> Int in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM transcript_entries;", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    // MARK: - Agent runs

    func insertAgentRun(_ run: AgentRun) {
        queue.sync {
            let sql = """
                INSERT INTO agent_runs (id, tier, run_at, input_count, corrections_added, vocab_added, summary, token_cost)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, (run.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (run.tier as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 3, run.runAt.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 4, Int32(run.inputCount))
            sqlite3_bind_int(stmt, 5, Int32(run.correctionsAdded))
            sqlite3_bind_int(stmt, 6, Int32(run.vocabAdded))
            if let s = run.summary { sqlite3_bind_text(stmt, 7, (s as NSString).utf8String, -1, nil) } else { sqlite3_bind_null(stmt, 7) }
            sqlite3_bind_int(stmt, 8, Int32(run.tokenCost))
            sqlite3_step(stmt)
        }
    }

    func recentAgentRuns(limit: Int = 20) -> [AgentRun] {
        queue.sync { () -> [AgentRun] in
            let sql = "SELECT id, tier, run_at, input_count, corrections_added, vocab_added, summary, token_cost FROM agent_runs ORDER BY run_at DESC LIMIT ?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var out: [AgentRun] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(AgentRun(
                    id: stringCol(stmt, 0) ?? "",
                    tier: stringCol(stmt, 1) ?? "",
                    runAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    inputCount: Int(sqlite3_column_int(stmt, 3)),
                    correctionsAdded: Int(sqlite3_column_int(stmt, 4)),
                    vocabAdded: Int(sqlite3_column_int(stmt, 5)),
                    summary: stringCol(stmt, 6),
                    tokenCost: Int(sqlite3_column_int(stmt, 7))
                ))
            }
            return out
        }
    }

    func lastAgentRunAt(tier: String) -> Date? {
        queue.sync { () -> Date? in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT MAX(run_at) FROM agent_runs WHERE tier = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(stmt, 1, (tier as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    /// All entries for a session, oldest first.
    func entries(sessionID: String) -> [TranscriptEntry] {
        queue.sync { () -> [TranscriptEntry] in
            let sql = """
                SELECT id, session_id, timestamp, raw_text, final_text, was_cancelled
                FROM transcript_entries
                WHERE session_id = ?
                ORDER BY timestamp ASC;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, nil)

            var out: [TranscriptEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(TranscriptEntry(
                    id: stringCol(stmt, 0) ?? "",
                    sessionID: stringCol(stmt, 1) ?? "",
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    rawText: stringCol(stmt, 3) ?? "",
                    finalText: stringCol(stmt, 4) ?? "",
                    wasCancelled: sqlite3_column_int(stmt, 5) != 0
                ))
            }
            return out
        }
    }

    /// Keyword search across entries. Case-insensitive LIKE match.
    func search(_ query: String, limit: Int = 200) -> [(session: VSession, entry: TranscriptEntry)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return queue.sync { () -> [(VSession, TranscriptEntry)] in
            let sql = """
                SELECT e.id, e.session_id, e.timestamp, e.raw_text, e.final_text, e.was_cancelled,
                       s.started_at, s.ended_at, s.app_bundle_id, s.app_display_name
                FROM transcript_entries e
                JOIN sessions s ON s.id = e.session_id
                WHERE e.final_text LIKE ?1 OR e.raw_text LIKE ?1
                ORDER BY e.timestamp DESC
                LIMIT ?2;
            """
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            let needle = "%\(trimmed)%"
            sqlite3_bind_text(stmt, 1, (needle as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 2, Int32(limit))

            var out: [(VSession, TranscriptEntry)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let entry = TranscriptEntry(
                    id: stringCol(stmt, 0) ?? "",
                    sessionID: stringCol(stmt, 1) ?? "",
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    rawText: stringCol(stmt, 3) ?? "",
                    finalText: stringCol(stmt, 4) ?? "",
                    wasCancelled: sqlite3_column_int(stmt, 5) != 0
                )
                let sess = VSession(
                    id: entry.sessionID,
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                    endedAt: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)),
                    appBundleID: stringCol(stmt, 8),
                    appDisplayName: stringCol(stmt, 9),
                    summary: nil,
                    tags: [],
                    entryCount: 0
                )
                out.append((sess, entry))
            }
            return out
        }
    }

    // MARK: - Maintenance

    /// Delete entries + sessions older than `days`.
    func purgeOlderThan(days: Int) {
        guard days > 0 else { return }
        queue.sync {
            let cutoff = Date().timeIntervalSince1970 - TimeInterval(days * 86400)
            exec("DELETE FROM transcript_entries WHERE timestamp < \(cutoff);")
            exec("DELETE FROM sessions WHERE id NOT IN (SELECT DISTINCT session_id FROM transcript_entries);")
        }
    }

    func deleteSession(_ sessionID: String) {
        queue.sync {
            for sql in [
                "DELETE FROM transcript_entries WHERE session_id = ?;",
                "DELETE FROM sessions WHERE id = ?;",
            ] {
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
        }
    }

    // MARK: - Summary update

    func updateSummary(sessionID: String, summary: String, tags: [String]) {
        queue.sync {
            let tagsJSON = (try? String(data: JSONEncoder().encode(tags), encoding: .utf8)) ?? "[]"
            let sql = "UPDATE sessions SET summary = ?, tags = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            sqlite3_bind_text(stmt, 1, (summary as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (tagsJSON as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (sessionID as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Helpers

    private func stringCol(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cStr)
    }

    private func exec(_ sql: String) {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let msg = errMsg {
                sessionLog.error("SQL error: \(String(cString: msg), privacy: .public)")
            }
            sqlite3_free(errMsg)
        }
    }
}
