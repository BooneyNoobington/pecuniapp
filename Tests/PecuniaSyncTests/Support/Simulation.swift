import Foundation
@testable import PecuniaSync

struct SimulationFailure: Error, CustomStringConvertible, Sendable {
    let seed: UInt64
    let step: Int
    let reason: String
    let trace: [String]

    var description: String {
        """
        Simulation failed with seed \(seed) at step \(step): \(reason)
        Replay it with PECUNIA_SIM_SEED=\(seed) swift test --filter Simulation
        Last actions:
        \(trace.suffix(Self.traceLength).joined(separator: "\n"))
        """
    }

    /// `PECUNIA_SIM_TRACE` sets how many actions a failure prints.
    private static var traceLength: Int {
        ProcessInfo.processInfo.environment["PECUNIA_SIM_TRACE"].flatMap(Int.init) ?? 40
    }
}

struct SimulationStats: Sendable {
    var seeds = 0
    var devices = 0
    var writes = 0
    var entries = 0
    var syncs = 0
    var interruptedSyncs = 0
    var devicesRestored = 0
    var backupsRestoredOntoNewDevices = 0
    var serverRestores = 0
    var serverWipes = 0
    var newDeviceIDs = 0
    var wrongClocks = 0
    var merges = 0
    var dismissals = 0
    var appUpdates = 0
    var splitLogsRepaired = 0
    var reissuedEntries = 0
    var writesDuringSync = 0
    var syncsDuringSync = 0
    /// Identifies what happened in a run, so that replays can be compared across processes.
    var fingerprint: UInt64 = 0

    mutating func add(_ other: SimulationStats) {
        fingerprint &+= other.fingerprint
        splitLogsRepaired += other.splitLogsRepaired
        reissuedEntries += other.reissuedEntries
        writesDuringSync += other.writesDuringSync
        syncsDuringSync += other.syncsDuringSync
        seeds += other.seeds
        devices += other.devices
        writes += other.writes
        entries += other.entries
        syncs += other.syncs
        interruptedSyncs += other.interruptedSyncs
        devicesRestored += other.devicesRestored
        backupsRestoredOntoNewDevices += other.backupsRestoredOntoNewDevices
        serverRestores += other.serverRestores
        serverWipes += other.serverWipes
        newDeviceIDs += other.newDeviceIDs
        wrongClocks += other.wrongClocks
        merges += other.merges
        dismissals += other.dismissals
        appUpdates += other.appUpdates
    }

    var summary: String {
        """
        seeds: \(seeds), devices: \(devices), writes: \(writes), log entries: \(entries)
        syncs: \(syncs), of which interrupted: \(interruptedSyncs)
        devices restored from backup: \(devicesRestored), backups restored onto new devices: \(backupsRestoredOntoNewDevices)
        server restores: \(serverRestores), server wipes: \(serverWipes), new device IDs taken: \(newDeviceIDs)
        clocks set wrong: \(wrongClocks), merges: \(merges), dismissals: \(dismissals), app updates: \(appUpdates)
        split logs repaired: \(splitLogsRepaired), entries re-issued: \(reissuedEntries)
        writes during a sync: \(writesDuringSync), other devices syncing during a sync: \(syncsDuringSync)
        fingerprint: \(fingerprint)
        """
    }
}

/// Several virtual devices making random changes while everything that can go wrong does.
/// The same seed always replays exactly the same run.
final class Simulation {
    struct Options: Sendable {
        var steps = 300
        var maxDevices = 7
        /// How many runs happen at once. `PECUNIA_SIM_PARALLELISM` lowers it, for a machine that
        /// shouldn't run flat out. Fewer is slower, but cooler and uses less energy overall.
        var parallelism = ProcessInfo.processInfo.environment["PECUNIA_SIM_PARALLELISM"]
            .flatMap(Int.init) ?? ProcessInfo.processInfo.activeProcessorCount
        /// Simulates an identity check that can't tell a copy from the original, as if the
        /// Keychain moved with the backup. Used to show what that check protects against.
        var keychainMovesWithBackup = false
        /// These narrow down which kind of event a failure depends on.
        var restoresDevicesFromBackups = true
        var restoresBackupsOntoNewDevices = true
        var restoresServer = true
    }

    struct DeviceBackup {
        var database: Database
        var keychain: DeviceID?
        var held: Set<ContentKey>
        var scanned: [DeviceID: ScanPosition]
    }

    /// How far a device's log has been checked, and the entry found there, which reveals if the
    /// log has since been replaced.
    struct ScanPosition {
        var count: Int
        var last: StoredEntry?
    }

    /// What a write says, regardless of which device and number it ends up under.
    enum ContentKey: Hashable {
        case opaque(Data)
        case entry(table: String, record: RecordID, fields: [String: FieldValue], time: Int64)
    }

    private let seed: UInt64
    private let options: Options
    private let world: World
    private var devices: [TestDevice] = []
    private var serverBackups: [InMemoryServer.Snapshot] = []
    private var stats = SimulationStats()
    private var trace: [String] = []
    private var step = 0
    private var newestSchema = 1
    private var nameCounter = 0
    private var connectionFailurePercent = 0

    private let accounts: [FieldValue] = ["cash", "bank", "ebay"]
    private let amounts: [FieldValue] = [-250, -450, -1000, -1999, 5000]
    private let dates: [FieldValue] = ["2026-11-01", "2026-11-02", "2026-11-03", "2026-11-05"]
    private let recipients: [FieldValue] = [nil, "bakery", "landlord"]
    private let subscriptions = ["sub-a", "sub-b"].map(RecordID.init(rawValue:))

    init(seed: UInt64, options: Options = Options()) throws {
        self.seed = seed
        self.options = options
        world = World(seed: seed)
        world.server.maxBatchSize = pick([1, 3, 10, 50])
        world.server.maxPageSize = pick([1, 7, 200])
        connectionFailurePercent = pick([0, 1, 6])
        for _ in 0..<(2 + number(below: 3)) {
            _ = try addDevice(database: Database(), keychain: InMemoryKeychain())
        }
    }

    func run() async throws -> SimulationStats {
        for current in 0..<options.steps {
            step = current
            // Often no time passes at all, so that devices write in the same millisecond.
            if number(below: 4) != 0 {
                world.advance(Int64(number(below: 60_000)))
            }
            try await performOneAction()
        }
        step = options.steps
        try await settleAndCheck()
        stats.fingerprint = fingerprint()
        stats.seeds = 1
        stats.devices = devices.count
        stats.entries = devices.filter { !$0.isRetired }.first.map { device in
            device.database.logs.values.reduce(0) { $0 + $1.count }
        } ?? 0
        return stats
    }

    /// FNV-1a over everything that happened and the exact bytes of the final logs. Unlike `Hasher`
    /// it's stable across processes and platforms, so a run on another system can be compared.
    private func fingerprint() -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ bytes: some Sequence<UInt8>) {
            for byte in bytes {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
            }
        }
        for line in trace {
            mix(line.utf8)
        }
        if let logs = liveDevices.first?.database.logs {
            for id in logs.keys.sorted() {
                for entry in logs[id] ?? [] {
                    mix(entry.stored.payload)
                }
            }
        }
        return hash
    }

    // MARK: Random choices

    private func number(below limit: Int) -> Int {
        Int(world.rng.next() % UInt64(limit))
    }

    private func pick<T>(_ items: [T]) -> T {
        items[number(below: items.count)]
    }

    private var liveDevices: [TestDevice] {
        devices.filter { !$0.isRetired }
    }

    private func log(_ text: String) {
        trace.append("[\(step)] \(text)")
    }

    private func failure(_ reason: String) -> SimulationFailure {
        SimulationFailure(seed: seed, step: step, reason: reason, trace: trace)
    }

    private func addDevice(database: Database, keychain: InMemoryKeychain) throws -> TestDevice {
        nameCounter += 1
        let device = try world.makeDevice(
            "device-\(nameCounter)", database: database, keychain: keychain,
            supportedSchema: newestSchema)
        devices.append(device)
        return device
    }

    // MARK: Actions

    private func performOneAction() async throws {
        let device = pick(liveDevices)
        switch number(below: 1000) {
        case ..<520:
            try write(on: device)
        case ..<800:
            try await sync(device)
        case ..<830:
            device.isOnline.toggle()
            log("\(device.name) goes \(device.isOnline ? "online" : "offline")")
        case ..<860:
            setClock(of: device)
        case ..<890:
            device.backups.append(
                DeviceBackup(
                    database: device.database, keychain: device.keychain.stored, held: device.held,
                    scanned: device.scanned))
            log("\(device.name) makes a backup at \(device.database.high(device.id))")
        case ..<905:
            if options.restoresDevicesFromBackups {
                try restoreOwnBackup(on: device)
            }
        case ..<920:
            if options.restoresBackupsOntoNewDevices {
                try restoreBackupOntoNewDevice(from: device)
            }
        case ..<930:
            if liveDevices.count < options.maxDevices {
                let joined = try addDevice(database: Database(), keychain: InMemoryKeychain())
                log("\(joined.name) joins with an empty database")
            }
        case ..<938:
            if liveDevices.count > 1 {
                device.isRetired = true
                log("\(device.name) is retired")
            }
        case ..<955:
            serverBackups.append(world.server.snapshot())
            log("server makes a backup")
        case ..<970:
            if options.restoresServer, !serverBackups.isEmpty {
                world.server.restore(pick(serverBackups))
                stats.serverRestores += 1
                log("server is restored from a backup")
            }
        case ..<974:
            if options.restoresServer {
                world.server.wipe()
                stats.serverWipes += 1
                log("server is wiped")
            }
        case ..<984:
            newestSchema = 2
            device.device.appUpdated(toSchema: 2)
            stats.appUpdates += 1
            log("\(device.name) updates the app to schema 2")
        default:
            try device.device.open()
            log("\(device.name) relaunches")
        }
    }

    private func setClock(of device: TestDevice) {
        let hour = World.hour
        let year = World.year
        switch number(below: 6) {
        case 0: device.clock.offset = 0
        case 1: device.clock.offset = Int64(number(below: 4000)) - 2000
        case 2: device.clock.offset = Int64(1 + number(below: 48)) * hour
        case 3: device.clock.offset = -Int64(1 + number(below: 48)) * hour
        case 4: device.clock.offset = 70 * year
        default: device.clock.offset = -40 * year
        }
        stats.wrongClocks += 1
        log("\(device.name) clock offset is now \(device.clock.offset)")
    }

    private func restoreOwnBackup(on device: TestDevice) throws {
        guard !device.backups.isEmpty else { return }
        let backup = pick(device.backups)
        // The Keychain may come back with the backup when restoring onto the same device.
        if number(below: 2) == 0 {
            device.keychain.stored = backup.keychain
        }
        device.held = backup.held
        device.scanned = backup.scanned
        try device.restore(backup.database)
        stats.devicesRestored += 1
        log("\(device.name) is restored from its backup at \(device.database.high(device.id))")
    }

    private func restoreBackupOntoNewDevice(from device: TestDevice) throws {
        guard !device.backups.isEmpty, liveDevices.count < options.maxDevices else { return }
        let backup = pick(device.backups)
        let keychain = InMemoryKeychain(
            stored: options.keychainMovesWithBackup ? backup.database.deviceID : nil)
        let copy = try addDevice(database: backup.database, keychain: keychain)
        copy.held = backup.held
        copy.scanned = backup.scanned
        stats.backupsRestoredOntoNewDevices += 1
        log("\(copy.name) is set up from a backup of \(device.name), and both stay in use")
    }

    /// Things that can happen while a sync is waiting for the network: you enter something on
    /// the same device, or another device syncs and changes what the server has.
    private func somethingHappens(during device: TestDevice) async throws {
        switch number(below: 100) {
        case ..<5:
            log("\(device.name) writes during its sync")
            stats.writesDuringSync += 1
            try write(on: device)
        case ..<9:
            let others = liveDevices.filter { $0 !== device }
            if !others.isEmpty {
                let other = pick(others)
                log("\(other.name) syncs during the sync of \(device.name)")
                stats.syncsDuringSync += 1
                try await sync(other, allowInterleaving: false)
            }
        default:
            break
        }
    }

    private func sync(_ device: TestDevice, allowInterleaving: Bool = true) async throws {
        guard device.isOnline else { return }
        stats.syncs += 1
        var rng = SeededRNG(seed: world.rng.next())
        let failurePercent = UInt64(connectionFailurePercent)
        let backend = FlakyBackend(
            server: world.server,
            beforeCall: { [unowned self] in
                if allowInterleaving {
                    try await self.somethingHappens(during: device)
                }
            },
            outcome: { _ in
                let roll = rng.next() % 200
                if roll < failurePercent { return .lostBeforeServer }
                if roll < failurePercent * 2 { return .lostAfterServer }
                return .delivered
            }
        )
        let idBefore = device.id
        do {
            let report = try await device.device.sync(using: backend)
            guard report.problems.isEmpty else {
                throw failure("\(device.name) reported \(report.problems)")
            }
            stats.splitLogsRepaired += report.splitLogsRepaired
            stats.reissuedEntries += report.reissuedEntries
            log("\(device.name) syncs: pulled \(report.pulledEntries), pushed \(report.pushedEntries), repaired \(report.splitLogsRepaired)")
        } catch is FlakyBackend.ConnectionLost {
            stats.interruptedSyncs += 1
            log("\(device.name) sync is interrupted")
        } catch InMemoryServer.Failure.uniqueIndexViolation {
            stats.interruptedSyncs += 1
            log("\(device.name) push hits the unique index")
        }
        if device.id != idBefore {
            stats.newDeviceIDs += 1
            log("\(device.name) took a new device ID")
        }
        scanHeldEntries(of: device)
    }

    // MARK: Writing

    private func write(on device: TestDevice) throws {
        let app = device.device
        let table = Device.transactions
        let live = app.database.liveRecords(in: table).keys.sorted()

        switch number(below: 100) {
        case ..<32:
            var fields: [String: FieldValue] = [
                "account": pick(accounts), "amount": pick(amounts), "date": pick(dates),
            ]
            let recipient = pick(recipients)
            if !recipient.isNull { fields["recipient"] = recipient }
            let id = try app.create(table, fields)
            log("\(device.name) creates \(id)")
            stats.writes += 1
        case ..<37:
            _ = try app.create("categories", ["name": "groceries"])
            stats.writes += 1
        case ..<67:
            guard !live.isEmpty else { return }
            let record = pick(live)
            let edit: [String: FieldValue]
            switch number(below: 4) {
            case 0: edit = ["amount": pick(amounts)]
            case 1: edit = ["note": .string("note \(number(below: 1000))")]
            case 2: edit = ["category": .string(categoryReference())]
            default: edit = ["amount": pick(amounts), "recipient": pick(recipients)]
            }
            try checkedWrite(on: device, table, record, edit)
            log("\(device.name) edits \(record): \(edit.keys.sorted())")
        case ..<75:
            guard !live.isEmpty else { return }
            let record = pick(live)
            try app.delete(table, record)
            log("\(device.name) deletes \(record)")
            stats.writes += 1
        case ..<80:
            let deleted = (app.database.tables[table] ?? [:]).keys.sorted().filter {
                app.database.isDeleted($0, in: table)
            }
            guard !deleted.isEmpty else { return }
            let record = pick(deleted)
            try app.restore(table, record)
            log("\(device.name) restores \(record)")
            stats.writes += 1
        case ..<90:
            let subscription = pick(subscriptions)
            guard case .string(let date) = pick(dates) else { return }
            if number(below: 2) == 0 {
                try checkedWrite(
                    on: device, "subscription_versions",
                    .subscriptionVersion(subscription: subscription, validFrom: date),
                    ["amount": pick(amounts), Database.deletedAt: .null])
            } else {
                try checkedWrite(
                    on: device, "subscription_overrides",
                    .subscriptionOverride(subscription: subscription, occurrence: date),
                    ["amount": pick(amounts), Database.deletedAt: .null])
            }
        case ..<96:
            let pairs = app.possibleDuplicates()
            guard !pairs.isEmpty else { return }
            let pair = pick(pairs)
            try app.mergeDuplicates(pair)
            stats.merges += 1
            log("\(device.name) merges \(pair.low) and \(pair.high)")
        default:
            let pairs = app.possibleDuplicates()
            guard !pairs.isEmpty else { return }
            let pair = pick(pairs)
            try app.dismissDuplicates(pair)
            stats.dismissals += 1
            log("\(device.name) dismisses \(pair.low) and \(pair.high)")
        }
        scanHeldEntries(of: device)
    }

    /// A reference that may point at a category this device hasn't received yet.
    private func categoryReference() -> String {
        let source = pick(liveDevices).database
        let categories = (source.tables["categories"] ?? [:]).keys.sorted()
        return categories.isEmpty ? "no-such-category" : pick(categories).rawValue
    }

    /// An edit must always beat the value it replaces, whatever the device's clock says.
    private func checkedWrite(
        on device: TestDevice,
        _ table: String,
        _ record: RecordID,
        _ fields: [String: FieldValue]
    ) throws {
        let before = fields.keys.compactMap { field in
            device.database.state(of: field, record: record, table: table).map { (field, $0.stamp) }
        }
        let entry = try device.device.write(table, record, fields)
        stats.writes += 1
        for (field, value) in fields {
            guard device.database.value(of: field, record: record, table: table) == value else {
                throw failure("\(device.name) can't read back its own write to \(field)")
            }
        }
        for (field, stamp) in before where entry.stamp <= stamp {
            throw failure("\(device.name) write to \(field) didn't beat the value it replaced")
        }
    }

    // MARK: Checking

    /// Remembers everything this device has held since its last rollback. All of it must still
    /// exist on every remaining device at the end, or something was lost.
    private func scanHeldEntries(of device: TestDevice) {
        for (id, log) in device.database.logs {
            var from = 0
            if let position = device.scanned[id], position.count <= log.count,
                position.count == 0 || log[position.count - 1].stored == position.last {
                from = position.count
            }
            for entry in log[from...] {
                device.held.insert(Self.contentKey(of: entry))
            }
            device.scanned[id] = ScanPosition(count: log.count, last: log.last?.stored)
        }
    }

    private static func contentKey(of entry: LogEntry) -> ContentKey {
        guard let decoded = entry.decoded else { return .opaque(entry.stored.payload) }
        return .entry(
            table: decoded.table, record: decoded.record, fields: decoded.fields,
            time: decoded.time)
    }

    private func settleAndCheck() async throws {
        let live = liveDevices
        for device in live {
            device.isOnline = true
            device.device.appUpdated(toSchema: newestSchema)
        }

        // Keep syncing, with no failures any more, until a whole round moves nothing.
        var settled = false
        for _ in 0..<10 {
            var moved = 0
            for device in live {
                world.advance()
                let idBefore = device.id
                let report: SyncReport
                do {
                    report = try await device.sync()
                } catch {
                    throw failure("\(device.name) can't sync at the end: \(error)")
                }
                guard report.problems.isEmpty else {
                    throw failure("\(device.name) reported \(report.problems) at the end")
                }
                scanHeldEntries(of: device)
                stats.splitLogsRepaired += report.splitLogsRepaired
                stats.reissuedEntries += report.reissuedEntries
                moved += report.pulledEntries + report.pushedEntries + report.splitLogsRepaired
                if device.id != idBefore {
                    moved += 1
                    stats.newDeviceIDs += 1
                }
            }
            if moved == 0 {
                settled = true
                break
            }
        }
        guard settled else { throw failure("sync never settled") }

        try checkConvergence(of: live)

        // A brand-new device must be able to get everything from the server alone.
        let newcomer = try world.makeDevice("newcomer", supportedSchema: newestSchema)
        let report = try await newcomer.sync()
        guard report.problems.isEmpty else {
            throw failure("a new device reported \(report.problems)")
        }
        guard newcomer.database.tables == live[0].database.tables else {
            throw failure("a new device can't rebuild the data from the server")
        }
    }

    private func checkConvergence(of live: [TestDevice]) throws {
        let codec = EntryCodec()
        let first = live[0]

        // All devices hold exactly the same tables and logs...
        for device in live.dropFirst() {
            if let difference = Self.firstDifference(first.database, device.database) {
                throw failure("\(first.name) and \(device.name) differ: \(difference)")
            }
        }

        // ...so the rest only needs checking on one of them. Rebuilding from the log must give
        // the tables.
        guard
            first.database.rebuiltTables(supportedSchema: first.device.supportedSchema)
                == first.database.tables
        else { throw failure("\(first.name) tables don't match its own log") }

        // Numbers have no gaps, every payload decodes to what's recorded, and every entry follows
        // the one before it.
        for (id, log) in first.database.logs {
            var previous: String?
            for (index, entry) in log.enumerated() {
                guard entry.stored.device == id, entry.stored.seq == UInt64(index) + 1 else {
                    throw failure("\(first.name) log of \(id) is out of order at \(index)")
                }
                guard case .entry(let decoded) = try codec.decode(entry.stored),
                    decoded == entry.decoded
                else { throw failure("\(first.name) entry \(id)/\(index + 1) doesn't decode") }
                guard decoded.previous == previous else {
                    throw failure("\(first.name) log of \(id) breaks its chain at \(index + 1)")
                }
                previous = decoded.id
            }
        }

        // The server holds the full log.
        for (id, log) in first.database.logs {
            guard world.server.entries(of: id) == log.map(\.stored) else {
                throw failure("the server's log of \(id) doesn't match the devices'")
            }
        }

        // Nothing any remaining device ever held has been lost.
        var everHeld = Set<ContentKey>()
        for device in live {
            everHeld.formUnion(device.held)
        }
        let remaining = Set(
            first.database.logs.values.joined().map { Self.contentKey(of: $0) })
        let lost = everHeld.subtracting(remaining)
        guard lost.isEmpty else {
            throw failure("\(lost.count) writes were lost, for example \(lost.first!)")
        }
    }

    private static func firstDifference(_ first: Database, _ second: Database) -> String? {
        // A difference in the logs is the cause of any difference in the tables, so look there first.
        for id in Set(first.logs.keys).union(second.logs.keys).sorted() {
            let firstLog = first.logs[id] ?? []
            let secondLog = second.logs[id] ?? []
            let shared = min(firstLog.count, secondLog.count)
            let differing = (0..<shared).filter { firstLog[$0] != secondLog[$0] }
            if let index = differing.first {
                return "log of \(id), \(firstLog.count) versus \(secondLog.count) entries, "
                    + "differs at numbers \(differing.map { $0 + 1 }): "
                    + "\(String(describing: firstLog[index].decoded)) versus "
                    + "\(String(describing: secondLog[index].decoded))"
            }
            if firstLog.count != secondLog.count {
                return "log of \(id): \(firstLog.count) entries versus \(secondLog.count)"
            }
        }
        if first.tables != second.tables {
            for (table, records) in first.tables.sorted(by: { $0.key < $1.key }) {
                for (record, fields) in records.sorted(by: { $0.key < $1.key }) {
                    let other = second.tables[table]?[record]
                    if other != fields {
                        return "\(table)/\(record): \(fields) versus \(String(describing: other))"
                    }
                }
            }
            return "the second device has records the first doesn't"
        }
        if first.logs != second.logs {
            for id in Set(first.logs.keys).union(second.logs.keys).sorted() {
                if first.logs[id] != second.logs[id] {
                    return "log of \(id): \(first.logs[id]?.count ?? 0) entries versus "
                        + "\(second.logs[id]?.count ?? 0)"
                }
            }
        }
        return nil
    }

    // MARK: Running many seeds

    static func run(
        seeds: Range<UInt64>,
        options: Options = Options()
    ) async -> (stats: SimulationStats, failures: [SimulationFailure]) {
        await withTaskGroup(of: Result<SimulationStats, SimulationFailure>.self) { group in
            var stats = SimulationStats()
            var failures: [SimulationFailure] = []

            func collect(_ result: Result<SimulationStats, SimulationFailure>) {
                switch result {
                case .success(let one): stats.add(one)
                case .failure(let failure): failures.append(failure)
                }
            }

            let parallelism = max(1, options.parallelism)
            var running = 0
            for seed in seeds {
                if running >= parallelism, let finished = await group.next() {
                    collect(finished)
                    running -= 1
                }
                group.addTask {
                    do {
                        let simulation = try Simulation(seed: seed, options: options)
                        return .success(try await simulation.run())
                    } catch let failure as SimulationFailure {
                        return .failure(failure)
                    } catch {
                        return .failure(
                            SimulationFailure(
                                seed: seed, step: -1, reason: "\(error)", trace: []))
                    }
                }
                running += 1
            }
            for await finished in group {
                collect(finished)
            }
            return (stats, failures.sorted { $0.seed < $1.seed })
        }
    }
}
