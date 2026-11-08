import Foundation

/// Two records that may be the same purchase, always in the same order on every device.
public struct DuplicatePair: Hashable, Sendable {
    public let low: RecordID
    public let high: RecordID

    public init(_ first: RecordID, _ second: RecordID) {
        low = min(first, second)
        high = max(first, second)
    }
}

extension Device {
    public static let transactions = "transactions"
    static let duplicateDismissals = "duplicate_dismissals"

    /// Records with the same account and amount, dated within a day of each other and with no
    /// conflicting recipient. Sync can't remove these itself, since you may really have bought
    /// two coffees that morning, so they're only ever suggested.
    public func possibleDuplicates() -> [DuplicatePair] {
        struct Key: Hashable {
            var account: FieldValue
            var amount: FieldValue
        }

        var groups: [Key: [(id: RecordID, fields: [String: FieldValue])]] = [:]
        for (id, fields) in database.liveRecords(in: Self.transactions) {
            guard let account = fields["account"], let amount = fields["amount"] else { continue }
            groups[Key(account: account, amount: amount), default: []].append((id, fields))
        }

        var pairs: [DuplicatePair] = []
        for group in groups.values where group.count > 1 {
            for (index, first) in group.enumerated() {
                for second in group[(index + 1)...]
                where Self.mayBeSamePurchase(first.fields, second.fields) {
                    let pair = DuplicatePair(first.id, second.id)
                    if !isDismissed(pair) {
                        pairs.append(pair)
                    }
                }
            }
        }
        return pairs.sorted { ($0.low, $0.high) < ($1.low, $1.high) }
    }

    private static func mayBeSamePurchase(
        _ first: [String: FieldValue],
        _ second: [String: FieldValue]
    ) -> Bool {
        guard case .string(let firstDate)? = first["date"],
            case .string(let secondDate)? = second["date"],
            let firstDay = dayNumber(firstDate), let secondDay = dayNumber(secondDate),
            abs(firstDay - secondDay) <= 1
        else { return false }

        let firstRecipient = first["recipient"] ?? .null
        let secondRecipient = second["recipient"] ?? .null
        return firstRecipient.isNull || secondRecipient.isNull || firstRecipient == secondRecipient
    }

    /// Days since 1970 for a `YYYY-MM-DD` calendar date, without involving any time zone.
    static func dayNumber(_ date: String) -> Int? {
        let parts = date.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
            let day = Int(parts[2]), (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private func isDismissed(_ pair: DuplicatePair) -> Bool {
        let id = RecordID.duplicateDismissal(low: pair.low, high: pair.high)
        return database.record(id, in: Self.duplicateDismissals) != nil
            && !database.isDeleted(id, in: Self.duplicateDismissals)
    }

    /// Always keeps the record with the lowest ID, so two devices merging the same pair make the
    /// same choice. If each kept the record it was showing, each could delete the other's choice
    /// and the purchase would disappear. Empty fields on the kept record are filled in first.
    public func mergeDuplicates(_ pair: DuplicatePair) throws {
        guard let kept = database.record(pair.low, in: Self.transactions),
            let other = database.record(pair.high, in: Self.transactions)
        else { return }

        var missing: [String: FieldValue] = [:]
        for (name, value) in other where name != Database.deletedAt && !value.isNull {
            if kept[name]?.isNull ?? true {
                missing[name] = value
            }
        }
        if !missing.isEmpty {
            try write(Self.transactions, pair.low, missing)
        }
        try delete(Self.transactions, pair.high)
    }

    public func dismissDuplicates(_ pair: DuplicatePair) throws {
        try write(
            Self.duplicateDismissals,
            RecordID.duplicateDismissal(low: pair.low, high: pair.high),
            [
                "low": .string(pair.low.rawValue),
                "high": .string(pair.high.rawValue),
                Database.deletedAt: .null,
            ]
        )
    }
}
