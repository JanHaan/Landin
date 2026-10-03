#!/bin/sh
#  The parallel harness concludes what the sequential one concluded.
#
#  LANDIN_TEST_JOBS splits the two corpus-wide fixture cases across
#  workers.  That is allowed to change how long the suite takes and
#  nothing else: same cases, same checks, same failures, same text, same
#  order.  This runs the suite at one job and at several and requires the
#  two transcripts to be identical byte for byte.
#
#  A byte-identical transcript is necessary and not sufficient -- a race
#  that did not happen this time is still a race -- so this is a guard
#  against the change that breaks it, not a proof that none exists.  What
#  makes the split safe is structural: each worker owns its context and
#  they are absorbed in work order after every worker has finished.
#
#  Usage: scripts/parallel-equivalence.sh [--suite=NAME] [JOBS]
#
#  With no suite this runs the whole test program twice, which is slow.
#  `--suite='fixture execution'` is the one that parallelises, and is the
#  one to run after touching the harness.

set -eu

. "$(dirname -- "$0")/env.sh"

Suite=
Jobs=8
for Argument in "$@"; do
    case "$Argument" in
        --suite=*) Suite="$Argument" ;;
        *) Jobs="$Argument" ;;
    esac
done

Sequential=$(mktemp)
Parallel=$(mktemp)
trap 'rm -f "$Sequential" "$Parallel"' EXIT

run_test() {
    if [ -n "$Suite" ]; then
        LANDIN_TEST_JOBS="$1" "$LANDIN_ROOT/scripts/test.sh" "$Suite"
    else
        LANDIN_TEST_JOBS="$1" "$LANDIN_ROOT/scripts/test.sh"
    fi
}

echo "landin: one job..."
if run_test 1 > "$Sequential" 2>&1; then
    Sequential_Status=0
else
    Sequential_Status=$?
fi

echo "landin: $Jobs jobs..."
if run_test "$Jobs" > "$Parallel" 2>&1; then
    Parallel_Status=0
else
    Parallel_Status=$?
fi

#  A matching build error (or an unmatched filter) is not a harness result.
#  Check the case rows, the summary, and the harness exit status before
#  comparing transcripts.  Exit 1 is valid when cases actually failed.
valid_result() {
    awk -v Status="$2" '
        /^  pass  / { Passed_Rows++ }
        /^  FAIL  / { Failed_Rows++ }
        /^cases [0-9]+, passed [0-9]+, failed [0-9]+, checks [0-9]+$/ {
            Summaries++
            split($0, Parts, /[ ,]+/)
            Cases = Parts[2] + 0
            Passed = Parts[4] + 0
            Failed = Parts[6] + 0
        }
        END {
            if (Summaries != 1 || Cases < 1 || Passed + Failed != Cases) exit 1
            if (Passed_Rows != Passed || Failed_Rows != Failed) exit 1
            if (Failed == 0 && Status != 0) exit 1
            if (Failed > 0 && Status != 1) exit 1
        }
    ' "$1"
}

if ! valid_result "$Sequential" "$Sequential_Status"; then
    echo "landin: one-job run did not complete the selected cases (exit $Sequential_Status)" >&2
    sed -n '1,40p' "$Sequential" >&2
    exit 1
fi
if ! valid_result "$Parallel" "$Parallel_Status"; then
    echo "landin: $Jobs-job run did not complete the selected cases (exit $Parallel_Status)" >&2
    sed -n '1,40p' "$Parallel" >&2
    exit 1
fi

if [ "$Sequential_Status" -eq "$Parallel_Status" ] \
    && diff -q "$Sequential" "$Parallel" > /dev/null; then
    echo "landin: identical at 1 and $Jobs jobs"
    grep -E '^cases ' "$Sequential"
    exit 0
fi

echo "landin: the parallel run concluded something else" >&2
echo "landin: exit statuses: one job=$Sequential_Status, $Jobs jobs=$Parallel_Status" >&2
diff "$Sequential" "$Parallel" | head -40 >&2
exit 1
