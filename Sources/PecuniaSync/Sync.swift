import Foundation

public struct DeviceRecord: Hashable, Sendable {
    public var id: DeviceID
    public var encryptedName: Data

    public init(id: DeviceID, encryptedName: Data) {
        self.id = id
        self.encryptedName = encryptedName
    }
}

/// The only way the app reaches its backend. Logging in and storing the wrapped keys join this
/// when encryption and the real server are added.
public protocol SyncBackend: Sendable {
    /// Batches are all-or-nothing and limited in size, so pushes go out in chunks.
    var maxBatchSize: Int { get }

    func serverTime() async throws -> Int64?
    func listDevices() async throws -> [DeviceRecord]
    func registerDevice(_ device: DeviceRecord) async throws
    /// The device's highest-numbered entry, or nil if the server has none.
    func newestEntry(of device: DeviceID) async throws -> StoredEntry?
    func push(_ batch: [StoredEntry]) async throws
    func pull(device: DeviceID, after seq: UInt64, limit: Int) async throws -> [StoredEntry]
}

public enum SyncProblem: Hashable, Sendable {
    /// A device's numbers have a hole. This is reported, never skipped over.
    case gap(device: DeviceID, expected: UInt64, found: UInt64)
    case unreadableEntry(device: DeviceID, seq: UInt64)
    /// An entry doesn't follow the one before it, so the log mixes two different histories.
    case brokenChain(device: DeviceID, seq: UInt64)
}

public struct SyncReport: Equatable, Sendable {
    public var pulledEntries = 0
    public var pushedEntries = 0
    public var tookNewDeviceID = false
    /// How many devices' logs were found to have split from the server's, and repaired.
    public var splitLogsRepaired = 0
    /// Entries that only existed on this side of a split, now re-issued under this device's ID.
    public var reissuedEntries = 0
    public var problems: [SyncProblem] = []
    /// Some entries are stored but can't be applied until the app is updated.
    public var updateRequired = false
    /// This device's clock minus the server's, if the server's time is known.
    public var clockOffsetFromServer: Int64?
    public var clockLooksWrong = false
}

extension Device {
    private static let pullPageSize = 200

    private typealias Fetched = (stored: StoredEntry, decoded: ChangeEntry?)

    /// One round of sync. All network reads happen first, then local changes are applied in one
    /// transaction, then uploads go out. If the connection dies at any point, nothing is lost
    /// and the next round works out from scratch what's still missing.
    public func sync(using backend: any SyncBackend) async throws -> SyncReport {
        guard !isSyncing else { throw DeviceError.alreadySyncing }
        isSyncing = true
        defer { isSyncing = false }
        guard var me = try deviceID() else { throw DeviceError.notOpen }

        var report = SyncReport()
        let myHighAtStart = try store.read { try $0.high(me) }

        if let serverTime = try await backend.serverTime() {
            let offset = environment.now() &- serverTime
            report.clockOffsetFromServer = offset
            report.clockLooksWrong = offset.magnitude > clockWarningThreshold.magnitude
        }

        // Remember every device the server knows about, whatever happens later in this sync.
        let listed = try await backend.listDevices()
        var registered = Set(listed.map(\.id))
        var known = try store.write { tx in
            for device in listed {
                try tx.setKnownDevice(device.id, encryptedName: device.encryptedName)
            }
            return try tx.knownDevices()
        }

        // Compare each device's log with the server's. Each entry names the one before it, so if
        // the entries at the highest number both sides have are identical, everything before them
        // is too. If they differ, the history has split in two.
        var serverHigh: [DeviceID: UInt64] = [:]
        var newEntries: [DeviceID: [Fetched]] = [:]
        var splitLogs: [DeviceID: [Fetched]] = [:]
        var mustNotUpload = Set<DeviceID>()
        var isRolledBackCopy = false

        for id in known.keys.sorted() {
            let newest = try await backend.newestEntry(of: id)
            let server = newest?.seq ?? 0
            let local = try store.read { try $0.high(id) }
            serverHigh[id] = server
            guard let newest else { continue }

            let hasSplit: Bool
            if server <= local {
                hasSplit = try store.read { try $0.logEntry(id, seq: server)?.stored } != newest
            } else if local > 0 {
                let overlap = try await backend.pull(device: id, after: local - 1, limit: 1)
                let mine = try store.read { try $0.logEntry(id, seq: local)?.stored }
                hasSplit = overlap.first != mine
            } else {
                hasSplit = false
            }

            if hasSplit {
                let whole = try await fetchEntries(
                    of: id, after: 0, upTo: server, from: backend, report: &report)
                if UInt64(whole.count) == server {
                    splitLogs[id] = whole
                } else {
                    // Without the whole log the split can't be repaired yet, and uploading on
                    // top of it would make things worse.
                    mustNotUpload.insert(id)
                }
            } else if server > local {
                // The server has more from this device than the device itself remembers, so the
                // database is an older copy. A new ID keeps it from reusing numbers.
                if id == me {
                    isRolledBackCopy = true
                }
                newEntries[id] = try await fetchEntries(
                    of: id, after: local, upTo: server, from: backend, report: &report)
            }
        }

        // Apply everything in one transaction.
        var newID: DeviceID?
        let applied = try store.write { tx -> Bool in
            // You may have entered something while this was going on. That's fine unless this
            // device's own log is about to change, because the comparison is then out of date.
            // The next round starts over with the new entries included.
            if try tx.high(me) != myHighAtStart, isRolledBackCopy || splitLogs[me] != nil {
                return false
            }

            // An entry from a newer format can't be re-issued, so a split involving one has to
            // wait until the app is updated. Nothing is lost in the meantime.
            for (id, whole) in splitLogs {
                let local = try tx.logEntries(id, after: 0)
                if local[Self.firstDifference(local, whole)...].contains(where: { $0.decoded == nil }) {
                    mustNotUpload.insert(id)
                    splitLogs[id] = nil
                    report.updateRequired = true
                }
            }

            if isRolledBackCopy || splitLogs[me] != nil {
                me = try takeNewDeviceID(tx)
                newID = me
                report.tookNewDeviceID = true
            }
            var orphans: [ChangeEntry] = []
            for (id, whole) in splitLogs.sorted(by: { $0.key < $1.key }) {
                let local = try tx.logEntries(id, after: 0)
                orphans += local[Self.firstDifference(local, whole)...].compactMap(\.decoded)
                try tx.replaceLog(
                    of: id, with: whole.map { LogEntry(stored: $0.stored, decoded: $0.decoded) })
                report.splitLogsRepaired += 1
            }
            for (id, entries) in newEntries.sorted(by: { $0.key < $1.key }) where splitLogs[id] == nil {
                for entry in entries {
                    try tx.append(entry.stored, decoded: entry.decoded, supportedSchema: supportedSchema)
                }
                report.pulledEntries += entries.count
            }
            if !splitLogs.isEmpty {
                try tx.recalculateTables(supportedSchema: supportedSchema)
                for orphan in orphans {
                    try reissue(orphan, in: tx)
                }
                report.reissuedEntries = orphans.count
            }
            report.updateRequired =
                try report.updateRequired || tx.heldBackCount(supportedSchema: supportedSchema) > 0
            return true
        }
        if let newID {
            identity.write(newID)
            known[newID] = Data(name.utf8)
        }
        guard applied else { return report }

        // Upload whatever the server lacks, for every device, not only this one. That way any
        // one remaining device can rebuild the whole log after the server loses data.
        if !registered.contains(me) {
            try await backend.registerDevice(
                DeviceRecord(id: me, encryptedName: known[me] ?? Data(name.utf8)))
            registered.insert(me)
        }
        for id in known.keys.sorted() where !mustNotUpload.contains(id) {
            let pending = try store.read { [serverHigh] in
                try $0.logEntries(id, after: serverHigh[id, default: 0])
            }
            guard !pending.isEmpty else { continue }
            if !registered.contains(id) {
                try await backend.registerDevice(
                    DeviceRecord(id: id, encryptedName: known[id] ?? Data()))
                registered.insert(id)
            }
            var index = 0
            while index < pending.count {
                let end = min(index + backend.maxBatchSize, pending.count)
                try await backend.push(pending[index..<end].map(\.stored))
                report.pushedEntries += end - index
                index = end
            }
        }
        return report
    }

    /// Fetches a device's entries in order, stopping at a hole, an unreadable entry or a broken link.
    private func fetchEntries(
        of id: DeviceID,
        after start: UInt64,
        upTo target: UInt64,
        from backend: any SyncBackend,
        report: inout SyncReport
    ) async throws -> [Fetched] {
        var fetched: [Fetched] = []
        var next = start
        var previous = start == 0 ? nil : try store.read { try $0.logEntry(id, seq: start)?.decoded?.id }
        // An entry in a newer format can't be read, so the link after it can't be checked.
        var canCheckLink = start == 0 || previous != nil
        while next < target {
            let page = try await backend.pull(device: id, after: next, limit: Self.pullPageSize)
            guard !page.isEmpty else {
                report.problems.append(.gap(device: id, expected: next + 1, found: target))
                return fetched
            }
            for stored in page {
                guard stored.seq == next + 1, stored.device == id else {
                    report.problems.append(.gap(device: id, expected: next + 1, found: stored.seq))
                    return fetched
                }
                do {
                    switch try codec.decode(stored) {
                    case .entry(let entry):
                        guard !canCheckLink || entry.previous == previous else {
                            report.problems.append(.brokenChain(device: id, seq: stored.seq))
                            return fetched
                        }
                        fetched.append((stored, entry))
                        previous = entry.id
                        canCheckLink = true
                    case .newerFormat:
                        fetched.append((stored, nil))
                        canCheckLink = false
                    }
                } catch {
                    report.problems.append(.unreadableEntry(device: id, seq: stored.seq))
                    return fetched
                }
                next = stored.seq
            }
        }
        return fetched
    }

    /// The index of the first entry where a device's local log and the server's differ.
    private static func firstDifference(_ local: [LogEntry], _ server: [Fetched]) -> Int {
        var index = 0
        while index < local.count, index < server.count, local[index].stored == server[index].stored {
            index += 1
        }
        return index
    }

    /// Gives an entry that only exists on this side of a split a new place in this device's log.
    /// It keeps its time, so it still beats whatever it was written on top of.
    private func reissue(_ entry: ChangeEntry, in tx: any StoreAccess) throws {
        try appendEntry(
            tx,
            table: entry.table,
            record: entry.record,
            fields: entry.fields,
            time: entry.time,
            schema: entry.schema
        )
    }
}
