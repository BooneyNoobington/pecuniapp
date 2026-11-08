#!/usr/bin/env python3
"""Breaks the sync core on purpose, one rule at a time, and checks that the tests notice.

Each mutant replaces exact text in a source file, runs the whole test suite with a timeout, and
restores the file. The originals are also copied aside first and restored at the end.

Run it with no arguments for every mutant, or pass words to only run the mutants matching them:

    python3 Tools/mutation_test.py
    python3 Tools/mutation_test.py keychain clock

Set PECUNIA_SIM_PARALLELISM=2 to go easy on a machine that shouldn't run flat out.

A mutant that isn't caught means a rule could break without any test noticing.
"""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Sources/PecuniaSync"

MUTANTS = [
    ("An edit doesn't go past the value it replaces (no per-field clock)", "Device.swift", [
        ("return max(now, newest == .max ? newest : newest + 1)", "_ = newest; return now"),
    ]),
    ("The last entry to arrive wins, instead of the newest", "Database.swift", [
        ("current.stamp >= stamp {", "current.stamp >= stamp, false {"),
    ]),
    ("Ties aren't broken by device ID and number", "ChangeEntry.swift", [
        ("if lhs.device != rhs.device { return lhs.device < rhs.device }\n        return lhs.seq < rhs.seq",
         "return false"),
    ]),
    ("A split in a device's history isn't noticed", "Sync.swift", [
        ("hasSplit = database.logs[id]?[Int(server) - 1].stored != newest", "hasSplit = false"),
        ("hasSplit = overlap.first != database.logs[id]?[Int(local) - 1].stored",
         "_ = overlap; hasSplit = false"),
    ]),
    ("A split only notices when the server is behind", "Sync.swift", [
        ("hasSplit = overlap.first != database.logs[id]?[Int(local) - 1].stored",
         "_ = overlap; hasSplit = false"),
    ]),
    ("A split only notices when the server is ahead", "Sync.swift", [
        ("hasSplit = database.logs[id]?[Int(server) - 1].stored != newest", "hasSplit = false"),
    ]),
    ("Entries on this side of a split are dropped, not re-issued", "Sync.swift", [
        ("orphans += (database.logs[id] ?? [])[split...].compactMap(\\.decoded)", "_ = split"),
    ]),
    ("A re-issued entry gets the current time instead of its original one", "Sync.swift", [
        ("time: entry.time,", "time: environment.now(),"),
    ]),
    ("Entries don't name the one before them", "Device.swift", [
        ("id: newEntryID(),\n            previous: database.logs[me]?.last?.decoded?.id,",
         'id: "x",\n            previous: database.high(me) == 0 ? nil : "x",'),
    ]),
    ("The chain isn't checked when pulling", "Sync.swift", [
        ("guard !canCheckLink || entry.previous == previous else {", "guard true else {"),
    ]),
    ("A split doesn't work the tables out again", "Sync.swift", [
        ("            recalculateTables()\n            for orphan in orphans {",
         "            for orphan in orphans {"),
    ]),
    ("Devices only upload their own entries", "Sync.swift", [
        ("for id in database.knownDevices.keys.sorted() where !mustNotUpload.contains(id) {",
         "for id in [me] where !mustNotUpload.contains(id) {"),
    ]),
    ("A restored copy keeps its ID", "Sync.swift", [
        ("isRolledBackCopy = true", "_ = isRolledBackCopy"),
    ]),
    ("A hole in a device's numbers is skipped over", "Sync.swift", [
        ("guard stored.seq == next + 1, stored.device == id else {", "guard stored.device == id else {"),
    ]),
    ("A write during a sync isn't accounted for", "Sync.swift", [
        ("if database.high(me) != myHighAtStart, isRolledBackCopy || splitLogs[me] != nil {",
         "if false, database.high(me) != myHighAtStart, isRolledBackCopy || splitLogs[me] != nil {"),
    ]),
    ("Pushes aren't split into batches", "Sync.swift", [
        ("let end = min(sent + UInt64(backend.maxBatchSize), local)", "let end = local"),
    ]),
    ("Other devices aren't registered again after the server loses them", "Sync.swift", [
        ("            if !registered.contains(id) {\n                try await backend.registerDevice(\n"
         "                    DeviceRecord(id: id, encryptedName: database.knownDevices[id] ?? Data()))\n"
         "                registered.insert(id)\n            }\n            while sent < local {",
         "            while sent < local {"),
    ]),
    ("An unrepairable split still uploads on top", "Sync.swift", [
        ("                    mustNotUpload.insert(id)\n                }\n            } else if server > local {",
         "                }\n            } else if server > local {"),
    ]),
    ("A device can run two syncs at once", "Sync.swift", [
        ("guard !isSyncing else { throw DeviceError.alreadySyncing }\n", ""),
    ]),
    ("An unreadable entry stops nothing", "Sync.swift", [
        ("                    report.problems.append(.unreadableEntry(device: id, seq: stored.seq))\n                    return fetched",
         "                    report.problems.append(.unreadableEntry(device: id, seq: stored.seq))\n                    next = stored.seq; continue"),
    ]),
    ("Entries from a newer app version are applied anyway", "Database.swift", [
        ("if let decoded, decoded.schema <= supportedSchema {\n            Self.apply(decoded, to: &tables)",
         "if let decoded {\n            Self.apply(decoded, to: &tables)"),
    ]),
    ("Updating the app doesn't apply what was held back", "Device.swift", [
        ("        database.tables = database.rebuiltTables(supportedSchema: supportedSchema)\n", ""),
    ]),
    ("The clock warning never shows", "Sync.swift", [
        ("report.clockLooksWrong = offset.magnitude > clockWarningThreshold.magnitude",
         "report.clockLooksWrong = false"),
    ]),
    ("Restoring a record doesn't clear its deleted date", "Device.swift", [
        ("try write(table, record, [Database.deletedAt: .null])",
         "try write(table, record, [Database.deletedAt: .int(1)])"),
    ]),
    ("The Keychain check is ignored", "Device.swift", [
        ("if database.deviceID != stored {", "if database.deviceID == nil {"),
    ]),
    ("A locked Keychain is treated as missing", "Device.swift", [
        ("throw DeviceError.identityStoreLocked", "takeNewDeviceID()"),
    ]),
    ("Deleting wipes the record's other fields", "Device.swift", [
        ("try write(table, record, [Database.deletedAt: .int(environment.now())])",
         "var fields: [String: FieldValue] = [:]; for name in database.record(record, in: table)?.keys ?? [:].keys { fields[name] = .null }; fields[Database.deletedAt] = .int(environment.now()); try write(table, record, fields)"),
    ]),
    ("A merge keeps whichever record it was shown first", "Duplicates.swift", [
        ("low = min(first, second)\n        high = max(first, second)", "low = first\n        high = second"),
    ]),
    ("A merge loses fields only the other record had", "Duplicates.swift", [
        ("        if !missing.isEmpty {\n            try write(Self.transactions, pair.low, missing)\n        }\n", ""),
    ]),
    ("A dismissal doesn't hide the pair", "Duplicates.swift", [
        ("if !isDismissed(pair) {", "if true {"),
    ]),
    ("A conflicting recipient doesn't rule out a duplicate", "Duplicates.swift", [
        ("return firstRecipient.isNull || secondRecipient.isNull || firstRecipient == secondRecipient",
         "return true"),
    ]),
    ("An entry stored in the wrong place is accepted", "ChangeEntry.swift", [
        ("guard entry.device == stored.device, entry.seq == stored.seq else {", "guard true else {"),
    ]),
    ("IDs sort like Swift strings, not by their bytes", "Identifiers.swift", [
        ("lhs.rawValue.utf8.lexicographicallyPrecedes(rhs.rawValue.utf8)", "lhs.rawValue.lowercased() < rhs.rawValue.lowercased()"),
    ]),
    ("Floating-point amounts are accepted", "ChangeEntry.swift", [
        ("        } else if let value = try? container.decode(Int64.self) {\n            self = .int(value)\n",
         "        } else if let value = try? container.decode(Double.self) {\n            self = .int(Int64(value))\n"),
    ]),
]


def run_tests():
    command = ["swift", "test"]
    # On a machine that shouldn't run flat out, this also limits the builds and the test runner.
    limit = os.environ.get("PECUNIA_SIM_PARALLELISM")
    if limit:
        command += ["-j", limit, "--no-parallel"]
    try:
        result = subprocess.run(
            command, cwd=ROOT, capture_output=True, text=True, timeout=600,
        )
    except subprocess.TimeoutExpired:
        return "hung", []
    output = result.stdout + result.stderr
    if "error:" in output and "Compiling" in output and "Test run started" not in output:
        return "does not compile", [line for line in output.splitlines() if "error:" in line][:3]
    if result.returncode == 0:
        return "not caught", []
    failed = sorted(set(re.findall(r'✘ Test "([^"]+)"', output)))
    if not failed:
        return "crash", []
    return "caught", failed


def main():
    backup = pathlib.Path(tempfile.mkdtemp(prefix="pecunia-originals-"))
    for path in SRC.glob("*.swift"):
        shutil.copy2(path, backup / path.name)

    only = sys.argv[1:]
    results = []
    try:
        for name, filename, replacements in MUTANTS:
            if only and not any(text.lower() in name.lower() for text in only):
                continue
            path = SRC / filename
            original = path.read_text()
            mutated = original
            for old, new in replacements:
                if old not in mutated:
                    results.append((name, "PATTERN NOT FOUND", [old[:70]]))
                    break
                mutated = mutated.replace(old, new)
            else:
                path.write_text(mutated)
                try:
                    verdict, details = run_tests()
                finally:
                    path.write_text(original)
                results.append((name, verdict, details))
            verdict, details = results[-1][1], results[-1][2]
            print(f"{verdict:>18}  {name}", flush=True)
            for detail in details[:6]:
                print(f"{'':>20}- {detail[:110]}", flush=True)
    finally:
        for path in backup.glob("*.swift"):
            shutil.copy2(path, SRC / path.name)
        shutil.rmtree(backup)

    caught = sum(1 for _, verdict, _ in results if verdict in ("caught", "crash", "hung"))
    print(f"\n{caught} of {len(results)} deliberate bugs were caught")
    if caught != len(results):
        sys.exit(1)


main()
