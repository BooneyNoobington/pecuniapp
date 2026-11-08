import Foundation

/// A value a synced field can hold. There's deliberately no floating-point case, because amounts
/// are whole numbers in the currency's smallest unit and calendar dates are text.
public enum FieldValue: Hashable, Codable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case string(String)

    public var isNull: Bool { self == .null }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

extension FieldValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(stringLiteral value: String) { self = .string(value) }
}

/// Decides which write to a field wins. The time comes first, and the device ID and entry number
/// make the order strict, so the winner is the same no matter which order entries arrive in.
public struct Stamp: Comparable, Hashable, Sendable {
    public var time: Int64
    public var device: DeviceID
    public var seq: UInt64

    public static func < (lhs: Stamp, rhs: Stamp) -> Bool {
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        if lhs.device != rhs.device { return lhs.device < rhs.device }
        return lhs.seq < rhs.seq
    }
}

/// One write: a record, the fields it changed, their new values and a timestamp.
public struct ChangeEntry: Hashable, Codable, Sendable {
    public static let currentFormat = 1

    public var format: Int
    public var schema: Int
    public var device: DeviceID
    public var seq: UInt64
    /// Random and unique to this write. Together with `previous`, this links a device's log into
    /// a chain, so two entries with identical bytes always have identical histories. That's what
    /// lets comparing only the newest entries reveal a split.
    public var id: String
    /// The `id` of the entry before this one in the device's log, or nil for its first entry.
    public var previous: String?
    public var table: String
    public var record: RecordID
    public var fields: [String: FieldValue]
    public var time: Int64

    public var stamp: Stamp { Stamp(time: time, device: device, seq: seq) }
}

/// An entry as the server holds it. The payload is opaque to everything except `EntryCodec`,
/// and the bytes never change once written, so an entry can be uploaded again by any device.
public struct StoredEntry: Hashable, Sendable {
    public var device: DeviceID
    public var seq: UInt64
    public var payload: Data

    public init(device: DeviceID, seq: UInt64, payload: Data) {
        self.device = device
        self.seq = seq
        self.payload = payload
    }
}

/// Turns entries into payloads and back. Encryption joins here in a later step.
public struct EntryCodec {
    public enum Decoded: Hashable, Sendable {
        case entry(ChangeEntry)
        /// Written by a newer app version in a format this one can't read.
        case newerFormat
    }

    public enum Failure: Error, Equatable {
        case unreadable
        /// The payload says it belongs at a different device or number than where it was stored.
        case wrongPosition
    }

    private struct FormatHeader: Decodable {
        var format: Int
    }

    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func encode(_ entry: ChangeEntry) throws -> Data {
        try encoder.encode(entry)
    }

    public func decode(_ stored: StoredEntry) throws -> Decoded {
        guard let entry = try? decoder.decode(ChangeEntry.self, from: stored.payload) else {
            // A newer format may not have the fields this version expects.
            let header = try? decoder.decode(FormatHeader.self, from: stored.payload)
            guard let header, header.format > ChangeEntry.currentFormat else {
                throw Failure.unreadable
            }
            return .newerFormat
        }
        if entry.format > ChangeEntry.currentFormat {
            return .newerFormat
        }
        guard entry.device == stored.device, entry.seq == stored.seq else {
            throw Failure.wrongPosition
        }
        return .entry(entry)
    }
}
