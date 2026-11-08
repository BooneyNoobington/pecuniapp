import Foundation
import Testing
@testable import PecuniaSync

/// One test for each row of the "What happens when..." table in `Pecuniapp.md`.
/// Each test's name is the row's first column, and `everyRowHasATest` keeps them in step.
@Suite("What happens when...")
struct WhatHappensWhenTests {
    private static let rowsWithTests: Set<String> = [
        "You enter different things on your phone and your iMac",
        "You change the amount on one device and the category on another",
        "You change the same field on two devices",
        "You delete a record on one device and edit it on another",
        "Two devices enter a price change or override for the same subscription and date",
        "You enter the same expense on both devices",
        "You merge the same duplicate on two devices",
        "The connection dies during a push",
        "A device is restored from an old backup",
        "You restore a backup onto a new device and keep using the old one",
        "You restore a device from a backup and enter something before it syncs",
        "The server is restored from an old backup",
        "A device's clock is far in the future",
        "A change comes from a newer app version",
        "A record refers to one that hasn't arrived yet",
    ]

    @Test("Every row in the design's table has a test")
    func everyRowHasATest() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let design = try String(
            contentsOf: root.appendingPathComponent("Pecuniapp.md"), encoding: .utf8)
        let section = try #require(design.components(separatedBy: "### What happens when...").last)
        let table = try #require(section.components(separatedBy: "\n### ").first)
        let rows = table.split(separator: "\n")
            .filter { $0.hasPrefix("|") }
            .dropFirst(2)
            .map { $0.split(separator: "|", omittingEmptySubsequences: true)[0] }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(Set(rows) == Self.rowsWithTests)
    }

    private let table = Device.transactions

    private func phoneAndIMac() throws -> (World, TestDevice, TestDevice) {
        let world = World()
        return (world, try world.makeDevice("phone"), try world.makeDevice("iMac"))
    }

    private func expectSame(_ devices: TestDevice...) {
        for device in devices.dropFirst() {
            #expect(device.database.tables == devices[0].database.tables)
            #expect(device.database.logs == devices[0].database.logs)
        }
    }

    /// Everything that was ever written, regardless of which device and number it's under now.
    private func writes(on device: TestDevice) -> Set<[String]> {
        Set(
            device.database.logs.values.joined().compactMap(\.decoded).map {
                [$0.record.rawValue, "\($0.fields)", String($0.time)]
            })
    }

    @Test("You enter different things on your phone and your iMac")
    func differentThings() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        let croissant = try phone.device.create(table, ["amount": -250])
        let salary = try imac.device.create(table, ["amount": 300_000])

        try await world.syncAll([phone, imac])

        for device in [phone, imac] {
            #expect(device.database.value(of: "amount", record: croissant, table: table) == -250)
            #expect(device.database.value(of: "amount", record: salary, table: table) == 300_000)
        }
        expectSame(phone, imac)
    }

    @Test("You change the amount on one device and the category on another")
    func differentFields() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        let record = try phone.device.create(table, ["amount": -250, "category": "food"])
        try await world.syncAll([phone, imac])

        world.advance()
        try phone.device.write(table, record, ["amount": -300])
        world.advance()
        try imac.device.write(table, record, ["category": "treats"])
        try await world.syncAll([phone, imac])

        for device in [phone, imac] {
            #expect(device.database.value(of: "amount", record: record, table: table) == -300)
            #expect(
                device.database.value(of: "category", record: record, table: table) == "treats")
        }
        expectSame(phone, imac)
    }

    @Test("You change the same field on two devices")
    func sameField() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        let record = try phone.device.create(table, ["note": "original"])
        try await world.syncAll([phone, imac])

        world.advance()
        try phone.device.write(table, record, ["note": "from the phone"])
        world.advance()
        try imac.device.write(table, record, ["note": "from the iMac"])
        try await world.syncAll([phone, imac])

        // The newest change wins on all devices.
        #expect(phone.database.value(of: "note", record: record, table: table) == "from the iMac")
        expectSame(phone, imac)

        // The older value stays in the log and can be restored.
        let history = phone.database.history(of: "note", record: record, table: table)
        #expect(history.map(\.value) == ["original", "from the phone", "from the iMac"])
        try phone.device.write(table, record, ["note": history[1].value])
        try await world.syncAll([phone, imac])
        #expect(imac.database.value(of: "note", record: record, table: table) == "from the phone")
        expectSame(phone, imac)
    }

    @Test("You delete a record on one device and edit it on another")
    func deleteAndEdit() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        let record = try phone.device.create(table, ["amount": -250, "note": "keep me"])
        try await world.syncAll([phone, imac])

        world.advance()
        try imac.device.delete(table, record)
        world.advance()
        try phone.device.write(table, record, ["amount": -300])
        try await world.syncAll([phone, imac])

        // It stays deleted, because the edit doesn't touch deleted_at.
        #expect(phone.database.isDeleted(record, in: table))
        #expect(phone.database.liveRecords(in: table)[record] == nil)
        expectSame(phone, imac)

        // It can be restored, including the edit and everything else it held.
        try imac.device.restore(table, record)
        try await world.syncAll([phone, imac])
        #expect(phone.database.liveRecords(in: table)[record]?["amount"] == -300)
        #expect(phone.database.liveRecords(in: table)[record]?["note"] == "keep me")
        expectSame(phone, imac)
    }

    @Test("Two devices enter a price change or override for the same subscription and date")
    func samePriceChange() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        let subscription = RecordID(rawValue: "electricity")

        let version = RecordID.subscriptionVersion(subscription: subscription, validFrom: "2026-12-01")
        try phone.device.write("subscription_versions", version, ["amount": -8000])
        world.advance()
        try imac.device.write("subscription_versions", version, ["amount": -8500])

        let override = RecordID.subscriptionOverride(subscription: subscription, occurrence: "2026-12-01")
        try phone.device.write("subscription_overrides", override, ["amount": -9000])
        try imac.device.write("subscription_overrides", override, ["skipped": true])

        try await world.syncAll([phone, imac])

        // Their IDs are derived from the subscription and date, so they merge into one record.
        #expect(phone.database.tables["subscription_versions"]?.count == 1)
        #expect(phone.database.tables["subscription_overrides"]?.count == 1)
        #expect(phone.database.value(of: "amount", record: version, table: "subscription_versions") == -8500)
        #expect(phone.database.record(override, in: "subscription_overrides") == ["amount": -9000, "skipped": true])
        expectSame(phone, imac)
    }

    @Test("You enter the same expense on both devices")
    func sameExpense() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        let coffee: [String: FieldValue] = ["account": "cash", "amount": -350, "date": "2026-11-06"]
        let first = try phone.device.create(table, coffee)
        let second = try imac.device.create(table, coffee)

        // A third, clearly different purchase isn't suggested.
        try phone.device.create(table, ["account": "cash", "amount": -350, "date": "2026-11-09"])

        try await world.syncAll([phone, imac])

        // Sync can't tell, so both are kept and only shown as possible duplicates.
        #expect(phone.database.liveRecords(in: table).count == 3)
        #expect(phone.device.possibleDuplicates() == [DuplicatePair(first, second)])
        #expect(imac.device.possibleDuplicates() == [DuplicatePair(first, second)])

        // A conflicting recipient rules it out.
        try phone.device.write(table, first, ["recipient": "bakery"])
        try imac.device.write(table, second, ["recipient": "supermarket"])
        #expect(phone.device.possibleDuplicates() == [DuplicatePair(first, second)])
        try await world.syncAll([phone, imac])
        #expect(phone.device.possibleDuplicates().isEmpty)
        try phone.device.write(table, second, ["recipient": "bakery"])

        // Dismissing it syncs like everything else, and both stay.
        #expect(phone.device.possibleDuplicates() == [DuplicatePair(first, second)])
        try phone.device.dismissDuplicates(DuplicatePair(first, second))
        try await world.syncAll([phone, imac])
        #expect(phone.device.possibleDuplicates().isEmpty)
        #expect(imac.device.possibleDuplicates().isEmpty)
        #expect(imac.database.liveRecords(in: table).count == 3)
        expectSame(phone, imac)
    }

    @Test("You merge the same duplicate on two devices")
    func mergeOnBoth() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        let coffee: [String: FieldValue] = ["account": "cash", "amount": -350, "date": "2026-11-06"]
        let first = try phone.device.create(table, coffee)
        var withRecipient = coffee
        withRecipient["recipient"] = "bakery"
        let second = try imac.device.create(table, withRecipient)
        try await world.syncAll([phone, imac])

        // Each device starts from the record it happens to be showing.
        try phone.device.mergeDuplicates(DuplicatePair(first, second))
        world.advance()
        try imac.device.mergeDuplicates(DuplicatePair(second, first))
        try await world.syncAll([phone, imac])

        // Exactly one record remains, and it didn't lose the recipient.
        let live = phone.database.liveRecords(in: table)
        #expect(live.count == 1)
        #expect(live.keys.first == min(first, second))
        #expect(live.values.first?["recipient"] == "bakery")
        #expect(phone.device.possibleDuplicates().isEmpty)
        expectSame(phone, imac)
    }

    @Test("The merge can't delete all of three copies of a purchase")
    func mergeThree() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        let coffee: [String: FieldValue] = ["account": "cash", "amount": -350, "date": "2026-11-06"]
        let ids = try [
            phone.device.create(table, coffee),
            phone.device.create(table, coffee),
            phone.device.create(table, coffee),
        ].sorted()
        try await world.syncAll([phone, imac])

        try phone.device.mergeDuplicates(DuplicatePair(ids[0], ids[1]))
        try imac.device.mergeDuplicates(DuplicatePair(ids[1], ids[2]))
        try await world.syncAll([phone, imac])

        #expect(phone.database.liveRecords(in: table).keys.sorted() == [ids[0]])
        expectSame(phone, imac)
    }

    @Test("The connection dies during a push")
    func connectionDies() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        world.server.maxBatchSize = 2
        for amount in 1...5 {
            try phone.device.create(table, ["amount": .int(Int64(amount))])
        }

        // The server stores the second batch, but the answer never arrives.
        var pushes = 0
        let answerLost = FlakyBackend(server: world.server) { call in
            guard call == .push else { return .delivered }
            pushes += 1
            return pushes == 2 ? .lostAfterServer : .delivered
        }
        do {
            _ = try await phone.device.sync(using: answerLost)
            Issue.record("the sync should have been interrupted")
        } catch is FlakyBackend.ConnectionLost {}
        #expect(world.server.entries(of: phone.id).count == 4)

        // The next push dies before reaching the server.
        let requestLost = FlakyBackend(server: world.server) { call in
            call == .push ? .lostBeforeServer : .delivered
        }
        do {
            _ = try await phone.device.sync(using: requestLost)
            Issue.record("the sync should have been interrupted")
        } catch is FlakyBackend.ConnectionLost {}
        #expect(world.server.entries(of: phone.id).count == 4)

        // Retrying is harmless, and each entry is on the server exactly once.
        let report = try await phone.sync()
        #expect(report.pushedEntries == 1)
        #expect(world.server.entries(of: phone.id).map(\.seq) == [1, 2, 3, 4, 5])

        try await world.syncAll([phone, imac])
        expectSame(phone, imac)
    }

    @Test("A device is restored from an old backup")
    func restoredFromOldBackup() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        for amount in 1...3 {
            try phone.device.create(table, ["amount": .int(Int64(amount))])
        }
        try await world.syncAll([phone, imac])
        let backup = phone.database
        let oldID = phone.id

        let lostInRestore = try phone.device.create(table, ["amount": 4])
        try await world.syncAll([phone, imac])

        try phone.restore(backup)
        #expect(phone.id == oldID)
        #expect(phone.database.record(lostInRestore, in: table) == nil)

        // The server has more from this device than the device itself does.
        let report = try await phone.sync()
        #expect(report.tookNewDeviceID)
        #expect(phone.id != oldID)
        #expect(phone.database.record(lostInRestore, in: table) != nil)

        // It can't reuse old numbers, because new entries go under its new ID.
        try phone.device.create(table, ["amount": 5])
        #expect(phone.database.high(phone.id) == 1)
        #expect(phone.database.high(oldID) == 4)

        try await world.syncAll([phone, imac])
        expectSame(phone, imac)
    }

    /// The example from the design review: both are at 100, the old phone pushes up to 105,
    /// and the new phone has 108 locally, so the server's number isn't above the new phone's.
    private func copiedDeviceExample(
        keychainMoves: Bool
    ) async throws -> (old: TestDevice, new: TestDevice, imac: TestDevice, idAtStart: DeviceID) {
        let world = World()
        let oldPhone = try world.makeDevice("old phone")
        let imac = try world.makeDevice("iMac")
        for amount in 1...100 {
            try oldPhone.device.create(table, ["amount": .int(Int64(amount))])
        }
        try await world.syncAll([oldPhone, imac])

        let newPhone = try world.makeDevice(
            "new phone", database: oldPhone.database,
            keychain: InMemoryKeychain(stored: keychainMoves ? oldPhone.id : nil))
        let idAtStart = newPhone.id

        for amount in 1...5 {
            try oldPhone.device.create(table, ["note": .string("old phone \(amount)")])
        }
        try await oldPhone.sync()
        for amount in 1...8 {
            try newPhone.device.create(table, ["note": .string("new phone \(amount)")])
        }
        try await world.syncAll([oldPhone, newPhone, imac])
        return (oldPhone, newPhone, imac, idAtStart)
    }

    @Test("You restore a backup onto a new device and keep using the old one")
    func backupOntoNewDevice() async throws {
        let (oldPhone, newPhone, imac, idAtStart) = try await copiedDeviceExample(keychainMoves: false)

        // The Keychain doesn't move with a backup, so the new phone took its own ID right away.
        #expect(idAtStart != oldPhone.id)
        #expect(newPhone.id == idAtStart)
        #expect(writes(on: imac).count == 113)
        expectSame(oldPhone, newPhone, imac)
    }

    @Test("A copied device that keeps its ID is still repaired, with nothing lost")
    func copiedDeviceKeepingItsID() async throws {
        // Even if the identity check can't tell, comparing entries with the server reveals it.
        let (oldPhone, newPhone, imac, idAtStart) = try await copiedDeviceExample(keychainMoves: true)

        #expect(idAtStart == oldPhone.id)
        #expect(newPhone.id != idAtStart)
        #expect(newPhone.database.high(newPhone.id) == 8)
        #expect(writes(on: imac).count == 113)
        expectSame(oldPhone, newPhone, imac)
    }

    @Test("You restore a device from a backup and enter something before it syncs")
    func restoredThenWrites() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        for amount in 1...3 {
            try phone.device.create(table, ["amount": .int(Int64(amount))])
        }
        try await world.syncAll([phone, imac])
        let backup = phone.database

        let pushedThenLost = try phone.device.create(table, ["note": "pushed, then lost locally"])
        try await world.syncAll([phone, imac])

        // Same phone, same Keychain, so the identity check can't notice anything.
        try phone.restore(backup)
        let oldID = phone.id
        let atTheTill = try phone.device.create(table, ["note": "entered at the till"])
        let alsoNew = try phone.device.create(table, ["note": "entered after that"])
        #expect(phone.database.high(oldID) == 5)

        // This number now means something different on the phone and on the server.
        let report = try await phone.sync()
        #expect(report.splitLogsRepaired == 1)
        #expect(report.reissuedEntries == 2)
        #expect(report.tookNewDeviceID)
        #expect(phone.id != oldID)
        #expect(world.server.entries(of: oldID).count == 4)

        try await world.syncAll([phone, imac])
        for device in [phone, imac] {
            for record in [pushedThenLost, atTheTill, alsoNew] {
                #expect(device.database.record(record, in: table) != nil)
            }
        }
        expectSame(phone, imac)
    }

    @Test("A split is also repaired by devices holding the other side of it")
    func splitSeenByOtherDevice() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        for amount in 1...3 {
            try phone.device.create(table, ["amount": .int(Int64(amount))])
        }
        try await world.syncAll([phone, imac])
        let phoneBackup = phone.database
        let serverBackup = world.server.snapshot()

        let onlyOnIMac = try phone.device.create(table, ["note": "pushed, seen by the iMac"])
        try await world.syncAll([phone, imac])

        // Both the phone and the server go back in time, so the phone can't notice anything.
        world.server.restore(serverBackup)
        try phone.restore(phoneBackup)
        let onlyOnPhone = try phone.device.create(table, ["note": "entered after the restore"])
        let report = try await phone.sync()
        #expect(!report.tookNewDeviceID)

        // The iMac holds a different entry at the same number, and that must not get lost.
        let iMacReport = try await imac.sync()
        #expect(iMacReport.splitLogsRepaired == 1)

        try await world.syncAll([phone, imac])
        for device in [phone, imac] {
            #expect(device.database.record(onlyOnIMac, in: table) != nil)
            #expect(device.database.record(onlyOnPhone, in: table) != nil)
        }
        expectSame(phone, imac)
    }

    /// A rare case the simulation found about once in 25,000 runs, written out so that every test
    /// run covers it. Re-issuing an entry gives it the same content wherever it happens, so without
    /// the chain, two branches of a device's log could end in identical entries.
    @Test("A split is noticed even when the newest entries say the same thing")
    func splitBehindMatchingEntries() async throws {
        let world = World()
        let phone = try world.makeDevice("phone")
        let imac = try world.makeDevice("iMac")
        let tablet = try world.makeDevice("tablet")
        let emptyTablet = tablet.database
        let emptyServer = world.server.snapshot()

        // Everyone has an entry from the tablet.
        let fromTablet = try tablet.device.create(table, ["note": "from the tablet"])
        try await world.syncAll([tablet, phone, imac])
        let phoneBackup = phone.database
        let phoneID = phone.id

        // The tablet's history splits, so the phone re-issues that entry after its own first one,
        // and the iMac receives both.
        let firstBranch = try phone.device.create(table, ["note": "first branch"])
        world.server.restore(emptyServer)
        try tablet.restore(emptyTablet)
        try tablet.device.create(table, ["note": "the tablet after its restore"])
        try await tablet.sync()
        try await phone.sync()
        #expect(phone.database.high(phoneID) == 2)
        try await imac.sync()
        #expect(imac.database.high(phoneID) == 2)

        // The phone and the server go back in time, and the phone does the same again, on top of
        // a different first entry.
        world.server.restore(emptyServer)
        try await tablet.sync()
        try phone.restore(phoneBackup)
        let secondBranch = try phone.device.create(table, ["note": "second branch"])
        try await phone.sync()
        #expect(phone.id == phoneID)
        #expect(phone.database.high(phoneID) == 2)
        #expect(
            imac.database.logs[phoneID]?[1].decoded?.record
                == phone.database.logs[phoneID]?[1].decoded?.record)

        // Both logs end in the same re-issued entry, but they have different histories.
        let report = try await imac.sync()
        #expect(report.splitLogsRepaired == 1)

        try await world.syncAll([tablet, phone, imac])
        for device in [tablet, phone, imac] {
            for record in [fromTablet, firstBranch, secondBranch] {
                #expect(device.database.record(record, in: table) != nil)
            }
        }
        expectSame(tablet, phone, imac)
    }

    @Test("The server is restored from an old backup")
    func serverRestored() async throws {
        let world = World()
        let phone = try world.makeDevice("phone")
        let oldTablet = try world.makeDevice("old tablet")
        try phone.device.create(table, ["amount": 1])
        try oldTablet.device.create(table, ["amount": 2])
        try await world.syncAll([phone, oldTablet])
        let oldBackup = world.server.snapshot()

        // The tablet is retired, and its last entries only survive on the phone.
        let lastFromTablet = try oldTablet.device.create(table, ["amount": 3])
        try await world.syncAll([phone, oldTablet])
        let lastFromPhone = try phone.device.create(table, ["amount": 4])
        try await phone.sync()

        world.server.restore(oldBackup)
        let tabletID = oldTablet.id
        #expect(world.server.entries(of: tabletID).count == 1)

        // The phone uploads what the server lost, including the retired device's entries.
        let report = try await phone.sync()
        #expect(report.pushedEntries == 2)
        #expect(world.server.entries(of: tabletID).count == 2)

        let newcomer = try world.makeDevice("newcomer")
        try await newcomer.sync()
        #expect(newcomer.database.record(lastFromTablet, in: table) != nil)
        #expect(newcomer.database.record(lastFromPhone, in: table) != nil)
        expectSame(phone, newcomer)

        // Even on an empty server, one remaining device can rebuild the whole log.
        world.server.wipe()
        try await phone.sync()
        #expect(world.server.entries(of: tabletID).count == 2)
        #expect(try await world.server.listDevices().contains { $0.id == tabletID })

        let another = try world.makeDevice("another")
        try await another.sync()
        #expect(another.database.tables == phone.database.tables)
    }

    @Test("A device's clock is far in the future")
    func clockInTheFuture() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        let record = try imac.device.create(table, ["amount": -250, "note": "real time"])
        let untouched = try imac.device.create(table, ["amount": -100])
        try await world.syncAll([phone, imac])

        // The sync status warns on the device with the wrong clock, and only there.
        phone.clock.offset = 70 * World.year
        #expect(try await phone.sync().clockLooksWrong)
        #expect(try await imac.sync().clockLooksWrong == false)

        // Only the fields it edits get a future timestamp.
        try phone.device.write(table, record, ["amount": -300])
        try await world.syncAll([phone, imac])
        let future = try #require(imac.database.state(of: "amount", record: record, table: table))
        #expect(future.value == -300)
        #expect(future.stamp.time > world.time + 69 * World.year)

        let noteStamp = try #require(imac.database.state(of: "note", record: record, table: table)?.stamp)
        #expect(noteStamp.time <= world.time)
        let otherStamp = try #require(imac.database.state(of: "amount", record: untouched, table: table)?.stamp)
        #expect(otherStamp.time <= world.time)

        // Later edits go just past that timestamp and win.
        world.advance()
        try imac.device.write(table, record, ["amount": -400])
        let edited = try #require(imac.database.state(of: "amount", record: record, table: table))
        #expect(edited.value == -400)
        #expect(edited.stamp.time == future.stamp.time + 1)

        // Everything else stays on real time.
        let fresh = try imac.device.create(table, ["amount": -500])
        let freshStamp = try #require(imac.database.state(of: "amount", record: fresh, table: table)?.stamp)
        #expect(freshStamp.time == world.time)

        // Correcting the date fixes the rest, with nothing to repair.
        phone.clock.offset = 0
        try await world.syncAll([phone, imac])
        #expect(phone.database.value(of: "amount", record: record, table: table) == -400)
        try phone.device.write(table, record, ["note": "back to normal"])
        let repaired = try #require(phone.database.state(of: "note", record: record, table: table)?.stamp)
        #expect(repaired.time == world.time)
        #expect(try await phone.sync().clockLooksWrong == false)
        try await world.syncAll([phone, imac])
        expectSame(phone, imac)

        // An edit made elsewhere without having seen the future value loses to it...
        phone.clock.offset = 70 * World.year
        try phone.device.write(table, untouched, ["amount": -111])
        phone.clock.offset = 0
        try imac.device.write(table, untouched, ["amount": -222])
        try await world.syncAll([phone, imac])
        #expect(imac.database.value(of: "amount", record: untouched, table: table) == -111)

        // ...but the older value stays in the log and can be restored.
        let values = imac.database.history(of: "amount", record: untouched, table: table).map(\.value)
        #expect(values.contains(-222))
        try imac.device.write(table, untouched, ["amount": -222])
        try await world.syncAll([phone, imac])
        #expect(phone.database.value(of: "amount", record: untouched, table: table) == -222)
        expectSame(phone, imac)
    }

    @Test("A change comes from a newer app version")
    func newerAppVersion() async throws {
        let world = World()
        let phone = try world.makeDevice("phone", supportedSchema: 2)
        let imac = try world.makeDevice("iMac", supportedSchema: 1)

        let record = try phone.device.create(table, ["amount": -250, "new_in_v2": "something"])
        try await phone.sync()

        // It's stored but not applied, and the app asks you to update.
        let report = try await imac.sync()
        #expect(report.updateRequired)
        #expect(imac.database.high(phone.id) == 1)
        #expect(imac.database.record(record, in: table) == nil)

        // Updating applies it, including fields this version may not use yet.
        imac.device.appUpdated(toSchema: 2)
        #expect(imac.database.value(of: "new_in_v2", record: record, table: table) == "something")
        #expect(try await imac.sync().updateRequired == false)
        expectSame(phone, imac)
    }

    @Test("An entry in a newer format is kept and uploaded again, even though it can't be read")
    func newerFormat() async throws {
        let (world, phone, imac) = try phoneAndIMac()
        try await phone.sync()
        let payload = Data(#"{"format":99,"anything":"at all"}"#.utf8)
        world.server.forceInsert(StoredEntry(device: phone.id, seq: 1, payload: payload))

        let report = try await imac.sync()
        #expect(report.updateRequired)
        #expect(report.problems.isEmpty)
        #expect(imac.database.logs[phone.id]?.first?.decoded == nil)

        world.server.wipe()
        try await imac.sync()
        #expect(world.server.entries(of: phone.id).first?.payload == payload)
    }

    @Test("A record refers to one that hasn't arrived yet")
    func missingReference() async throws {
        let world = World()
        let phone = try world.makeDevice("phone")
        let imac = try world.makeDevice("iMac")
        let tablet = try world.makeDevice("tablet")

        let category = try phone.device.create("categories", ["name": "food"])
        try await phone.sync()
        try await imac.sync()
        let purchase = try imac.device.create(
            table, ["amount": -250, "category": .string(category.rawValue)])
        try await imac.sync()

        // The tablet hears from the iMac but not yet from the phone.
        let partial = HidingBackend(server: world.server, hidden: phone.id)
        let report = try await tablet.device.sync(using: partial)

        // Nothing fails, and the app can show the purchase with its category as unknown.
        #expect(report.problems.isEmpty)
        #expect(tablet.database.record(purchase, in: table) != nil)
        #expect(tablet.database.record(category, in: "categories") == nil)

        try await tablet.sync()
        #expect(tablet.database.record(category, in: "categories")?["name"] == "food")
    }
}

/// Pretends one device doesn't exist yet, as if its entries hadn't reached this device.
private final class HidingBackend: SyncBackend, @unchecked Sendable {
    private let server: InMemoryServer
    private let hidden: DeviceID

    init(server: InMemoryServer, hidden: DeviceID) {
        self.server = server
        self.hidden = hidden
    }

    var maxBatchSize: Int { server.maxBatchSize }

    func serverTime() async throws -> Int64? { try await server.serverTime() }

    func listDevices() async throws -> [DeviceRecord] {
        try await server.listDevices().filter { $0.id != hidden }
    }

    func registerDevice(_ device: DeviceRecord) async throws {
        try await server.registerDevice(device)
    }

    func newestEntry(of device: DeviceID) async throws -> StoredEntry? {
        try await server.newestEntry(of: device)
    }

    func push(_ batch: [StoredEntry]) async throws { try await server.push(batch) }

    func pull(device: DeviceID, after seq: UInt64, limit: Int) async throws -> [StoredEntry] {
        try await server.pull(device: device, after: seq, limit: limit)
    }
}
