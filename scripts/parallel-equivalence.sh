#!/bin/sh
#  The parallel harness concludes what the sequential one concluded.
#  Compare verdicts and diagnostics byte for byte, apart from the exact
#  progress duration field. Keep raw streams even when both runs fail.
#
#  Usage: scripts/parallel-equivalence.sh [--suite=NAME] [--output=DIR] [JOBS]
#  Jobs defaults to 8. With no suite the whole test program runs twice.
#  This guards against observed races; it cannot prove none exists.

set -eu
. "$(dirname -- "$0")/env.sh"

Suite=
Jobs=8
Evidence=
for Argument in "$@"; do
    case "$Argument" in
        --suite=*) Suite="$Argument" ;;
        --output=*) Evidence="${Argument#--output=}" ;;
        *) Jobs="$Argument" ;;
    esac
done
case "$Jobs" in
    '' | *[!0-9]* | 0)
        echo "landin: jobs must be a positive integer" >&2
        exit 2 ;;
esac

#  Use the same lock as test.sh, across the build and both executions.
#  No intervening builder can replace either executable between the runs.
landin_build_lock mode "$@"
if [ -n "$Evidence" ]; then
    mkdir "$Evidence"
else
    Evidence=$(mktemp -d "${TMPDIR:-/tmp}/landin-parallel.XXXXXXXX")
fi
Evidence=$(CDPATH='' cd -- "$Evidence" && pwd)
echo "landin: evidence: $Evidence"

#  Build chatter is not a test transcript. Build once, keeping all of it.
python3 - "$LANDIN_ROOT/scripts/build.sh" -q > "$Evidence/build.command" <<'PYCOMMAND'
import shlex
import sys
print(shlex.join(sys.argv[1:]))
PYCOMMAND
if "$LANDIN_ROOT/scripts/build.sh" -q \
    > "$Evidence/build.stdout" 2> "$Evidence/build.stderr"; then
    Build_Status=0
else
    Build_Status=$?
fi
printf '%s\n' "$Build_Status" > "$Evidence/build.status"
if [ "$Build_Status" -ne 0 ]; then
    echo "landin: build failed (exit $Build_Status); see $Evidence" >&2
    cat "$Evidence/build.stdout" "$Evidence/build.stderr" >&2
    exit 1
fi

cd "$LANDIN_ADA_DIR"
LANDIN_REFINE="$LANDIN_BUILD_DIR/bin/refine"
export LANDIN_REFINE
#  Optional detailed timing tables sort by duration, outside the stable
#  harness transcript. This property run requests only normal progress.
unset LANDIN_TEST_TIMINGS
run_test() {
    Run_Jobs="$1"
    Prefix="$Evidence/$2"
    set -- "$LANDIN_BUILD_DIR/bin/landin_tests"
    if [ -n "$Suite" ]; then
        set -- "$@" "$Suite"
    fi
    python3 - "$LANDIN_ADA_DIR" "$Run_Jobs" "$LANDIN_REFINE" "$@" \
        > "$Prefix.command" <<'PY'
import shlex
import sys
cwd, jobs, refine, *command = sys.argv[1:]
print('cd ' + shlex.quote(cwd))
print('unset LANDIN_TEST_TIMINGS')
print('LANDIN_TEST_JOBS=' + shlex.quote(jobs)
      + ' LANDIN_REFINE=' + shlex.quote(refine) + ' '
      + shlex.join(command))
PY
    if LANDIN_TEST_JOBS="$Run_Jobs" "$@" \
        > "$Prefix.stdout" 2> "$Prefix.stderr"; then
        Run_Status=0
    else
        Run_Status=$?
    fi
    printf '%s\n' "$Run_Status" > "$Prefix.status"
    #  Retain every unknown diagnostic and all progress counts/verdicts.
    #  Only the known one-decimal elapsed field may differ between jobs.
    sed -E 's/^(progress: .+: [0-9]+ cases, [0-9]+ failed, )[0-9]+\.[0-9]s$/\1<TIME>/' \
        "$Prefix.stderr" > "$Prefix.stderr.comparison"
}

echo "landin: one job..."
run_test 1 one-job
Sequential_Status="$Run_Status"
echo "landin: $Jobs jobs..."
run_test "$Jobs" many-jobs
Parallel_Status="$Run_Status"

#  A matching build error (or an unmatched filter) is not a harness result.
#  Exit 1 is valid when the completed cases actually failed.
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

Invalid=no
if ! valid_result "$Evidence/one-job.stdout" "$Sequential_Status"; then
    echo "landin: one-job run did not complete the selected cases (exit $Sequential_Status)" >&2
    Invalid=yes
fi
if ! valid_result "$Evidence/many-jobs.stdout" "$Parallel_Status"; then
    echo "landin: $Jobs-job run did not complete the selected cases (exit $Parallel_Status)" >&2
    Invalid=yes
fi
#  Always save full diffs, including for invalid runs.
Different=no
diff -u "$Evidence/one-job.stdout" "$Evidence/many-jobs.stdout" \
    > "$Evidence/stdout.diff" || Different=yes
diff -u "$Evidence/one-job.stderr.comparison" \
    "$Evidence/many-jobs.stderr.comparison" \
    > "$Evidence/stderr.diff" || Different=yes
if [ "$Invalid" = no ] && [ "$Different" = no ] \
    && [ "$Sequential_Status" -eq "$Parallel_Status" ]; then
    echo "landin: identical at 1 and $Jobs jobs"
    grep -E '^cases ' "$Evidence/one-job.stdout"
    if [ "$Sequential_Status" -ne 0 ]; then
        echo "landin: equivalence holds, but both harness runs failed:" >&2
        cat "$Evidence/one-job.stdout" >&2
    fi
    exit 0
fi

echo "landin: the parallel run did not establish equivalence; see $Evidence" >&2
echo "landin: exit statuses: one job=$Sequential_Status, $Jobs jobs=$Parallel_Status" >&2
cat "$Evidence/stdout.diff" "$Evidence/stderr.diff" >&2
if [ "$Invalid" = yes ]; then
    cat "$Evidence/one-job.stdout" "$Evidence/one-job.stderr" \
        "$Evidence/many-jobs.stdout" "$Evidence/many-jobs.stderr" >&2
fi
exit 1
