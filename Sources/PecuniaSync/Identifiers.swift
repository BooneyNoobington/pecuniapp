import Foundation

/// An identifier stored as canonical lowercase text.
///
/// IDs are compared by their UTF-8 bytes, because the order breaks timestamp ties and decides
/// which record a merge keeps. Every platform has to reach the same answer.
public protocol ByteOrderedID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    var rawValue: String { get }
    init(rawValue: String)
}

extension ByteOrderedID {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)
    }

    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Names one device's log of changes.
public struct DeviceID: ByteOrderedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func random(_ random: () -> UInt64) -> DeviceID {
        DeviceID(rawValue: UUIDText.v4(random))
    }
}

/// Names one synced record.
public struct RecordID: ByteOrderedID {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func new(now: Int64, random: () -> UInt64) -> RecordID {
        RecordID(rawValue: UUIDText.v7(now: now, random))
    }

    /// Derived IDs make two devices entering the same thing merge into one record.
    /// The parts are random IDs and calendar dates, so joining them can't be ambiguous.
    public static func subscriptionVersion(subscription: RecordID, validFrom: String) -> RecordID {
        RecordID(rawValue: "version/\(subscription.rawValue)/\(validFrom)")
    }

    public static func subscriptionOverride(subscription: RecordID, occurrence: String) -> RecordID {
        RecordID(rawValue: "override/\(subscription.rawValue)/\(occurrence)")
    }

    static func duplicateDismissal(low: RecordID, high: RecordID) -> RecordID {
        RecordID(rawValue: "dismissal/\(low.rawValue)/\(high.rawValue)")
    }
}

/// Formats UUIDs itself so that the text is always lowercase and the randomness can be seeded.
enum UUIDText {
    static func v4(_ random: () -> UInt64) -> String {
        var bytes = randomBytes(random)
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return format(bytes)
    }

    static func v7(now: Int64, _ random: () -> UInt64) -> String {
        var bytes = randomBytes(random)
        let milliseconds = UInt64(truncatingIfNeeded: now)
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: milliseconds >> UInt64((5 - index) * 8))
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return format(bytes)
    }

    private static func randomBytes(_ random: () -> UInt64) -> [UInt8] {
        let high = random().bigEndian
        let low = random().bigEndian
        return withUnsafeBytes(of: high, Array.init) + withUnsafeBytes(of: low, Array.init)
    }

    private static func format(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(36)
        for (index, byte) in bytes.enumerated() {
            if index == 4 || index == 6 || index == 8 || index == 10 {
                text.append(UInt8(ascii: "-"))
            }
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }
}
