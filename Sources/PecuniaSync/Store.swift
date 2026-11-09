import Foundation

/// The operations the sync core needs from local storage, inside one transaction.
///
/// The methods are deliberately simple, so that each storage implementation is easy to check,
/// and the rules for merging live in one place, in the extension below.
public protocol StoreAccess {
    func deviceID() throws -> DeviceID?
    func setDeviceID(_ id: DeviceID) throws

    func knownDevices() throws -> [DeviceID: Data]
    func setKnownDevice(_ id: DeviceID, encryptedName: Data) throws

    /// The highest number in a device's log, which is also how many entries it holds.
    func high(_ device: DeviceID) throws -> UInt64
    func logEntry(_ device: DeviceID, seq: UInt64) throws -> LogEntry?
    func logEntries(_ device: DeviceID, after seq: UInt64) throws -> [LogEntry]
    func logEntries(table: String, record: RecordID) throws -> [LogEntry]
    func allLogEntries() throws -> [LogEntry]
    func appendLog(_ entry: LogEntry) throws
    func replaceLog(of device: DeviceID, with entries: [LogEntry]) throws
    /// How many entries are stored but can't be applied until the app is updated.
    func heldBackCount(supportedSchema: Int) throws -> Int

    func fieldState(_ field: String, record: RecordID, table: String) throws -> FieldState?
    func fields(of record: RecordID, table: String) throws -> [String: FieldState]?
    func records(in table: String) throws -> [RecordID: [String: FieldState]]
    func setFieldState(_ state: FieldState, field: String, record: RecordID, table: String) throws
    func removeAllFields() throws
}

public enum StoreError: Error, Equatable {
    /// An entry doesn't follow on from the last one in its device's log.
    case entryOutOfOrder(device: DeviceID, seq: UInt64)
}

/// Where a device keeps its log and the tables worked out from it.
public protocol LocalStore: AnyObject {
    func read<T>(_ body: (any StoreAccess) throws -> T) throws -> T
    /// Runs `body` as one transaction. If anything in it throws, none of its changes are kept.
    func write<T>(_ body: (any StoreAccess) throws -> T) throws -> T
    /// Everything in the store as one value, for checks, exports and backups.
    func snapshot() throws -> StoreSnapshot
}

extension StoreAccess {
    /// For each field, the newest stamp wins. Applying entries is therefore commutative and
    /// idempotent, which is what makes the order they arrive in irrelevant.
    func apply(_ entry: ChangeEntry) throws {
        let stamp = entry.stamp
        for (name, value) in entry.fields {
            if let current = try fieldState(name, record: entry.record, table: entry.table),
                current.stamp >= stamp
            {
                continue
            }
            try setFieldState(
                FieldState(value: value, stamp: stamp), field: name, record: entry.record,
                table: entry.table)
        }
    }

    /// Adds an entry to its device's log and applies it, unless it's from a newer app version.
    func append(_ stored: StoredEntry, decoded: ChangeEntry?, supportedSchema: Int) throws {
        guard try high(stored.device) + 1 == stored.seq else {
            throw StoreError.entryOutOfOrder(device: stored.device, seq: stored.seq)
        }
        try appendLog(LogEntry(stored: stored, decoded: decoded))
        if let decoded, decoded.schema <= supportedSchema {
            try apply(decoded)
        }
    }

    /// Works the tables out from the log again, for when the log itself has changed.
    func recalculateTables(supportedSchema: Int) throws {
        try removeAllFields()
        for entry in try allLogEntries() {
            if let decoded = entry.decoded, decoded.schema <= supportedSchema {
                try apply(decoded)
            }
        }
    }
}
