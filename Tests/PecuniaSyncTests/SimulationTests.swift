import Foundation
import Testing
@testable import PecuniaSync

@Suite("Simulation")
struct SimulationTests {
    private static func environmentNumber(_ name: String) -> UInt64? {
        ProcessInfo.processInfo.environment[name].flatMap { UInt64($0) }
    }

    /// `PECUNIA_SIM_SEEDS` sets how many seeds to run, `PECUNIA_SIM_START` the first one,
    /// `PECUNIA_SIM_STEPS` the length of each run and `PECUNIA_SIM_SEED` replays a single seed.
    @Test("All devices converge across many seeds")
    func manySeeds() async {
        let seeds: Range<UInt64>
        if let seed = Self.environmentNumber("PECUNIA_SIM_SEED") {
            seeds = seed..<(seed + 1)
        } else {
            let start = Self.environmentNumber("PECUNIA_SIM_START") ?? 1
            seeds = start..<(start + (Self.environmentNumber("PECUNIA_SIM_SEEDS") ?? 300))
        }
        var options = Simulation.Options()
        if let steps = Self.environmentNumber("PECUNIA_SIM_STEPS") {
            options.steps = Int(steps)
        }

        let result = await Simulation.run(seeds: seeds, options: options)
        print(result.stats.summary)
        print("failures: \(result.failures.count)")
        for failure in result.failures.prefix(3) {
            Issue.record("\(failure)")
        }
        #expect(result.failures.isEmpty)
    }

    @Test("The same seed replays exactly the same run")
    func reproducible() async {
        let first = await Simulation.run(seeds: 1..<21)
        let second = await Simulation.run(seeds: 1..<21)
        #expect(first.stats.fingerprint == second.stats.fingerprint)
        #expect(first.stats.fingerprint != 0)
    }

    @Test("Different seeds give different runs")
    func seedsDiffer() async {
        let first = await Simulation.run(seeds: 1..<2)
        let second = await Simulation.run(seeds: 2..<3)
        #expect(first.stats.fingerprint != second.stats.fingerprint)
    }

    @Test("Devices also converge when the identity check can't tell a copy from the original")
    func copiesKeepingTheirID() async {
        var options = Simulation.Options()
        options.keychainMovesWithBackup = true
        let result = await Simulation.run(seeds: 1..<101, options: options)
        for failure in result.failures.prefix(1) {
            Issue.record("\(failure)")
        }
        #expect(result.failures.isEmpty)
    }
}
