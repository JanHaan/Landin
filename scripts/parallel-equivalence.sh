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

echo "landin: one job..."
if [ -n "$Suite" ]; then
    LANDIN_TEST_JOBS=1 "$LANDIN_ROOT/scripts/test.sh" "$Suite" > "$Sequential" 2>&1 || true
else
    LANDIN_TEST_JOBS=1 "$LANDIN_ROOT/scripts/test.sh" > "$Sequential" 2>&1 || true
fi

echo "landin: $Jobs jobs..."
if [ -n "$Suite" ]; then
    LANDIN_TEST_JOBS="$Jobs" "$LANDIN_ROOT/scripts/test.sh" "$Suite" > "$Parallel" 2>&1 || true
else
    LANDIN_TEST_JOBS="$Jobs" "$LANDIN_ROOT/scripts/test.sh" > "$Parallel" 2>&1 || true
fi

if diff -q "$Sequential" "$Parallel" > /dev/null; then
    echo "landin: identical at 1 and $Jobs jobs"
    grep -E '^cases ' "$Sequential" || true
    exit 0
fi

echo "landin: the parallel run concluded something else" >&2
diff "$Sequential" "$Parallel" | head -40 >&2
exit 1
