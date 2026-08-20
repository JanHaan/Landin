#!/bin/sh
#  Run the repository's own test program.  It is run from compiler/ada so
#  that fixture discovery resolves compiler/tests the same way everywhere.

. "$(dirname -- "$0")/env.sh"

"$LANDIN_ROOT/scripts/build.sh" -q

#  Run from compiler/ada: every suite resolves the repository's fixture
#  trees relative to it, and LANDIN_REFINE tells the end-to-end cases which
#  executable they are meant to be checking.
cd "$LANDIN_ADA_DIR"
LANDIN_REFINE="$LANDIN_BUILD_DIR/bin/refine"
export LANDIN_REFINE
"$LANDIN_BUILD_DIR/bin/landin_tests"
