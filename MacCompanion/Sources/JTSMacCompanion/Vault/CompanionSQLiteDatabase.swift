import Foundation
import SQLite3

final class CompanionSQLiteDatabase {
    private static let lockWaitMilliseconds: Int32 = 5_000
    private let handle: OpaquePointer?
    private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open SQLite database."
            if let database {
                sqlite3_close(database)
            }
            throw CompanionVaultError.database(message)
        }

        self.handle = database
        // FULLMUTEX protects this connection, not the independent connections
        // used by RDP, Companion persistence, and other vault instances.
        guard sqlite3_busy_timeout(database, Self.lockWaitMilliseconds) == SQLITE_OK else {
            throw CompanionVaultError.database("Unable to configure the credential database lock wait.")
        }
        try executeSchema()
    }

    deinit {
        sqlite3_close(handle)
    }

    func withWriteTransaction(_ operation: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try operation()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func containsRecords() throws -> Bool {
        let statement = try prepare("SELECT 1 FROM credentials LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw CompanionVaultError.database(lastErrorMessage)
        }
        return result == SQLITE_ROW
    }

    func write(_ record: CompanionEncryptedRecord, createOnly: Bool) throws {
        var sql = """
        INSERT INTO credentials (
            account, wrapped_key, nonce, ciphertext, tag, algorithm, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        if !createOnly {
            sql += """

        ON CONFLICT(account) DO UPDATE SET
            wrapped_key = excluded.wrapped_key,
            nonce = excluded.nonce,
            ciphertext = excluded.ciphertext,
            tag = excluded.tag,
            algorithm = excluded.algorithm,
            updated_at = excluded.updated_at;
        """
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(record.account, at: 1, in: statement)
        try bind(record.wrappedKey, at: 2, in: statement)
        try bind(record.nonce, at: 3, in: statement)
        try bind(record.ciphertext, at: 4, in: statement)
        try bind(record.tag, at: 5, in: statement)
        try bind(record.algorithm, at: 6, in: statement)
        try bind(record.createdAt, at: 7, in: statement)
        try bind(record.updatedAt, at: 8, in: statement)
        try stepDone(statement)
    }

    func fetch(account: String) throws -> CompanionEncryptedRecord? {
        let sql = """
        SELECT account, wrapped_key, nonce, ciphertext, tag, algorithm, created_at, updated_at
        FROM credentials
        WHERE account = ?
        LIMIT 1;
        """

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        try bind(account, at: 1, in: statement)
        let stepResult = sqlite3_step(statement)
        if stepResult == SQLITE_DONE {
            return nil
        }
        guard stepResult == SQLITE_ROW else {
            throw CompanionVaultError.database(lastErrorMessage)
        }

        return CompanionEncryptedRecord(
            account: stringColumn(0, in: statement),
            wrappedKey: dataColumn(1, in: statement),
            nonce: dataColumn(2, in: statement),
            ciphertext: dataColumn(3, in: statement),
            tag: dataColumn(4, in: statement),
            algorithm: stringColumn(5, in: statement),
            createdAt: stringColumn(6, in: statement),
            updatedAt: stringColumn(7, in: statement)
        )
    }

    func delete(account: String) throws {
        let statement = try prepare("DELETE FROM credentials WHERE account = ?;")
        defer { sqlite3_finalize(statement) }

        try bind(account, at: 1, in: statement)
        try stepDone(statement)
    }

    private func executeSchema() throws {
        try configureJournalMode()
        try execute("PRAGMA synchronous=FULL;")
        try execute("PRAGMA fullfsync=ON;")
        try execute("PRAGMA foreign_keys=ON;")
        // Opening an initialized vault for a read must not acquire a writer
        // lock by updating an unchanged schema-version row.
        if try schemaIsInitialized() { return }
        try withWriteTransaction {
            // Another process may have initialized the empty database while
            // this connection waited for the writer lock.
            if try schemaIsInitialized() { return }
            try execute("""
            CREATE TABLE credentials (
                account TEXT PRIMARY KEY NOT NULL,
                wrapped_key BLOB NOT NULL,
                nonce BLOB NOT NULL,
                ciphertext BLOB NOT NULL,
                tag BLOB NOT NULL,
                algorithm TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );
            CREATE TABLE metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            );
            INSERT INTO metadata (key, value) VALUES ('schema_version', '1');
            """)
            guard try schemaIsInitialized() else {
                throw CompanionVaultError.database("Credential database initialization did not complete.")
            }
        }
    }

    private func configureJournalMode() throws {
        // Changing a fresh rollback-journal database to WAL can require a lock
        // upgrade for which SQLite skips its busy handler. Finalize each probe
        // before retrying so competing initializers can finish that transition.
        let deadline = ProcessInfo.processInfo.systemUptime + Double(Self.lockWaitMilliseconds) / 1_000
        defer { sqlite3_busy_timeout(handle, Self.lockWaitMilliseconds) }
        var failure = "Credential database journal initialization remained busy."
        while true {
            let remaining = Int32(max(0, (deadline - ProcessInfo.processInfo.systemUptime) * 1_000))
            guard remaining > 0 else { throw CompanionVaultError.database(failure) }
            sqlite3_busy_timeout(handle, remaining)
            var result = journalModeResult("PRAGMA journal_mode;")
            if result.code == SQLITE_ROW, result.mode == "wal" { return }
            if result.code == SQLITE_ROW {
                let transitionWait = Int32(max(0, (deadline - ProcessInfo.processInfo.systemUptime) * 1_000))
                guard transitionWait > 0 else { throw CompanionVaultError.database(failure) }
                sqlite3_busy_timeout(handle, transitionWait)
                result = journalModeResult("PRAGMA journal_mode=WAL;")
            }
            if result.code == SQLITE_ROW, result.mode == "wal" { return }
            failure = result.code == SQLITE_ROW
                ? "Credential database could not enable WAL journaling." : result.message
            let primaryCode = result.code & 0xff
            guard primaryCode == SQLITE_BUSY || primaryCode == SQLITE_LOCKED else {
                throw CompanionVaultError.database(failure)
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CompanionVaultError.database(failure)
            }
            sqlite3_sleep(10)
        }
    }

    private func journalModeResult(_ sql: String) -> (code: Int32, mode: String?, message: String) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else { return (prepared, nil, lastErrorMessage) }
        let result = sqlite3_step(statement)
        return (result, result == SQLITE_ROW ? stringColumn(0, in: statement) : nil, lastErrorMessage)
    }

    /// Only an empty database may be initialized. Partial or unsupported schema
    /// is never repaired by overwriting its version or recreating missing tables.
    private func schemaIsInitialized() throws -> Bool {
        let objects = try prepare("SELECT name, type FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';")
        var names = Set<String>()
        var hasObjects = false
        do {
            defer { sqlite3_finalize(objects) }
            var result = sqlite3_step(objects)
            while result == SQLITE_ROW {
                hasObjects = true
                let name = stringColumn(0, in: objects)
                if name == "credentials" || name == "metadata" {
                    guard stringColumn(1, in: objects) == "table" else { throw invalidSchema }
                    names.insert(name)
                }
                result = sqlite3_step(objects)
            }
            guard result == SQLITE_DONE else { throw CompanionVaultError.database(lastErrorMessage) }
        }
        if !hasObjects { return false }
        guard names == ["credentials", "metadata"] else { throw invalidSchema }
        try validateColumns("credentials", expected: [
            ("account", "TEXT", 1), ("wrapped_key", "BLOB", 0), ("nonce", "BLOB", 0),
            ("ciphertext", "BLOB", 0), ("tag", "BLOB", 0), ("algorithm", "TEXT", 0),
            ("created_at", "TEXT", 0), ("updated_at", "TEXT", 0),
        ])
        try validateColumns("metadata", expected: [("key", "TEXT", 1), ("value", "TEXT", 0)])
        let version = try prepare("SELECT value FROM metadata WHERE key = 'schema_version';")
        defer { sqlite3_finalize(version) }
        let result = sqlite3_step(version)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { throw invalidSchema }
            throw CompanionVaultError.database(lastErrorMessage)
        }
        guard stringColumn(0, in: version) == "1", sqlite3_step(version) == SQLITE_DONE else { throw invalidSchema }
        return true
    }

    private func validateColumns(_ table: String, expected: [(String, String, Int32)]) throws {
        // table is one of the two fixed internal names above, never caller input.
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        var index = 0
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard index < expected.count,
                  stringColumn(1, in: statement) == expected[index].0,
                  stringColumn(2, in: statement).uppercased() == expected[index].1,
                  sqlite3_column_int(statement, 3) == 1,
                  sqlite3_column_int(statement, 5) == expected[index].2 else { throw invalidSchema }
            index += 1
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw CompanionVaultError.database(lastErrorMessage) }
        guard index == expected.count else { throw invalidSchema }
    }

    private var invalidSchema: CompanionVaultError { .database("Credential database schema is incomplete or unsupported.") }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage
            sqlite3_free(errorMessage)
            throw CompanionVaultError.database(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw CompanionVaultError.database(lastErrorMessage)
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw CompanionVaultError.database(lastErrorMessage)
        }
    }

    private func bind(_ value: Data, at index: Int32, in statement: OpaquePointer?) throws {
        let result = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(value.count), sqliteTransient)
        }
        guard result == SQLITE_OK else {
            throw CompanionVaultError.database(lastErrorMessage)
        }
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CompanionVaultError.database(lastErrorMessage)
        }
    }

    private func stringColumn(_ index: Int32, in statement: OpaquePointer?) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func dataColumn(_ index: Int32, in statement: OpaquePointer?) -> Data {
        let byteCount = sqlite3_column_bytes(statement, index)
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: Int(byteCount))
    }

    private var lastErrorMessage: String {
        guard let handle, let message = sqlite3_errmsg(handle) else {
            return "Unknown SQLite error."
        }
        return String(cString: message)
    }
}
