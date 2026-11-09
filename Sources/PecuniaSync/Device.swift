import Foundation

public enum DeviceError: Error, Equatable {
    case notOpen
    /// The Keychain can't be read yet, for example in the background before first unlock.
    /// That means wait, not missing, or every reboot could create a new device ID.
    case identityStoreLocked
    case nothingToWrite
    case alreadySyncing
}

public enum StoredIdentity: Equatable, Sendable {
    case found(DeviceID)
    case missing
    case locked
}

/// Keeps the device ID somewhere that doesn't move with a backup, which is the Keychain in the
/// real app. It's what reveals that a database was copied here from another device.
public protocol DeviceIdentityStore: AnyObject {
    func read() -> StoredIdentity
    func write(_ id: DeviceID)
}

/// The outside world a device depends on, so that tests can control it.
public struct DeviceEnvironment {
    /// Milliseconds since 1970 according to this device, which may be wrong.
    public var now: () -> Int64
    public var random: () -> UInt64

    public init(now: @escaping () -> Int64, random: @escaping () -> UInt64) {
        self.now = now
        self.random = random
    }

    public static var system: DeviceEnvironment {
        DeviceEnvironment(
            now: { Int64(Date().timeIntervalSince1970 * 1000) },
            random: { UInt64.random(in: .min ... .max) }
        )
    }
}

/// One device's view of the data: its local store plus the rules for changing and syncing it.
public final class Device {
    public static let deletedAt = "deleted_at"

    public let store: any LocalStore
    public internal(set) var supportedSchema: Int
    /// How far a clock may differ from the server's before the sync status warns about it.
    public var clockWarningThreshold: Int64 = 3_600_000

    public let name: String
    let identity: any DeviceIdentityStore
    let environment: DeviceEnvironment
    let codec = EntryCodec()
    var isSyncing = false

    public init(
        store: any LocalStore = MemoryStore(),
        identity: any DeviceIdentityStore,
        environment: DeviceEnvironment = .system,
        name: String,
        supportedSchema: Int = 1
    ) {
        self.store = store
        self.identity = identity
        self.environment = environment
        self.name = name
        self.supportedSchema = supportedSchema
    }

    // MARK: Identity

    /// Must run on launch, before any write. If the ID in the Keychain doesn't match the one in
    /// the database, the database is a copy, so this device takes an ID of its own.
    public func open() throws {
        let stored = identity.read()
        if stored == .locked {
            throw DeviceError.identityStoreLocked
        }
        let newID: DeviceID? = try store.write { tx in
            if case .found(let id) = stored, try tx.deviceID() == id {
                return nil
            }
            return try takeNewDeviceID(tx)
        }
        if let newID {
            identity.write(newID)
        }
    }

    /// Records a new ID in the database. The caller puts it in the identity store once the
    /// transaction has been saved, so a failed transaction can't leave the two out of step.
    func takeNewDeviceID(_ tx: any StoreAccess) throws -> DeviceID {
        let id = DeviceID.random(environment.random)
        try tx.setDeviceID(id)
        try tx.setKnownDevice(id, encryptedName: Data(name.utf8))
        return id
    }

    // MARK: Reading

    public func deviceID() throws -> DeviceID? {
        try store.read { try $0.deviceID() }
    }

    public func state(of field: String, record: RecordID, table: String) throws -> FieldState? {
        try store.read { try $0.fieldState(field, record: record, table: table) }
    }

    public func value(of field: String, record: RecordID, table: String) throws -> FieldValue? {
        try state(of: field, record: record, table: table)?.value
    }

    /// A record's fields whether it's deleted or not, or nil if it hasn't arrived here.
    public func record(_ id: RecordID, in table: String) throws -> [String: FieldValue]? {
        try store.read { try $0.fields(of: id, table: table)?.mapValues(\.value) }
    }

    public func isDeleted(_ id: RecordID, in table: String) throws -> Bool {
        try store.read { try Self.isDeleted($0.fields(of: id, table: table) ?? [:]) }
    }

    public func liveRecords(in table: String) throws -> [RecordID: [String: FieldValue]] {
        try store.read { try Self.liveRecords($0.records(in: table)) }
    }

    /// Every value a field has held, oldest first. An overwritten value stays here for good.
    public func history(of field: String, record: RecordID, table: String) throws -> [FieldState] {
        try store.read {
            try Self.history(
                of: field, record: record, table: table,
                in: $0.logEntries(table: table, record: record))
        }
    }

    /// How many entries are stored but can't be applied until the app is updated.
    public func heldBackCount() throws -> Int {
        try store.read { [supportedSchema] in try $0.heldBackCount(supportedSchema: supportedSchema) }
    }

    public func snapshot() throws -> StoreSnapshot {
        try store.snapshot()
    }

    static func isDeleted(_ fields: [String: FieldState]) -> Bool {
        guard let deleted = fields[deletedAt] else { return false }
        return !deleted.value.isNull
    }

    static func liveRecords(
        _ records: [RecordID: [String: FieldState]]
    ) -> [RecordID: [String: FieldValue]] {
        records.filter { !isDeleted($0.value) }.mapValues { $0.mapValues(\.value) }
    }

    static func history(
        of field: String,
        record: RecordID,
        table: String,
        in entries: some Sequence<LogEntry>
    ) -> [FieldState] {
        var versions: [FieldState] = []
        for entry in entries {
            guard let decoded = entry.decoded, decoded.table == table, decoded.record == record,
                let value = decoded.fields[field]
            else { continue }
            versions.append(FieldState(value: value, stamp: decoded.stamp))
        }
        return versions.sorted { $0.stamp < $1.stamp }
    }

    // MARK: Writing

    /// Writes fields to a record and logs the change, as one transaction.
    @discardableResult
    public func write(
        _ table: String,
        _ record: RecordID,
        _ fields: [String: FieldValue]
    ) throws -> ChangeEntry {
        guard !fields.isEmpty else { throw DeviceError.nothingToWrite }
        return try store.write { tx in
            try writeEntry(tx, table: table, record: record, fields: fields)
        }
    }

    /// Writes fields inside a transaction that's already open, so several writes can be one.
    @discardableResult
    func writeEntry(
        _ tx: any StoreAccess,
        table: String,
        record: RecordID,
        fields: [String: FieldValue]
    ) throws -> ChangeEntry {
        try appendEntry(
            tx,
            table: table,
            record: record,
            fields: fields,
            time: writeTime(tx, table: table, record: record, fields: fields.keys),
            schema: supportedSchema
        )
    }

    /// The current time or just past the values being overwritten, whichever is later, so an
    /// edit always beats what it replaces even if this device's clock is wrong.
    private func writeTime(
        _ tx: any StoreAccess,
        table: String,
        record: RecordID,
        fields: some Collection<String>
    ) throws -> Int64 {
        let now = environment.now()
        var newest: Int64?
        for field in fields {
            if let time = try tx.fieldState(field, record: record, table: table)?.stamp.time {
                newest = max(newest ?? time, time)
            }
        }
        guard let newest else { return now }
        return max(now, newest == .max ? newest : newest + 1)
    }

    /// Adds an entry to the end of this device's own log and applies it.
    @discardableResult
    func appendEntry(
        _ tx: any StoreAccess,
        table: String,
        record: RecordID,
        fields: [String: FieldValue],
        time: Int64,
        schema: Int
    ) throws -> ChangeEntry {
        guard let me = try tx.deviceID() else { throw DeviceError.notOpen }
        let seq = try tx.high(me) + 1
        let entry = ChangeEntry(
            format: ChangeEntry.currentFormat,
            schema: schema,
            device: me,
            seq: seq,
            id: newEntryID(),
            previous: seq > 1 ? try tx.logEntry(me, seq: seq - 1)?.decoded?.id : nil,
            table: table,
            record: record,
            fields: fields,
            time: time
        )
        let stored = StoredEntry(device: me, seq: seq, payload: try codec.encode(entry))
        try tx.append(stored, decoded: entry, supportedSchema: supportedSchema)
        return entry
    }

    private func newEntryID() -> String {
        String(environment.random(), radix: 16)
    }

    @discardableResult
    public func create(_ table: String, _ fields: [String: FieldValue]) throws -> RecordID {
        let id = RecordID.new(now: environment.now(), random: environment.random)
        try write(table, id, fields)
        return id
    }

    /// Marks a record as deleted. It's an ordinary field, so an edit elsewhere doesn't undo it.
    public func delete(_ table: String, _ record: RecordID) throws {
        try write(table, record, [Self.deletedAt: .int(environment.now())])
    }

    public func restore(_ table: String, _ record: RecordID) throws {
        try write(table, record, [Self.deletedAt: .null])
    }

    // MARK: App updates

    /// Applies what was held back for this version.
    public func appUpdated(toSchema schema: Int) throws {
        supportedSchema = max(supportedSchema, schema)
        try store.write { [supportedSchema] in
            try $0.recalculateTables(supportedSchema: supportedSchema)
        }
    }
}
