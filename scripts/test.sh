#!/bin/sh
#  Run the repository's own test program.  It is run from compiler/ada so
#  that fixture discovery resolves compiler/tests the same way everywhere.
#
#  Arguments are passed through.  --record writes compiler/tests/lowering.ir
#  and compiler/tests/layout.targets and runs no case.  --record-and-run does
#  both invocations after one build.  --suite, --case and --fixture select a
#  visibly FILTERED developer run; none replaces the no-argument gate.

. "$(dirname -- "$0")/env.sh"

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
LANDIN_REFINE="$LANDIN_BUILD_DIR/bin/refine"
export LANDIN_REFINE

if [ "$Record_And_Run" = "yes" ]; then
    "$LANDIN_BUILD_DIR/bin/landin_tests" --record
    "$LANDIN_BUILD_DIR/bin/landin_tests"
else
    "$LANDIN_BUILD_DIR/bin/landin_tests" "$@"
fi
