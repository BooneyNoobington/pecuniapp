import Foundation
@testable import PecuniaSync

/// Behaves like the PocketBase collections in the design: entries are only ever appended,
/// there's a unique index on device and number, and batches are all-or-nothing.
///
/// Only ever used from one task at a time, which is why `@unchecked Sendable` is safe here.
final class InMemoryServer: SyncBackend, @unchecked Sendable {
    enum Failure: Error, Equatable {
        case uniqueIndexViolation
        case batchTooLarge
    }

    struct Snapshot {
        fileprivate var devices: [DeviceID: DeviceRecord]
        fileprivate var changes: [DeviceID: [UInt64: StoredEntry]]
    }

    var maxBatchSize = 50
    /// A server may return fewer entries than asked for.
    var maxPageSize = Int.max
    var clock: () -> Int64? = { nil }

    private var devices: [DeviceID: DeviceRecord] = [:]
    private var changes: [DeviceID: [UInt64: StoredEntry]] = [:]

    // MARK: SyncBackend

    func serverTime() async throws -> Int64? {
        clock()
    }

    func listDevices() async throws -> [DeviceRecord] {
        devices.values.sorted { $0.id < $1.id }
    }

    func registerDevice(_ device: DeviceRecord) async throws {
        if devices[device.id] == nil {
            devices[device.id] = device
        }
    }

    func newestEntry(of device: DeviceID) async throws -> StoredEntry? {
        guard let entries = changes[device], let highest = entries.keys.max() else { return nil }
        return entries[highest]
    }

    func push(_ batch: [StoredEntry]) async throws {
        guard batch.count <= maxBatchSize else { throw Failure.batchTooLarge }
        var seen = Set<[String]>()
        for entry in batch {
            let key = [entry.device.rawValue, String(entry.seq)]
            guard changes[entry.device]?[entry.seq] == nil, seen.insert(key).inserted else {
                throw Failure.uniqueIndexViolation
            }
        }
        for entry in batch {
            changes[entry.device, default: [:]][entry.seq] = entry
        }
    }

    func pull(device: DeviceID, after seq: UInt64, limit: Int) async throws -> [StoredEntry] {
        let entries = changes[device]?.values.filter { $0.seq > seq } ?? []
        return Array(entries.sorted { $0.seq < $1.seq }.prefix(min(limit, maxPageSize)))
    }

    // MARK: Test controls

    func snapshot() -> Snapshot {
        Snapshot(devices: devices, changes: changes)
    }

    func restore(_ snapshot: Snapshot) {
        devices = snapshot.devices
        changes = snapshot.changes
    }

    func wipe() {
        devices = [:]
        changes = [:]
    }

    func entries(of device: DeviceID) -> [StoredEntry] {
        (changes[device]?.values.sorted { $0.seq < $1.seq }) ?? []
    }

    /// Adds an entry without any checks, as a superuser could.
    func forceInsert(_ entry: StoredEntry) {
        changes[entry.device, default: [:]][entry.seq] = entry
    }

    /// Removes an entry without any checks, as a superuser could.
    func forceRemove(device: DeviceID, seq: UInt64) {
        changes[device]?[seq] = nil
    }

    func forceRegister(_ device: DeviceRecord) {
        devices[device.id] = device
    }
}

/// Puts failures between a device and the server.
final class FlakyBackend: SyncBackend, @unchecked Sendable {
    enum Call {
        case time, list, register, newest, push, pull
    }

    enum Outcome {
        case delivered
        /// The connection dies before the server gets the request.
        case lostBeforeServer
        /// The server processes the request, but the answer never arrives.
        case lostAfterServer
    }

    struct ConnectionLost: Error {}

    private let server: InMemoryServer
    private let outcome: (Call) -> Outcome
    private let beforeCall: () async throws -> Void

    /// `beforeCall` runs before every request, so that other things can happen in between.
    init(
        server: InMemoryServer,
        beforeCall: @escaping () async throws -> Void = {},
        outcome: @escaping (Call) -> Outcome
    ) {
        self.server = server
        self.beforeCall = beforeCall
        self.outcome = outcome
    }

    var maxBatchSize: Int { server.maxBatchSize }

    private func perform<T>(_ call: Call, _ work: () async throws -> T) async throws -> T {
        try await beforeCall()
        switch outcome(call) {
        case .delivered:
            return try await work()
        case .lostBeforeServer:
            throw ConnectionLost()
        case .lostAfterServer:
            _ = try await work()
            throw ConnectionLost()
        }
    }

    func serverTime() async throws -> Int64? {
        try await perform(.time) { try await server.serverTime() }
    }

    func listDevices() async throws -> [DeviceRecord] {
        try await perform(.list) { try await server.listDevices() }
    }

    func registerDevice(_ device: DeviceRecord) async throws {
        try await perform(.register) { try await server.registerDevice(device) }
    }

    func newestEntry(of device: DeviceID) async throws -> StoredEntry? {
        try await perform(.newest) { try await server.newestEntry(of: device) }
    }

    func push(_ batch: [StoredEntry]) async throws {
        try await perform(.push) { try await server.push(batch) }
    }

    func pull(device: DeviceID, after seq: UInt64, limit: Int) async throws -> [StoredEntry] {
        try await perform(.pull) { try await server.pull(device: device, after: seq, limit: limit) }
    }
}
