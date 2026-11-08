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

/// Everything that lives in the local database, so everything that a backup brings back.
///
/// This is an in-memory value for now, which makes backups and restores trivial to simulate.
/// Each mutating method corresponds to one database transaction once this moves to SQLite.
public struct Database: Equatable, Sendable {
    public static let deletedAt = "deleted_at"

    public internal(set) var deviceID: DeviceID?
    /// Every device's entries, numbered from 1 without gaps, so an entry sits at `seq - 1`.
    public internal(set) var logs: [DeviceID: [LogEntry]] = [:]
    public internal(set) var tables: Tables = [:]
    /// Every device this one has heard of, with its encrypted name, so a device can register
    /// the others again if the server loses them.
    public internal(set) var knownDevices: [DeviceID: Data] = [:]
    /// How many log entries are stored but not applied until the app is updated.
    public internal(set) var heldBackCount = 0

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
        guard let value = value(of: Self.deletedAt, record: id, table: table) else { return false }
        return !value.isNull
    }

    public func liveRecords(in table: String) -> [RecordID: [String: FieldValue]] {
        var result: [RecordID: [String: FieldValue]] = [:]
        for (id, fields) in tables[table] ?? [:] {
            if let deleted = fields[Self.deletedAt], !deleted.value.isNull { continue }
            result[id] = fields.mapValues(\.value)
        }
        return result
    }

    /// Every value a field has held, oldest first. An overwritten value stays here for good.
    public func history(of field: String, record: RecordID, table: String) -> [FieldState] {
        var versions: [FieldState] = []
        for log in logs.values {
            for entry in log {
                guard let decoded = entry.decoded, decoded.table == table, decoded.record == record,
                    let value = decoded.fields[field]
                else { continue }
                versions.append(FieldState(value: value, stamp: decoded.stamp))
            }
        }
        return versions.sorted { $0.stamp < $1.stamp }
    }

    // MARK: Merging

    /// For each field, the newest stamp wins. Applying entries is therefore commutative and
    /// idempotent, which is what makes the order they arrive in irrelevant.
    static func apply(_ entry: ChangeEntry, to tables: inout Tables) {
        let stamp = entry.stamp
        for (name, value) in entry.fields {
            if let current = tables[entry.table]?[entry.record]?[name], current.stamp >= stamp {
                continue
            }
            tables[entry.table, default: [:]][entry.record, default: [:]][name] =
                FieldState(value: value, stamp: stamp)
        }
    }

    /// The tables worked out from the log alone. They must always match `tables`.
    public func rebuiltTables(supportedSchema: Int) -> Tables {
        var rebuilt: Tables = [:]
        for log in logs.values {
            for entry in log {
                if let decoded = entry.decoded, decoded.schema <= supportedSchema {
                    Self.apply(decoded, to: &rebuilt)
                }
            }
        }
        return rebuilt
    }

    // MARK: Writing

    mutating func append(_ stored: StoredEntry, decoded: ChangeEntry?, supportedSchema: Int) {
        logs[stored.device, default: []].append(LogEntry(stored: stored, decoded: decoded))
        if let decoded, decoded.schema <= supportedSchema {
            Self.apply(decoded, to: &tables)
        } else {
            heldBackCount += 1
        }
    }
}
