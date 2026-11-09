#if canImport(GRDB)
import Foundation
import GRDB

/// Keeps a device's log and tables in SQLite. Each `write` is one SQLite transaction, so a crash
/// or a failure part way through leaves nothing half done.
///
/// Synced data is one row per field, together with the stamp that decides merges. That keeps the
/// sync rules independent of the data model: a new field needs no migration here, and readable
/// tables can be views on top.
public final class SQLiteStore: LocalStore {
    private let writer: any DatabaseWriter
    private let codec = EntryCodec()

    /// Opens a database file, creating it if needed. It uses SQLite's write-ahead log, so reading
    /// never waits for a write.
    public convenience init(path: String) throws {
        try self.init(writer: DatabasePool(path: path))
    }

    /// A database that only lives in memory, for tests and simulations.
    public static func inMemory() throws -> SQLiteStore {
        try SQLiteStore(writer: DatabaseQueue())
    }

    /// An in-memory database holding the same as a snapshot, for simulating backups.
    public static func inMemory(copying snapshot: StoreSnapshot) throws -> SQLiteStore {
        let store = try inMemory()
        try store.importSnapshot(snapshot)
        return store
    }

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    public func read<T>(_ body: (any StoreAccess) throws -> T) throws -> T {
        try writer.read { db in try body(SQLiteAccess(db: db, codec: codec)) }
    }

    public func write<T>(_ body: (any StoreAccess) throws -> T) throws -> T {
        try writer.write { db in try body(SQLiteAccess(db: db, codec: codec)) }
    }

    public func snapshot() throws -> StoreSnapshot {
        try writer.read { db in
            let access = SQLiteAccess(db: db, codec: codec)
            var snapshot = StoreSnapshot()
            snapshot.deviceID = try access.deviceID()
            snapshot.knownDevices = try access.knownDevices()
            for entry in try access.allLogEntries() {
                snapshot.logs[entry.stored.device, default: []].append(entry)
            }
            let rows = try Row.fetchAll(
                db, sql: "SELECT tbl, record, field, kind, value, time, device, seq FROM fields")
            for row in rows {
                let table: String = row["tbl"]
                let record = RecordID(rawValue: row["record"])
                let field: String = row["field"]
                snapshot.tables[table, default: [:]][record, default: [:]][field] =
                    SQLiteAccess.fieldState(from: row)
            }
            return snapshot
        }
    }

    private func importSnapshot(_ snapshot: StoreSnapshot) throws {
        try writer.write { db in
            let access = SQLiteAccess(db: db, codec: codec)
            if let id = snapshot.deviceID {
                try access.setDeviceID(id)
            }
            for (id, name) in snapshot.knownDevices {
                try access.setKnownDevice(id, encryptedName: name)
            }
            for entry in snapshot.logs.values.joined() {
                try access.appendLog(entry)
            }
            for (table, records) in snapshot.tables {
                for (record, fields) in records {
                    for (field, state) in fields {
                        try access.setFieldState(state, field: field, record: record, table: table)
                    }
                }
            }
        }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(
                sql: """
                    CREATE TABLE meta (
                        key TEXT PRIMARY KEY NOT NULL,
                        value TEXT NOT NULL
                    ) WITHOUT ROWID;

                    CREATE TABLE devices (
                        id TEXT PRIMARY KEY NOT NULL,
                        encrypted_name BLOB NOT NULL
                    ) WITHOUT ROWID;

                    -- Every device's entries, exactly as they're stored on the server. The other
                    -- columns are copied from the payload so it can be searched. They're NULL
                    -- for an entry in a newer format, which can't be read yet.
                    CREATE TABLE log (
                        device TEXT NOT NULL,
                        seq INTEGER NOT NULL,
                        payload BLOB NOT NULL,
                        schema INTEGER,
                        tbl TEXT,
                        record TEXT,
                        PRIMARY KEY (device, seq)
                    ) WITHOUT ROWID;

                    CREATE INDEX log_by_record ON log (tbl, record);

                    -- The current value of every synced field and the write that set it.
                    -- kind is 0 for null, 1 for a boolean, 2 for an integer and 3 for text.
                    CREATE TABLE fields (
                        tbl TEXT NOT NULL,
                        record TEXT NOT NULL,
                        field TEXT NOT NULL,
                        kind INTEGER NOT NULL,
                        value,
                        time INTEGER NOT NULL,
                        device TEXT NOT NULL,
                        seq INTEGER NOT NULL,
                        PRIMARY KEY (tbl, record, field)
                    ) WITHOUT ROWID;
                    """)
        }
        return migrator
    }
}

final class SQLiteAccess: StoreAccess {
    private let db: GRDB.Database
    private let codec: EntryCodec

    init(db: GRDB.Database, codec: EntryCodec) {
        self.db = db
        self.codec = codec
    }

    func deviceID() throws -> DeviceID? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'device_id'")
            .map(DeviceID.init(rawValue:))
    }

    func setDeviceID(_ id: DeviceID) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('device_id', ?)",
            arguments: [id.rawValue])
    }

    func knownDevices() throws -> [DeviceID: Data] {
        var devices: [DeviceID: Data] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, encrypted_name FROM devices") {
            devices[DeviceID(rawValue: row["id"])] = row["encrypted_name"]
        }
        return devices
    }

    func setKnownDevice(_ id: DeviceID, encryptedName: Data) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO devices (id, encrypted_name) VALUES (?, ?)",
            arguments: [id.rawValue, encryptedName])
    }

    func high(_ device: DeviceID) throws -> UInt64 {
        let statement = try db.cachedStatement(sql: "SELECT MAX(seq) FROM log WHERE device = ?")
        return UInt64(try Int64.fetchOne(statement, arguments: [device.rawValue]) ?? 0)
    }

    func logEntry(_ device: DeviceID, seq: UInt64) throws -> LogEntry? {
        let statement = try db.cachedStatement(
            sql: "SELECT payload FROM log WHERE device = ? AND seq = ?")
        return try Data.fetchOne(statement, arguments: [device.rawValue, Int64(seq)])
            .map { logEntry(device: device, seq: seq, payload: $0) }
    }

    func logEntries(_ device: DeviceID, after seq: UInt64) throws -> [LogEntry] {
        try Row.fetchAll(
            db, sql: "SELECT seq, payload FROM log WHERE device = ? AND seq > ? ORDER BY seq",
            arguments: [device.rawValue, Int64(seq)]
        ).map { row in
            logEntry(device: device, seq: UInt64(row["seq"] as Int64), payload: row["payload"])
        }
    }

    func logEntries(table: String, record: RecordID) throws -> [LogEntry] {
        try entries(
            sql: "SELECT device, seq, payload FROM log WHERE tbl = ? AND record = ?",
            arguments: [table, record.rawValue])
    }

    func allLogEntries() throws -> [LogEntry] {
        try entries(sql: "SELECT device, seq, payload FROM log ORDER BY device, seq")
    }

    private func entries(sql: String, arguments: StatementArguments = []) throws -> [LogEntry] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
            logEntry(
                device: DeviceID(rawValue: row["device"]),
                seq: UInt64(row["seq"] as Int64),
                payload: row["payload"])
        }
    }

    private func logEntry(device: DeviceID, seq: UInt64, payload: Data) -> LogEntry {
        let stored = StoredEntry(device: device, seq: seq, payload: payload)
        let decoded: ChangeEntry? =
            if case .entry(let entry)? = try? codec.decode(stored) { entry } else { nil }
        return LogEntry(stored: stored, decoded: decoded)
    }

    func appendLog(_ entry: LogEntry) throws {
        let statement = try db.cachedStatement(
            sql: """
                INSERT INTO log (device, seq, payload, schema, tbl, record)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
        try statement.execute(arguments: [
            entry.stored.device.rawValue,
            Int64(entry.stored.seq),
            entry.stored.payload,
            entry.decoded?.schema,
            entry.decoded?.table,
            entry.decoded?.record.rawValue,
        ])
    }

    func replaceLog(of device: DeviceID, with entries: [LogEntry]) throws {
        try db.execute(sql: "DELETE FROM log WHERE device = ?", arguments: [device.rawValue])
        for entry in entries {
            try appendLog(entry)
        }
    }

    func heldBackCount(supportedSchema: Int) throws -> Int {
        try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM log WHERE schema IS NULL OR schema > ?",
            arguments: [supportedSchema]) ?? 0
    }

    func fieldState(_ field: String, record: RecordID, table: String) throws -> FieldState? {
        let statement = try db.cachedStatement(
            sql: """
                SELECT kind, value, time, device, seq FROM fields
                WHERE tbl = ? AND record = ? AND field = ?
                """)
        return try Row.fetchOne(statement, arguments: [table, record.rawValue, field])
            .map(Self.fieldState(from:))
    }

    func fields(of record: RecordID, table: String) throws -> [String: FieldState]? {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT field, kind, value, time, device, seq FROM fields WHERE tbl = ? AND record = ?",
            arguments: [table, record.rawValue])
        guard !rows.isEmpty else { return nil }
        var fields: [String: FieldState] = [:]
        for row in rows {
            fields[row["field"]] = Self.fieldState(from: row)
        }
        return fields
    }

    func records(in table: String) throws -> [RecordID: [String: FieldState]] {
        var records: [RecordID: [String: FieldState]] = [:]
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT record, field, kind, value, time, device, seq FROM fields WHERE tbl = ?",
            arguments: [table])
        for row in rows {
            let field: String = row["field"]
            records[RecordID(rawValue: row["record"]), default: [:]][field] = Self.fieldState(from: row)
        }
        return records
    }

    func setFieldState(_ state: FieldState, field: String, record: RecordID, table: String) throws {
        let kind: Int
        let value: (any DatabaseValueConvertible)?
        switch state.value {
        case .null: (kind, value) = (0, nil)
        case .bool(let flag): (kind, value) = (1, flag ? 1 : 0)
        case .int(let number): (kind, value) = (2, number)
        case .string(let text): (kind, value) = (3, text)
        }
        let statement = try db.cachedStatement(
            sql: """
                INSERT OR REPLACE INTO fields (tbl, record, field, kind, value, time, device, seq)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
        try statement.execute(arguments: [
            table, record.rawValue, field, kind, value, state.stamp.time,
            state.stamp.device.rawValue, Int64(state.stamp.seq),
        ])
    }

    func removeAllFields() throws {
        try db.execute(sql: "DELETE FROM fields")
    }

    static func fieldState(from row: Row) -> FieldState {
        let kind: Int = row["kind"]
        let value: FieldValue
        switch kind {
        case 1: value = .bool((row["value"] as Int64) != 0)
        case 2: value = .int(row["value"])
        case 3: value = .string(row["value"])
        default: value = .null
        }
        return FieldState(
            value: value,
            stamp: Stamp(
                time: row["time"],
                device: DeviceID(rawValue: row["device"]),
                seq: UInt64(row["seq"] as Int64)))
    }
}
#endif
