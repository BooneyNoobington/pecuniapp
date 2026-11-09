import Foundation

/// A field's current value and the write that set it.
public struct FieldState: Hashable, Sendable {
    public var value: FieldValue
    public var stamp: Stamp
}

/// An entry in the local log. `decoded` is nil if a newer app version wrote it in a format this
/// one can't read. It's kept anyway, so the log stays complete and can be uploaded again.
public struct LogEntry: Hashable, Sendable {
    public var stored: StoredEntry
    public var decoded: ChangeEntry?
}

public typealias Tables = [String: [RecordID: [String: FieldState]]]

/// Everything a local store holds, as one value. Used to compare devices in tests, for exports,
/// and to simulate backups. `MemoryStore` keeps exactly this.
public struct StoreSnapshot: Equatable, Sendable {
    public internal(set) var deviceID: DeviceID?
    /// Every device's entries, numbered from 1 without gaps, so an entry sits at `seq - 1`.
    public internal(set) var logs: [DeviceID: [LogEntry]] = [:]
    public internal(set) var tables: Tables = [:]
    /// Every device this one has heard of, with its encrypted name, so a device can register
    /// the others again if the server loses them.
    public internal(set) var knownDevices: [DeviceID: Data] = [:]

    public init() {}

    // MARK: Reading

    public func high(_ device: DeviceID) -> UInt64 {
        UInt64(logs[device]?.count ?? 0)
    }

    public func state(of field: String, record: RecordID, table: String) -> FieldState? {
        tables[table]?[record]?[field]
    }

    public func value(of field: String, record: RecordID, table: String) -> FieldValue? {
        state(of: field, record: record, table: table)?.value
    }

    /// A record's fields whether it's deleted or not, or nil if it hasn't arrived here.
    public func record(_ id: RecordID, in table: String) -> [String: FieldValue]? {
        tables[table]?[id]?.mapValues(\.value)
    }

    public func isDeleted(_ id: RecordID, in table: String) -> Bool {
        Device.isDeleted(tables[table]?[id] ?? [:])
    }

    public func liveRecords(in table: String) -> [RecordID: [String: FieldValue]] {
        Device.liveRecords(tables[table] ?? [:])
    }

    /// Every value a field has held, oldest first. An overwritten value stays here for good.
    public func history(of field: String, record: RecordID, table: String) -> [FieldState] {
        Device.history(of: field, record: record, table: table, in: logs.values.joined())
    }

    // MARK: Merging

    /// Applies one entry to a set of tables, using the same rule as every store.
    static func apply(_ entry: ChangeEntry, to tables: inout Tables) {
        var snapshot = StoreSnapshot()
        snapshot.tables = tables
        let access = MemoryAccess(snapshot)
        access.applyWithoutFailing(entry)
        tables = access.data.tables
    }

    /// The tables worked out from the log alone. They must always match `tables`.
    public func rebuiltTables(supportedSchema: Int) -> Tables {
        let access = MemoryAccess(self)
        access.recalculateTablesWithoutFailing(supportedSchema: supportedSchema)
        return access.data.tables
    }
}

/// Keeps everything in memory. It's the reference that the SQLite store is checked against,
/// and the large simulations run on it, because it's fast.
public final class MemoryStore: LocalStore {
    private var data: StoreSnapshot

    public init(_ data: StoreSnapshot = StoreSnapshot()) {
        self.data = data
    }

    public func read<T>(_ body: (any StoreAccess) throws -> T) throws -> T {
        try body(MemoryAccess(data))
    }

    public func write<T>(_ body: (any StoreAccess) throws -> T) throws -> T {
        // Changes go to a copy, which only replaces the original if nothing threw.
        let access = MemoryAccess(data)
        let result = try body(access)
        data = access.data
        return result
    }

    public func snapshot() -> StoreSnapshot {
        data
    }
}

final class MemoryAccess: StoreAccess {
    var data: StoreSnapshot

    init(_ data: StoreSnapshot) {
        self.data = data
    }

    func deviceID() -> DeviceID? { data.deviceID }
    func setDeviceID(_ id: DeviceID) { data.deviceID = id }

    func knownDevices() -> [DeviceID: Data] { data.knownDevices }
    func setKnownDevice(_ id: DeviceID, encryptedName: Data) { data.knownDevices[id] = encryptedName }

    func high(_ device: DeviceID) -> UInt64 { data.high(device) }

    func logEntry(_ device: DeviceID, seq: UInt64) -> LogEntry? {
        guard let log = data.logs[device], seq >= 1, seq <= UInt64(log.count) else { return nil }
        return log[Int(seq) - 1]
    }

    func logEntries(_ device: DeviceID, after seq: UInt64) -> [LogEntry] {
        let log = data.logs[device] ?? []
        guard seq < UInt64(log.count) else { return [] }
        return Array(log[Int(seq)...])
    }

    func logEntries(table: String, record: RecordID) -> [LogEntry] {
        data.logs.values.joined().filter { $0.decoded?.table == table && $0.decoded?.record == record }
    }

    func allLogEntries() -> [LogEntry] {
        Array(data.logs.values.joined())
    }

    func appendLog(_ entry: LogEntry) {
        data.logs[entry.stored.device, default: []].append(entry)
    }

    func replaceLog(of device: DeviceID, with entries: [LogEntry]) {
        data.logs[device] = entries.isEmpty ? nil : entries
    }

    func heldBackCount(supportedSchema: Int) -> Int {
        data.logs.values.joined().filter { entry in
            guard let decoded = entry.decoded else { return true }
            return decoded.schema > supportedSchema
        }.count
    }

    func fieldState(_ field: String, record: RecordID, table: String) -> FieldState? {
        data.tables[table]?[record]?[field]
    }

    func fields(of record: RecordID, table: String) -> [String: FieldState]? {
        data.tables[table]?[record]
    }

    func records(in table: String) -> [RecordID: [String: FieldState]] {
        data.tables[table] ?? [:]
    }

    func setFieldState(_ state: FieldState, field: String, record: RecordID, table: String) {
        data.tables[table, default: [:]][record, default: [:]][field] = state
    }

    func removeAllFields() {
        data.tables = [:]
    }

    // Nothing in memory can fail, so these don't need to throw.

    func applyWithoutFailing(_ entry: ChangeEntry) {
        try! apply(entry)
    }

    func recalculateTablesWithoutFailing(supportedSchema: Int) {
        try! recalculateTables(supportedSchema: supportedSchema)
    }
}
