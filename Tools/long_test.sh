#!/usr/bin/env bash
#
# Runs the long version of the sync tests: many seeds, long histories and the mutation test.
# It works the CPU hard for a while, so it's best on a machine with a fan. To go easy on one
# without, limit the number of cores:
#
#     PECUNIA_SIM_PARALLELISM=2 Tools/long_test.sh
#
# The first stage prints a fingerprint of what happened. It should be the same on every machine.

cd "$(dirname "$0")/.." || exit 1

failed=0

simulate() {
    local title=$1 seeds=$2 steps=$3 start=$4
    local began=$SECONDS
    echo "=== $title ==="
    PECUNIA_SIM_SEEDS=$seeds PECUNIA_SIM_STEPS=$steps PECUNIA_SIM_START=$start \
        swift test -c release -Xswiftc -enable-testing --filter 'SimulationTests/manySeeds' 2>&1 \
        | grep -E '^(seeds|syncs|devices restored|server restores|clocks|split logs|writes during|fingerprint|failures):|✘|Simulation failed|error:'
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        failed=1
    fi
    echo "took $(((SECONDS - began) / 60)) minutes"
    echo
}

simulate "300 seeds, to compare between machines" 300 300 5000
simulate "100,000 seeds of 300 steps" 100000 300 100000
simulate "2,000 seeds of 3,000 steps" 2000 3000 900000

echo "=== mutation test ==="
began=$SECONDS
if ! python3 Tools/mutation_test.py; then
    failed=1
fi
echo "took $(((SECONDS - began) / 60)) minutes"
echo

if [ "$failed" -eq 0 ]; then
    echo "RESULT: everything passed"
else
    echo "RESULT: something failed, see above"
fi
exit "$failed"
