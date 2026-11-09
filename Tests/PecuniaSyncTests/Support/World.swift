import Foundation
@testable import PecuniaSync

/// A small, fast random generator whose numbers depend only on the seed (SplitMix64).
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Stands in for the Keychain, which doesn't move with a backup.
final class InMemoryKeychain: DeviceIdentityStore {
    var stored: DeviceID?
    var isLocked = false

    init(stored: DeviceID? = nil) {
        self.stored = stored
    }

    func read() -> StoredIdentity {
        if isLocked { return .locked }
        return stored.map(StoredIdentity.found) ?? .missing
    }

    func write(_ id: DeviceID) {
        stored = id
    }
}

/// Which kind of local store test devices use.
enum StoreKind: String, Sendable, CaseIterable {
    case memory
    case sqlite
}

/// Real time and shared randomness for a group of test devices.
final class World {
    static let start: Int64 = 1_793_000_000_000
    static let hour: Int64 = 3_600_000
    static let year: Int64 = 365 * 24 * hour

    var time = World.start
    var rng: SeededRNG
    let server = InMemoryServer()
    let storeKind: StoreKind

    init(seed: UInt64 = 1, storeKind: StoreKind = .memory) {
        rng = SeededRNG(seed: seed)
        self.storeKind = storeKind
        server.clock = { [unowned self] in self.time }
    }

    /// A new store holding the same as a snapshot, as restoring a backup does.
    func makeStore(from snapshot: StoreSnapshot) throws -> any LocalStore {
        switch storeKind {
        case .memory:
            return MemoryStore(snapshot)
        case .sqlite:
            #if canImport(GRDB)
            return try SQLiteStore.inMemory(copying: snapshot)
            #else
            preconditionFailure("SQLite is only available on Apple platforms")
            #endif
        }
    }

    func makeDevice(
        _ name: String,
        database: StoreSnapshot = StoreSnapshot(),
        keychain: InMemoryKeychain = InMemoryKeychain(),
        supportedSchema: Int = 1
    ) throws -> TestDevice {
        try TestDevice(
            name: name, world: self, database: database, keychain: keychain,
            supportedSchema: supportedSchema)
    }

    func advance(_ milliseconds: Int64 = 1_000) {
        time += milliseconds
    }

    /// Syncs every device twice, so that everyone sees what everyone else pushed.
    func syncAll(_ devices: [TestDevice]) async throws {
        for _ in 0..<2 {
            for device in devices {
                advance()
                try await device.sync()
            }
        }
    }
}

/// A device under test with a clock that can be set wrong.
final class TestDevice {
    final class Clock {
        unowned let world: World
        var offset: Int64 = 0

        init(world: World) {
            self.world = world
        }

        var now: Int64 { world.time &+ offset }
    }

    let name: String
    unowned let world: World
    let keychain: InMemoryKeychain
    let clock: Clock
    var device: Device

    // Used by the simulation.
    var isOnline = true
    var isRetired = false
    var backups: [Simulation.DeviceBackup] = []
    var held = Set<Simulation.ContentKey>()
    var scanned: [DeviceID: Simulation.ScanPosition] = [:]

    init(
        name: String,
        world: World,
        database: StoreSnapshot,
        keychain: InMemoryKeychain,
        supportedSchema: Int
    ) throws {
        self.name = name
        self.world = world
        self.keychain = keychain
        self.clock = Clock(world: world)
        self.device = Self.makeDevice(
            name: name, world: world, clock: clock, store: try world.makeStore(from: database),
            keychain: keychain, supportedSchema: supportedSchema)
        try device.open()
    }

    private static func makeDevice(
        name: String,
        world: World,
        clock: Clock,
        store: any LocalStore,
        keychain: InMemoryKeychain,
        supportedSchema: Int
    ) -> Device {
        Device(
            store: store,
            identity: keychain,
            environment: DeviceEnvironment(
                now: { clock.now },
                random: { [unowned world] in world.rng.next() }
            ),
            name: name,
            supportedSchema: supportedSchema
        )
    }

    var id: DeviceID { try! device.deviceID()! }

    /// A copy of everything the device holds. Cheap in memory, but slow with SQLite, so the
    /// simulation's frequent reads go to the store directly instead.
    var database: StoreSnapshot { (try? device.snapshot()) ?? StoreSnapshot() }

    /// Replaces the database with a backup, as restoring the whole device does.
    func restore(_ backup: StoreSnapshot) throws {
        device = Self.makeDevice(
            name: name, world: world, clock: clock, store: try world.makeStore(from: backup),
            keychain: keychain, supportedSchema: device.supportedSchema)
        try device.open()
    }

    @discardableResult
    func sync() async throws -> SyncReport {
        try await device.sync(using: world.server)
    }
}

extension StoreKind {
    /// The kinds this platform can run. SQLite isn't available on Linux.
    static var available: [StoreKind] {
        #if canImport(GRDB)
        return [.memory, .sqlite]
        #else
        return [.memory]
        #endif
    }
}
