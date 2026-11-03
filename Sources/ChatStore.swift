import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 本地 SQLite：对话、记忆、对话摘要。所有 SQL 都走参数绑定。
final class ChatStore {
    struct Message {
        let id: Int64
        let role: String          // user / assistant
        let content: String
        let createdAt: Date
    }

    struct Memory {
        let id: Int64
        let kind: String          // preference / fact / plan / relationship
        let content: String
        let keywords: String
        let createdAt: Date
        let updatedAt: Date
        let hits: Int
    }

    struct Summary {
        let content: String
        let createdAt: Date
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.wangchao.ruanmeipet.chatdb")
    private(set) var isOpen = false
    private(set) var openError: String?

    init?(url: URL) {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let opened = handle else {
            openError = "无法打开对话数据库"
            if handle != nil { sqlite3_close(handle) }
            return nil
        }
        db = opened
        isOpen = true
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        exec("PRAGMA busy_timeout=2000;")
        createSchema()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - 底层

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        return statement
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ text: String) {
        sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
    }

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS messages(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            persona TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(created_at);
        CREATE TABLE IF NOT EXISTS memories(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            content TEXT NOT NULL,
            keywords TEXT NOT NULL DEFAULT '',
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            hits INTEGER NOT NULL DEFAULT 0
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_memories_content ON memories(content);
        CREATE TABLE IF NOT EXISTS summaries(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL,
            created_at REAL NOT NULL,
            covers_until INTEGER NOT NULL DEFAULT 0
        );
        """)
    }

    // MARK: - 消息

    @discardableResult
    func insertMessage(role: String, content: String, persona: String = "") -> Int64? {
        let safeContent = String(content.prefix(20_000))
        return queue.sync {
            guard let statement = prepare("INSERT INTO messages(role, content, persona, created_at) VALUES(?, ?, ?, ?);") else { return nil }
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, role)
            bind(statement, 2, safeContent)
            bind(statement, 3, persona)
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE, let db else { return nil }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func recentMessages(limit: Int) -> [Message] {
        let count = max(1, min(limit, 400))
        return queue.sync {
            guard let statement = prepare("SELECT id, role, content, created_at FROM messages ORDER BY id DESC LIMIT ?;") else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(count))
            var result: [Message] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = sqlite3_column_int64(statement, 0)
                let role = String(cString: sqlite3_column_text(statement, 1))
                let content = String(cString: sqlite3_column_text(statement, 2))
                let created = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                result.append(Message(id: id, role: role, content: content, createdAt: created))
            }
            return result.reversed()
        }
    }

    func messageCount() -> Int {
        queue.sync {
            guard let statement = prepare("SELECT COUNT(*) FROM messages;") else { return 0 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        }
    }

    func userMessageCount() -> Int {
        queue.sync {
            guard let statement = prepare("SELECT COUNT(*) FROM messages WHERE role = 'user';") else { return 0 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        }
    }

    func deleteAllMessages() {
        queue.sync { _ = exec("DELETE FROM messages;") }
    }

    /// 只保留最近 `keep` 条消息，避免数据库无限增长。
    func pruneMessages(keep: Int) {
        let limit = max(50, keep)
        queue.sync {
            guard let statement = prepare("DELETE FROM messages WHERE id NOT IN (SELECT id FROM messages ORDER BY id DESC LIMIT ?);") else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            sqlite3_step(statement)
        }
    }

    // MARK: - 记忆

    @discardableResult
    func upsertMemory(kind: String, content: String, keywords: String) -> Bool {
        let safe = String(content.prefix(300)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return false }
        return queue.sync {
            guard let statement = prepare("""
            INSERT INTO memories(kind, content, keywords, created_at, updated_at, hits)
            VALUES(?, ?, ?, ?, ?, 0)
            ON CONFLICT(content) DO UPDATE SET
                kind = excluded.kind,
                keywords = excluded.keywords,
                updated_at = excluded.updated_at;
            """) else { return false }
            defer { sqlite3_finalize(statement) }
            let now = Date().timeIntervalSince1970
            bind(statement, 1, kind)
            bind(statement, 2, safe)
            bind(statement, 3, keywords)
            sqlite3_bind_double(statement, 4, now)
            sqlite3_bind_double(statement, 5, now)
            return sqlite3_step(statement) == SQLITE_DONE
        }
    }

    func memories(limit: Int = 500) -> [Memory] {
        queue.sync {
            guard let statement = prepare("SELECT id, kind, content, keywords, created_at, updated_at, hits FROM memories ORDER BY updated_at DESC LIMIT ?;") else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 2000))))
            var result: [Memory] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(Memory(
                    id: sqlite3_column_int64(statement, 0),
                    kind: String(cString: sqlite3_column_text(statement, 1)),
                    content: String(cString: sqlite3_column_text(statement, 2)),
                    keywords: String(cString: sqlite3_column_text(statement, 3)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                    hits: Int(sqlite3_column_int(statement, 6))
                ))
            }
            return result
        }
    }

    func memoryCount() -> Int {
        queue.sync {
            guard let statement = prepare("SELECT COUNT(*) FROM memories;") else { return 0 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        }
    }

    func deleteMemory(id: Int64) {
        queue.sync {
            guard let statement = prepare("DELETE FROM memories WHERE id = ?;") else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            sqlite3_step(statement)
        }
    }

    func clearMemories() {
        queue.sync { _ = exec("DELETE FROM memories;") }
    }

    func markMemoriesUsed(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        queue.sync {
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            guard let statement = prepare("UPDATE memories SET hits = hits + 1 WHERE id IN (\(placeholders));") else { return }
            defer { sqlite3_finalize(statement) }
            for (index, id) in ids.enumerated() {
                sqlite3_bind_int64(statement, Int32(index + 1), id)
            }
            sqlite3_step(statement)
        }
    }

    // MARK: - 摘要

    func insertSummary(content: String, coversUntil: Int64) {
        let safe = String(content.prefix(2000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return }
        queue.sync {
            guard let statement = prepare("INSERT INTO summaries(content, created_at, covers_until) VALUES(?, ?, ?);") else { return }
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, safe)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            sqlite3_bind_int64(statement, 3, coversUntil)
            sqlite3_step(statement)
        }
    }

    func latestSummary() -> Summary? {
        queue.sync {
            guard let statement = prepare("SELECT content, created_at FROM summaries ORDER BY id DESC LIMIT 1;") else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Summary(content: String(cString: sqlite3_column_text(statement, 0)),
                           createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)))
        }
    }

    func pruneSummaries(keep: Int) {
        queue.sync {
            guard let statement = prepare("DELETE FROM summaries WHERE id NOT IN (SELECT id FROM summaries ORDER BY id DESC LIMIT ?);") else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(5, keep)))
            sqlite3_step(statement)
        }
    }
}
