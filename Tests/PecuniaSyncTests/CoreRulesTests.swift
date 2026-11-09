import Foundation
import Testing
@testable import PecuniaSync

@Suite("Merging")
struct MergingTests {
    private func randomEntries(seed: UInt64, count: Int) -> [ChangeEntry] {
        var rng = SeededRNG(seed: seed)
        let devices = ["a", "b", "c"].map(DeviceID.init(rawValue:))
        let records = ["r1", "r2"].map(RecordID.init(rawValue:))
        var numbers: [DeviceID: UInt64] = [:]
        return (0..<count).map { _ in
            let device = devices[Int(rng.next() % 3)]
            numbers[device, default: 0] += 1
            return ChangeEntry(
                format: 1,
                schema: 1,
                device: device,
                seq: numbers[device]!,
                id: "\(device)-\(numbers[device]!)",
                previous: nil,
                table: "t",
                record: records[Int(rng.next() % 2)],
                fields: rng.next() % 2 == 0
                    ? ["x": .int(Int64(rng.next() % 100))]
                    : ["x": .int(Int64(rng.next() % 100)), "y": .string("v\(rng.next() % 5)")],
                // Few distinct times, so that ties are common.
                time: Int64(rng.next() % 5)
            )
        }
    }

    @Test("The result doesn't depend on the order entries arrive in", arguments: 1...50)
    func orderDoesNotMatter(seed: UInt64) {
        let entries = randomEntries(seed: seed, count: 60)
        var expected: Tables = [:]
        for entry in entries {
            StoreSnapshot.apply(entry, to: &expected)
        }
        var rng = SeededRNG(seed: seed &+ 1000)
        for _ in 0..<20 {
            var tables: Tables = [:]
            for entry in entries.shuffled(using: &rng) {
                StoreSnapshot.apply(entry, to: &tables)
            }
            #expect(tables == expected)
        }
    }

    @Test("Applying an entry twice changes nothing", arguments: 1...20)
    func applyingTwice(seed: UInt64) {
        let entries = randomEntries(seed: seed, count: 40)
        var once: Tables = [:]
        var twice: Tables = [:]
        for entry in entries {
            StoreSnapshot.apply(entry, to: &once)
            StoreSnapshot.apply(entry, to: &twice)
            StoreSnapshot.apply(entry, to: &twice)
        }
        #expect(once == twice)
    }

    @Test("Ties are broken by device ID and then entry number")
    func ties() {
        let a = DeviceID(rawValue: "a")
        let b = DeviceID(rawValue: "b")
        #expect(Stamp(time: 5, device: a, seq: 9) < Stamp(time: 6, device: a, seq: 1))
        #expect(Stamp(time: 5, device: a, seq: 9) < Stamp(time: 5, device: b, seq: 1))
        #expect(Stamp(time: 5, device: a, seq: 1) < Stamp(time: 5, device: a, seq: 2))
    }
}

@Suite("The per-field clock")
struct ClockTests {
    @Test("An edit beats the value it replaces, however wrong the clock is")
    func editBeatsWhatItReplaces() throws {
        let world = World()
        let device = try world.makeDevice("device")
        let record = try device.device.create("t", ["x": 1])

        for offset in [-40 * World.year, 70 * World.year, -World.hour, 0] {
            device.clock.offset = offset
            let before = try #require(device.database.state(of: "x", record: record, table: "t"))
            let value = FieldValue.int(offset)
            let entry = try device.device.write("t", record, ["x": value])
            #expect(entry.stamp > before.stamp)
            #expect(device.database.value(of: "x", record: record, table: "t") == value)
        }
    }

    @Test("Two writes in the same millisecond still have an order")
    func sameMillisecond() throws {
        let world = World()
        let device = try world.makeDevice("device")
        let record = try device.device.create("t", ["x": 1])
        let second = try device.device.write("t", record, ["x": 2])
        let third = try device.device.write("t", record, ["x": 3])
        #expect(third.time == second.time + 1)
        #expect(device.database.value(of: "x", record: record, table: "t") == 3)
    }

    @Test("The largest possible timestamp doesn't crash the app")
    func largestTimestamp() async throws {
        let world = World()
        let device = try world.makeDevice("device")
        let record = RecordID(rawValue: "r")
        device.clock.offset = Int64.max - world.time
        try device.device.write("t", record, ["x": 1])
        try device.device.write("t", record, ["x": 2])
        #expect(device.database.value(of: "x", record: record, table: "t") == 2)
        _ = try await device.sync()
    }
}

@Suite("Device identity")
struct IdentityTests {
    @Test("A locked Keychain means wait, not a new ID")
    func lockedKeychain() throws {
        let world = World()
        let keychain = InMemoryKeychain()
        let device = try world.makeDevice("phone", keychain: keychain)
        let id = device.id

        keychain.isLocked = true
        #expect(throws: DeviceError.identityStoreLocked) {
            try device.restore(device.database)
        }
        #expect(device.database.deviceID == id)

        keychain.isLocked = false
        try device.device.open()
        #expect(device.id == id)
    }

    @Test("A database without a matching Keychain entry is a copy")
    func mismatch() throws {
        let world = World()
        let original = try world.makeDevice("original")
        let copy = try world.makeDevice("copy", database: original.database)
        #expect(copy.id != original.id)
    }

    @Test("A database whose ID differs from the one in the Keychain is a copy")
    func differentID() throws {
        let world = World()
        let original = try world.makeDevice("original")
        let other = try world.makeDevice("other")
        let copy = try world.makeDevice(
            "copy", database: original.database, keychain: InMemoryKeychain(stored: other.id))
        #expect(copy.id != original.id)
        #expect(copy.id != other.id)
    }

    @Test("A fresh database always gets a new ID, even if the Keychain survived a reinstall")
    func reinstall() throws {
        let world = World()
        let keychain = InMemoryKeychain()
        let first = try world.makeDevice("phone", keychain: keychain)
        let second = try world.makeDevice("phone", keychain: keychain)
        #expect(first.id != second.id)
    }

    @Test("Writing needs an open device")
    func notOpen() {
        let device = Device(identity: InMemoryKeychain(), name: "phone")
        #expect(throws: DeviceError.notOpen) {
            try device.write("t", RecordID(rawValue: "r"), ["x": 1])
        }
    }
}

@Suite("Sync safety")
struct SyncSafetyTests {
    @Test("A hole in a device's numbers is reported, not skipped")
    func gap() async throws {
        let world = World()
        let phone = try world.makeDevice("phone")
        let imac = try world.makeDevice("iMac")
        for amount in 1...3 {
            try phone.device.create("t", ["x": .int(Int64(amount))])
        }
        try await phone.sync()
        world.server.forceRemove(device: phone.id, seq: 2)

        let report = try await imac.sync()
        #expect(report.problems == [.gap(device: phone.id, expected: 2, found: 3)])
        #expect(imac.database.high(phone.id) == 1)
    }

    @Test("An unreadable entry is reported and not applied")
    func unreadable() async throws {
        let world = World()
        let phone = try world.makeDevice("phone")
        let imac = try world.makeDevice("iMac")
        try await phone.sync()
        world.server.forceInsert(
            StoredEntry(device: phone.id, seq: 1, payload: Data("not an entry".utf8)))

        let report = try await imac.sync()
        #expect(report.problems == [.unreadableEntry(device: phone.id, seq: 1)])
        #expect(imac.database.high(phone.id) == 0)
    }

    @Test("An entry stored at the wrong place is rejected")
    func wrongPosition() async throws {
        let world = World()
        let phone = try world.makeDevice("phone")
        let imac = try world.makeDevice("iMac")
        try phone.device.create("t", ["x": 1])
        try phone.device.create("t", ["x": 2])
        try await phone.sync()

        // Swap two entries, as a misbehaving server might.
        let entries = world.server.entries(of: phone.id)
        world.server.forceInsert(StoredEntry(device: phone.id, seq: 1, payload: entries[1].payload))
        world.server.forceInsert(StoredEntry(device: phone.id, seq: 2, payload: entries[0].payload))

        let report = try await imac.sync()
        #expect(report.problems == [.unreadableEntry(device: phone.id, seq: 1)])
        #expect(imac.database.high(phone.id) == 0)
    }

    @Test("An entry that doesn't follow the one before it is reported, not applied")
    func brokenChain() async throws {
        let world = World()
        let phone = try world.makeDevice("phone")
        let imac = try world.makeDevice("iMac")
        try phone.device.create("t", ["x": 1])
        try phone.device.create("t", ["x": 2])
        try await phone.sync()

        // A log put together from two different histories.
        let codec = EntryCodec()
        guard case .entry(var second) = try codec.decode(world.server.entries(of: phone.id)[1])
        else {
            Issue.record("the entry should decode")
            return
        }
        second.previous = "an entry from another history"
        world.server.forceInsert(
            StoredEntry(device: phone.id, seq: 2, payload: try codec.encode(second)))

        let report = try await imac.sync()
        #expect(report.problems == [.brokenChain(device: phone.id, seq: 2)])
        #expect(imac.database.high(phone.id) == 1)
    }

    @Test("Each entry names the one before it")
    func chain() async throws {
        let world = World()
        let phone = try world.makeDevice("phone")
        let first = try phone.device.write("t", RecordID(rawValue: "r"), ["x": 1])
        let second = try phone.device.write("t", RecordID(rawValue: "r"), ["x": 1])
        #expect(first.previous == nil)
        #expect(second.previous == first.id)
        #expect(first.id != second.id)
    }

    @Test("A split that can't be repaired yet doesn't upload on top of the other side")
    func splitWithHole() async throws {
        let world = World()
        let phone = try world.makeDevice("phone")
        try phone.device.create("t", ["x": 1])
        try phone.device.create("t", ["x": 2])
        try await phone.sync()
        let backup = phone.database

        try phone.device.create("t", ["x": 3])
        try phone.device.create("t", ["x": 4])
        try await phone.sync()
        let oldID = phone.id

        try phone.restore(backup)
        try phone.device.create("t", ["x": 5])
        try phone.device.create("t", ["x": 6])
        try phone.device.create("t", ["x": 7])
        world.server.forceRemove(device: oldID, seq: 2)

        let serverBefore = world.server.entries(of: oldID)
        let report = try await phone.sync()
        #expect(report.problems == [.gap(device: oldID, expected: 2, found: 3)])
        #expect(report.splitLogsRepaired == 0)
        #expect(world.server.entries(of: oldID) == serverBefore)
    }

    @Test("Writing during a sync is safe, even if the device turns out to be a restored copy")
    func writeDuringSync() async throws {
        let world = World()
        let phone = try world.makeDevice("phone")
        let imac = try world.makeDevice("iMac")
        try phone.device.create("t", ["x": 1])
        try await world.syncAll([phone, imac])
        let backup = phone.database
        try phone.device.create("t", ["x": 2])
        try await world.syncAll([phone, imac])
        try phone.restore(backup)

        var written: RecordID?
        let backend = FlakyBackend(
            server: world.server,
            beforeCall: {
                if written == nil {
                    written = try phone.device.create("t", ["x": 3])
                }
            },
            outcome: { _ in .delivered }
        )
        _ = try await phone.device.sync(using: backend)
        try await world.syncAll([phone, imac])

        let record = try #require(written)
        #expect(imac.database.record(record, in: "t") != nil)
        #expect(imac.database.tables == phone.database.tables)
    }

    @Test("A device can't run two syncs at once")
    func oneSyncAtATime() async throws {
        let world = World()
        let phone = try world.makeDevice("phone")
        var nested: (any Error)?
        let backend = FlakyBackend(
            server: world.server,
            beforeCall: {
                if nested == nil {
                    do {
                        _ = try await phone.device.sync(using: world.server)
                    } catch {
                        nested = error
                    }
                }
            },
            outcome: { _ in .delivered }
        )
        _ = try await phone.device.sync(using: backend)
        #expect(nested as? DeviceError == .alreadySyncing)
    }
}

@Suite("Formats")
struct FormatTests {
    private let entry = ChangeEntry(
        format: 1,
        schema: 1,
        device: DeviceID(rawValue: "device"),
        seq: 7,
        id: "b",
        previous: "a",
        table: "transactions",
        record: RecordID(rawValue: "record/with/slashes"),
        fields: ["amount": -250, "note": "ünï", "flag": true, "gone": nil],
        time: 1_793_000_000_000
    )

    @Test("An entry survives encoding and decoding unchanged")
    func roundTrip() throws {
        let codec = EntryCodec()
        let stored = StoredEntry(device: entry.device, seq: 7, payload: try codec.encode(entry))
        #expect(try codec.decode(stored) == .entry(entry))
    }

    @Test("Encoding is canonical, so equal entries have identical bytes")
    func canonical() throws {
        let codec = EntryCodec()
        #expect(try codec.encode(entry) == codec.encode(entry))
        let text = String(decoding: try codec.encode(entry), as: UTF8.self)
        #expect(text.hasPrefix(#"{"device":"device","fields":{"amount":-250,"flag":true,"gone":null"#))
    }

    @Test("A newer format is held back, whether or not it looks like today's")
    func newerFormats() throws {
        let codec = EntryCodec()
        let device = DeviceID(rawValue: "device")
        var lookalike = entry
        lookalike.format = ChangeEntry.currentFormat + 1
        let stored = StoredEntry(device: device, seq: 7, payload: try codec.encode(lookalike))
        #expect(try codec.decode(stored) == .newerFormat)

        let different = StoredEntry(device: device, seq: 7, payload: Data(#"{"format":99}"#.utf8))
        #expect(try codec.decode(different) == .newerFormat)

        let notNewer = StoredEntry(device: device, seq: 7, payload: Data(#"{"format":1}"#.utf8))
        #expect(throws: EntryCodec.Failure.unreadable) {
            try codec.decode(notNewer)
        }
    }

    @Test("Floating-point numbers are refused, because amounts never use them")
    func noFloats() {
        let codec = EntryCodec()
        let payload = Data(
            #"{"format":1,"schema":1,"device":"d","seq":1,"id":"x","table":"t","record":"r","fields":{"amount":1.5},"time":1}"#
                .utf8)
        #expect(throws: EntryCodec.Failure.unreadable) {
            try codec.decode(StoredEntry(device: DeviceID(rawValue: "d"), seq: 1, payload: payload))
        }
    }

    @Test("IDs sort by their bytes")
    func byteOrder() {
        #expect(RecordID(rawValue: "Z") < RecordID(rawValue: "a"))
        #expect(RecordID(rawValue: "a") < RecordID(rawValue: "ä"))
        #expect(RecordID(rawValue: "a") < RecordID(rawValue: "aa"))
    }

    @Test("Generated IDs are lowercase UUIDs, and sort by time")
    func generatedIDs() {
        var rng = SeededRNG(seed: 1)
        let early = RecordID.new(now: 1_000, random: { rng.next() })
        let late = RecordID.new(now: 2_000, random: { rng.next() })
        #expect(early < late)
        #expect(early.rawValue == early.rawValue.lowercased())
        #expect(UUID(uuidString: early.rawValue) != nil)
        #expect(early.rawValue.dropFirst(14).first == "7")

        let device = DeviceID.random { rng.next() }
        #expect(UUID(uuidString: device.rawValue) != nil)
        #expect(device.rawValue.dropFirst(14).first == "4")
    }

    @Test("Derived IDs are the same on every device")
    func derivedIDs() {
        let subscription = RecordID(rawValue: "electricity")
        #expect(
            RecordID.subscriptionVersion(subscription: subscription, validFrom: "2026-12-01")
                .rawValue == "version/electricity/2026-12-01")
        #expect(
            RecordID.subscriptionOverride(subscription: subscription, occurrence: "2026-12-01")
                .rawValue == "override/electricity/2026-12-01")
        let a = RecordID(rawValue: "a")
        let b = RecordID(rawValue: "b")
        #expect(DuplicatePair(a, b) == DuplicatePair(b, a))
    }

    @Test("Calendar dates count days without a time zone")
    func dates() {
        #expect(Device.dayNumber("1970-01-01") == 0)
        #expect(Device.dayNumber("1970-01-02") == 1)
        #expect(Device.dayNumber("2024-03-01")! - Device.dayNumber("2024-02-28")! == 2)
        #expect(Device.dayNumber("2025-03-01")! - Device.dayNumber("2025-02-28")! == 1)
        #expect(Device.dayNumber("2026-01-01")! - Device.dayNumber("2025-12-31")! == 1)
        #expect(Device.dayNumber("not a date") == nil)
        #expect(Device.dayNumber("2026-13-01") == nil)
    }
}
