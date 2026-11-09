import Foundation
import Testing
@testable import PecuniaSync

/// Wraps a store and makes its N-th change fail, as a crash part way through a transaction would.
final class FailingStore: LocalStore {
    struct InjectedFailure: Error {}

    let base: any LocalStore
    var failAtChange: Int?
    private(set) var changes = 0

    init(base: any LocalStore, failAtChange: Int? = nil) {
        self.base = base
        self.failAtChange = failAtChange
    }

    func read<T>(_ body: (any StoreAccess) throws -> T) throws -> T {
        try base.read(body)
    }

    func write<T>(_ body: (any StoreAccess) throws -> T) throws -> T {
        try base.write { tx in try body(FailingAccess(base: tx, store: self)) }
    }

    func snapshot() throws -> StoreSnapshot {
        try base.snapshot()
    }

    fileprivate func change() throws {
        changes += 1
        if changes == failAtChange {
            throw InjectedFailure()
        }
    }
}

private final class FailingAccess: StoreAccess {
    let base: any StoreAccess
    let store: FailingStore

    init(base: any StoreAccess, store: FailingStore) {
        self.base = base
        self.store = store
    }

    func deviceID() throws -> DeviceID? { try base.deviceID() }
    func knownDevices() throws -> [DeviceID: Data] { try base.knownDevices() }
    func high(_ device: DeviceID) throws -> UInt64 { try base.high(device) }
    func logEntry(_ device: DeviceID, seq: UInt64) throws -> LogEntry? {
        try base.logEntry(device, seq: seq)
    }
    func logEntries(_ device: DeviceID, after seq: UInt64) throws -> [LogEntry] {
        try base.logEntries(device, after: seq)
    }
    func logEntries(table: String, record: RecordID) throws -> [LogEntry] {
        try base.logEntries(table: table, record: record)
    }
    func allLogEntries() throws -> [LogEntry] { try base.allLogEntries() }
    func heldBackCount(supportedSchema: Int) throws -> Int {
        try base.heldBackCount(supportedSchema: supportedSchema)
    }
    func fieldState(_ field: String, record: RecordID, table: String) throws -> FieldState? {
        try base.fieldState(field, record: record, table: table)
    }
    func fields(of record: RecordID, table: String) throws -> [String: FieldState]? {
        try base.fields(of: record, table: table)
    }
    func records(in table: String) throws -> [RecordID: [String: FieldState]] {
        try base.records(in: table)
    }

    func setDeviceID(_ id: DeviceID) throws {
        try store.change()
        try base.setDeviceID(id)
    }
    func setKnownDevice(_ id: DeviceID, encryptedName: Data) throws {
        try store.change()
        try base.setKnownDevice(id, encryptedName: encryptedName)
    }
    func appendLog(_ entry: LogEntry) throws {
        try store.change()
        try base.appendLog(entry)
    }
    func replaceLog(of device: DeviceID, with entries: [LogEntry]) throws {
        try store.change()
        try base.replaceLog(of: device, with: entries)
    }
    func setFieldState(_ state: FieldState, field: String, record: RecordID, table: String) throws {
        try store.change()
        try base.setFieldState(state, field: field, record: record, table: table)
    }
    func removeAllFields() throws {
        try store.change()
        try base.removeAllFields()
    }
}

@Suite("Crash safety")
struct CrashSafetyTests {
    private let table = Device.transactions

    /// A device whose store fails wherever the test says, starting from a given state.
    private func device(
        from snapshot: StoreSnapshot,
        in world: World,
        keychain: InMemoryKeychain,
        failAtChange: Int?
    ) throws -> (Device, FailingStore) {
        let store = FailingStore(base: try world.makeStore(from: snapshot), failAtChange: failAtChange)
        let device = Device(
            store: store,
            identity: keychain,
            environment: DeviceEnvironment(now: { world.time }, random: { world.rng.next() }),
            name: "phone"
        )
        return (device, store)
    }

    /// Runs an operation once to count its changes, then again with each change failing in turn.
    /// After every failure, nothing may be left half done: the state must be exactly as before.
    private func expectAllOrNothing(
        storeKind: StoreKind,
        _ operation: (Device) throws -> Void
    ) throws {
        let world = World(storeKind: storeKind)
        let phone = try world.makeDevice("phone")
        let coffee: [String: FieldValue] = ["account": "cash", "amount": -350, "date": "2026-11-06"]
        try phone.device.create(table, coffee)
        try phone.device.create(table, coffee.merging(["recipient": "bakery"]) { $1 })
        try phone.device.create(table, ["amount": 5, "note": "keep me"])
        let before = phone.database

        let (counting, countingStore) = try device(
            from: before, in: world, keychain: phone.keychain, failAtChange: nil)
        try operation(counting)
        let total = countingStore.changes
        #expect(total > 1)

        for failing in 1...total {
            let (device, store) = try device(
                from: before, in: world, keychain: phone.keychain, failAtChange: failing)
            #expect(throws: FailingStore.InjectedFailure.self) { try operation(device) }
            #expect(try store.snapshot() == before, "change \(failing) of \(total) left something behind")
        }
    }

    @Test("A write is all or nothing", arguments: StoreKind.available)
    func write(storeKind: StoreKind) throws {
        try expectAllOrNothing(storeKind: storeKind) { device in
            let record = try #require(device.liveRecords(in: table).keys.sorted().first)
            try device.write(table, record, ["amount": -400, "note": "changed", "category": "food"])
        }
    }

    @Test("A merge is all or nothing", arguments: StoreKind.available)
    func merge(storeKind: StoreKind) throws {
        try expectAllOrNothing(storeKind: storeKind) { device in
            let pair = try #require(device.possibleDuplicates().first)
            try device.mergeDuplicates(pair)
        }
    }

    @Test("Updating the app is all or nothing", arguments: StoreKind.available)
    func appUpdate(storeKind: StoreKind) throws {
        try expectAllOrNothing(storeKind: storeKind) { device in
            try device.appUpdated(toSchema: 2)
        }
    }

    /// The most involved transaction: a sync that pulls, repairs a split and re-issues entries.
    /// A failure may only lose the progress of that sync, and the next sync must still work.
    @Test("A sync that fails part way leaves nothing half done", arguments: StoreKind.available)
    func sync(storeKind: StoreKind) async throws {
        let world = World(storeKind: storeKind)
        let phone = try world.makeDevice("phone")
        let imac = try world.makeDevice("iMac")
        for amount in 1...3 {
            try phone.device.create(table, ["amount": .int(Int64(amount))])
        }
        try await world.syncAll([phone, imac])
        let backup = phone.database
        try phone.device.create(table, ["note": "pushed, then lost locally"])
        try imac.device.create(table, ["note": "from the iMac"])
        try await world.syncAll([phone, imac])

        // The restored phone writes before syncing, so its sync repairs a split.
        try phone.restore(backup)
        try phone.device.create(table, ["note": "entered at the till"])
        let before = phone.database
        let serverBefore = world.server.snapshot()

        let (counting, countingStore) = try device(
            from: before, in: world, keychain: phone.keychain, failAtChange: nil)
        let report = try await counting.sync(using: world.server)
        #expect(report.splitLogsRepaired == 1)
        let total = countingStore.changes

        for failing in 1...total {
            world.server.restore(serverBefore)
            let (device, store) = try device(
                from: before, in: world, keychain: phone.keychain, failAtChange: failing)
            do {
                _ = try await device.sync(using: world.server)
                Issue.record("change \(failing) of \(total) should have failed")
            } catch is FailingStore.InjectedFailure {}

            // Only the list of known devices is saved separately, before the main transaction.
            let after = try store.snapshot()
            #expect(after.logs == before.logs, "change \(failing) of \(total) touched the log")
            #expect(after.tables == before.tables, "change \(failing) of \(total) touched the tables")
            #expect(after.deviceID == before.deviceID)

            // The next sync works as if nothing had happened.
            store.failAtChange = nil
            let retry = try await device.sync(using: world.server)
            #expect(retry.splitLogsRepaired == 1)
            #expect(after.rebuiltTables(supportedSchema: 1) == after.tables)
        }
    }
}

#if canImport(GRDB)
@Suite("SQLite storage")
struct SQLiteStorageTests {
    /// The strongest check: the same simulated runs give exactly the same fingerprints, so the
    /// SQLite store did everything the reference store did, byte for byte.
    @Test("SQLite gives exactly the same results as the reference store")
    func sameAsReference() async {
        var memory = Simulation.Options()
        memory.storeKind = .memory
        var sqlite = Simulation.Options()
        sqlite.storeKind = .sqlite
        let seeds: Range<UInt64> = 7000..<7040

        let reference = await Simulation.run(seeds: seeds, options: memory)
        let result = await Simulation.run(seeds: seeds, options: sqlite)
        for failure in (reference.failures + result.failures).prefix(2) {
            Issue.record("\(failure)")
        }
        print("SQLite simulation: \(result.stats.summary)")
        #expect(result.failures.isEmpty)
        #expect(result.stats.fingerprint == reference.stats.fingerprint)
    }

    @Test("Everything survives closing and reopening the database file")
    func reopen() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("pecunia-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("pecunia.sqlite").path

        var random: UInt64 = 0
        let environment = DeviceEnvironment(
            now: { 1_793_000_000_000 },
            random: {
                random += 1
                return random
            })
        let keychain = InMemoryKeychain()
        let saved: StoreSnapshot
        do {
            let device = Device(
                store: try SQLiteStore(path: path), identity: keychain, environment: environment,
                name: "phone")
            try device.open()
            let record = try device.create("transactions", ["amount": -250, "note": "croissant"])
            try device.write("transactions", record, ["amount": -300])
            try device.delete("transactions", record)
            saved = try device.snapshot()
        }

        let reopened = Device(
            store: try SQLiteStore(path: path), identity: keychain, environment: environment,
            name: "phone")
        try reopened.open()
        #expect(try reopened.snapshot() == saved)
        #expect(saved.logs.values.joined().count == 3)
    }

    @Test("Values keep their type")
    func valueTypes() throws {
        let store = try SQLiteStore.inMemory()
        let values: [String: FieldValue] = [
            "flag": true, "off": false, "one": 1, "zero": 0, "negative": -5,
            "largest": .int(.max), "smallest": .int(.min), "none": nil, "text": "ünï 🥐",
            "empty": "",
        ]
        let record = RecordID(rawValue: "record")
        let stamp = Stamp(time: 1, device: DeviceID(rawValue: "device"), seq: 1)
        try store.write { tx in
            for (field, value) in values {
                try tx.setFieldState(
                    FieldState(value: value, stamp: stamp), field: field, record: record, table: "t")
            }
        }
        #expect(try store.read { try $0.fields(of: record, table: "t") }?.mapValues(\.value) == values)
    }

    @Test("A snapshot copied into SQLite comes back unchanged")
    func copying() async throws {
        let world = World()
        let phone = try world.makeDevice("phone")
        let imac = try world.makeDevice("iMac", supportedSchema: 2)
        try phone.device.create("transactions", ["amount": -250])
        try imac.device.create("transactions", ["amount": 5, "new_in_v2": true])
        try await world.syncAll([phone, imac])
        let snapshot = phone.database
        #expect(phone.database.logs.count == 2)

        let store = try SQLiteStore.inMemory(copying: snapshot)
        #expect(try store.snapshot() == snapshot)
        #expect(try store.read { try $0.heldBackCount(supportedSchema: 1) } == 1)
    }
}
#endif

@Suite("Store rules")
struct StoreRuleTests {
    @Test("An entry that doesn't follow on from the last one is refused", arguments: StoreKind.available)
    func outOfOrder(storeKind: StoreKind) throws {
        let world = World(storeKind: storeKind)
        let phone = try world.makeDevice("phone")
        let record = try phone.device.create("t", ["x": 1])
        let entry = try #require(phone.database.logs[phone.id]?.first)

        var skipped = entry.stored
        skipped.seq = 3
        #expect(throws: StoreError.entryOutOfOrder(device: phone.id, seq: 3)) {
            try phone.device.store.write { tx in
                try tx.append(skipped, decoded: nil, supportedSchema: 1)
            }
        }
        #expect(phone.database.high(phone.id) == 1)
        #expect(phone.database.value(of: "x", record: record, table: "t") == 1)
    }
}
