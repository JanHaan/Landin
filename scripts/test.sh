#!/bin/sh
#  Run the repository's own test program.  It is run from compiler/ada so
#  that fixture discovery resolves compiler/tests the same way everywhere.
#
#  Arguments are passed through.  --record writes compiler/tests/lowering.ir,
#  compiler/tests/layout.targets and the server sessions' transcripts and runs
#  no case; --record=lowering, --record=layout, --record=server/NAME and
#  --record=CLASS/NAME each write one of them, the last a fixture's report,
#  and repeat to write several in one run.  --record-and-run does
#  both invocations after one build.  --suite, --case and --fixture, each as
#  often as wanted, select a visibly FILTERED developer run; none replaces
#  the no-argument gate.
#  --host explicitly excludes native target workload emission/execution and reports
#  HOST-ONLY scope; it can combine with --suite and --case selections.
#  --shard=I/N runs shard I of N of the complete (or --host) run; only all N
#  together are the complete run, as the gate's shard jobs are.
#  Linux routine acceptance uses host scope for its debug compiler; Darwin
#  runs both compiler hosts and selects native workloads separately.
#
#  --help prints the test program's usage and its suite names, read from its
#  source, without a build, a lock or Python.

case "${1:-}" in
    --help | -h)
        Tests_Source="$(dirname -- "$0")/../compiler/ada/tests/src/landin_tests.adb"
        Name=scripts/test.sh
        if [ "${LANDIN_BUILD_INCREMENTAL:-no}" = yes ]; then
            Name=scripts/dev-test.sh
        fi
        echo "Builds the compiler and its test program, then runs the test program"
        echo "with the options given, which are the test program's own:"
        echo
        #  Each Put_Line of Print_Usage is one line: its literals, joined.
        awk '/procedure Print_Usage is/ { on = 1; next }
             /end Print_Usage;/ { on = 0 }
             on {
                 text = $0
                 while (match(text, /"[^"]*"/)) {
                     line = line substr(text, RSTART + 1, RLENGTH - 2)
                     text = substr(text, RSTART + RLENGTH)
                 }
                 if ($0 ~ /\);/) { print line; line = "" }
             }' "$Tests_Source" | sed "s|landin_tests|$Name|g"
        echo "       $Name --record-and-run   records, then runs every case"
        echo
        #  What a suite costs is not in its name, and a brief that names
        #  one beside a new fixture did not expect half an hour.
        echo "Most suites take seconds; three take minutes on their own:"
        echo "  fixture execution  emits every positive fixture and compiles, links"
        echo "                     and runs every runtime fixture at every profile:"
        echo "                     half an hour and more on one worker, about fifteen"
        echo "                     minutes at LANDIN_TEST_JOBS=8.  --fixture=CLASS/NAME"
        echo "                     runs one fixture instead."
        echo "  parser             parses every truncation and mutation of the corpus:"
        echo "                     five to fifteen minutes, longest on a loaded host"
        echo "  memory             compiles one real program over and over to see what"
        echo "                     it keeps: about five minutes"
        echo "LANDIN_TEST_JOBS=N splits fixture execution's two corpus-wide cases"
        echo "across N workers, one by default; scripts/parallel-equivalence.sh holds"
        echo "a wider run to the same transcript.  It changes no other suite."
        echo
        echo "A no-argument invocation runs the complete local native suite."
        echo "Selections produce a FILTERED run; --host produces HOST-ONLY scope."
        echo "Suites, for --suite=NAME and --case=SUITE/NAME:"
        awk '/Expected_Suites : constant/ { on = 1 }
             on {
                 text = $0
                 while (match(text, /"[^"]*"/)) {
                     name = substr(text, RSTART + 1, RLENGTH - 2)
                     sub(/ +$/, "", name)
                     print "  " name
                     text = substr(text, RSTART + RLENGTH)
                 }
             }
             on && /];/ { exit }' "$Tests_Source"
        exit 0
        ;;
esac

. "$(dirname -- "$0")/env.sh"

landin_build_lock mode "$@"

Record_And_Run=no
if [ "$#" -eq 1 ] && [ "$1" = "--record-and-run" ]; then
    Record_And_Run=yes
    set --
fi

"$LANDIN_ROOT/scripts/build.sh" -q

#  Run from compiler/ada: every suite resolves the repository's fixture
#  trees relative to it, and LANDIN_REFINE tells the end-to-end cases which
#  executable they are meant to be checking.
cd "$LANDIN_ADA_DIR"
#  No core files under a cross runner: a trap fixture traps on purpose, and
#  QEMU's user emulation writes the core of every one it runs into this
#  directory, whatever the system does with native cores -- 388 sparse
#  files a cross run, 19 GB as read after six.  Only there: with the limit
#  on every run, the memory gate's "a gate sees retained run growth" failed
#  three gate runs of four on atki77 and in none without it.
for Argument in "$@"; do
    case "$Argument" in
        --runner=*) ulimit -c 0 ;;
    esac
done
LANDIN_REFINE="$LANDIN_BUILD_DIR/bin/refine"
export LANDIN_REFINE
landin_test_allocator_environment

if [ "$Record_And_Run" = "yes" ]; then
    "$LANDIN_BUILD_DIR/bin/landin_tests" --record
    "$LANDIN_BUILD_DIR/bin/landin_tests"
else
    "$LANDIN_BUILD_DIR/bin/landin_tests" "$@"
fi
