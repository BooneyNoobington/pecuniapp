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

/// One device's view of the data: its database plus the rules for changing and syncing it.
public final class Device {
    public internal(set) var database: Database
    public internal(set) var supportedSchema: Int
    /// How far a clock may differ from the server's before the sync status warns about it.
    public var clockWarningThreshold: Int64 = 3_600_000

    public let name: String
    let identity: any DeviceIdentityStore
    let environment: DeviceEnvironment
    let codec = EntryCodec()
    var isSyncing = false

    public init(
        database: Database = Database(),
        identity: any DeviceIdentityStore,
        environment: DeviceEnvironment = .system,
        name: String,
        supportedSchema: Int = 1
    ) {
        self.database = database
        self.identity = identity
        self.environment = environment
        self.name = name
        self.supportedSchema = supportedSchema
    }

    // MARK: Identity

    /// Must run on launch, before any write. If the ID in the Keychain doesn't match the one in
    /// the database, the database is a copy, so this device takes an ID of its own.
    public func open() throws {
        switch identity.read() {
        case .locked:
            throw DeviceError.identityStoreLocked
        case .found(let stored):
            if database.deviceID != stored {
                takeNewDeviceID()
            }
        case .missing:
            takeNewDeviceID()
        }
    }

    func takeNewDeviceID() {
        let id = DeviceID.random(environment.random)
        database.deviceID = id
        database.knownDevices[id] = Data(name.utf8)
        identity.write(id)
    }

    // MARK: Writing

    /// Writes fields to a record and logs the change, as one transaction.
    @discardableResult
    public func write(
        _ table: String,
        _ record: RecordID,
        _ fields: [String: FieldValue]
    ) throws -> ChangeEntry {
        guard database.deviceID != nil else { throw DeviceError.notOpen }
        guard !fields.isEmpty else { throw DeviceError.nothingToWrite }
        return try appendEntry(
            table: table,
            record: record,
            fields: fields,
            time: writeTime(table: table, record: record, fields: fields.keys),
            schema: supportedSchema
        )
    }

    /// Adds an entry to the end of this device's own log and applies it.
    @discardableResult
    func appendEntry(
        table: String,
        record: RecordID,
        fields: [String: FieldValue],
        time: Int64,
        schema: Int
    ) throws -> ChangeEntry {
        guard let me = database.deviceID else { throw DeviceError.notOpen }
        let entry = ChangeEntry(
            format: ChangeEntry.currentFormat,
            schema: schema,
            device: me,
            seq: database.high(me) + 1,
            id: newEntryID(),
            previous: database.logs[me]?.last?.decoded?.id,
            table: table,
            record: record,
            fields: fields,
            time: time
        )
        let stored = StoredEntry(device: me, seq: entry.seq, payload: try codec.encode(entry))
        database.append(stored, decoded: entry, supportedSchema: supportedSchema)
        return entry
    }

    private func newEntryID() -> String {
        String(environment.random(), radix: 16)
    }

    /// The current time or just past the values being overwritten, whichever is later, so an
    /// edit always beats what it replaces even if this device's clock is wrong.
    private func writeTime(
        table: String,
        record: RecordID,
        fields: Dictionary<String, FieldValue>.Keys
    ) -> Int64 {
        let now = environment.now()
        let newest = fields.compactMap {
            database.state(of: $0, record: record, table: table)?.stamp.time
        }.max()
        guard let newest else { return now }
        return max(now, newest == .max ? newest : newest + 1)
    }

    @discardableResult
    public func create(_ table: String, _ fields: [String: FieldValue]) throws -> RecordID {
        let id = RecordID.new(now: environment.now(), random: environment.random)
        try write(table, id, fields)
        return id
    }

    /// Marks a record as deleted. It's an ordinary field, so an edit elsewhere doesn't undo it.
    public func delete(_ table: String, _ record: RecordID) throws {
        try write(table, record, [Database.deletedAt: .int(environment.now())])
    }

    public func restore(_ table: String, _ record: RecordID) throws {
        try write(table, record, [Database.deletedAt: .null])
    }

    // MARK: App updates

    /// Applies what was held back for this version.
    public func appUpdated(toSchema schema: Int) {
        supportedSchema = max(supportedSchema, schema)
        recalculateTables()
    }

    /// Works the tables out from the log again, for when the log itself has changed.
    func recalculateTables() {
        database.tables = database.rebuiltTables(supportedSchema: supportedSchema)
        var heldBack = 0
        for log in database.logs.values {
            for entry in log {
                if let decoded = entry.decoded, decoded.schema <= supportedSchema { continue }
                heldBack += 1
            }
        }
        database.heldBackCount = heldBack
    }
}
