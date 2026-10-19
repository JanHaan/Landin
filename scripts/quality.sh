#!/bin/sh
# Measure an already-built compiler, never race a build or record a golden.
#
# usage: scripts/quality.sh [--output=DIR | --output DIR]
#
# The retained evidence, measurements.json, goes to DIR, and by default to
# the build tree's quality directory; every other file the measurement
# makes is private scratch that is removed when it ends.
. "$(dirname -- "$0")/env.sh"
Output="$LANDIN_BUILD_DIR/quality"
Expect_Output=
for Argument do
    if [ -n "$Expect_Output" ]; then
        Output="$Argument"
        Expect_Output=
        continue
    fi
    case "$Argument" in
        --output=?*) Output="${Argument#--output=}" ;;
        --output) Expect_Output=yes ;;
        --output=)
            echo "landin: quality.sh's --output names no directory" >&2
            exit 2 ;;
        -h | --help)
            echo "usage: scripts/quality.sh [--output=DIR]"
            echo "  writes measurements.json to DIR, by default $LANDIN_BUILD_DIR/quality"
            exit 0 ;;
        *)
            echo "landin: quality.sh does not take '$Argument'" >&2
            echo "landin: usage: scripts/quality.sh [--output=DIR]" >&2
            exit 2 ;;
    esac
done
if [ -n "$Expect_Output" ]; then
    echo "landin: quality.sh's --output names no directory" >&2
    echo "landin: usage: scripts/quality.sh [--output=DIR]" >&2
    exit 2
fi
landin_build_lock mode "$@"
: "${LANDIN_GNAT_HOME:?set LANDIN_GNAT_HOME to the pinned Linux installation}"
python3 "$LANDIN_ROOT/compiler/tests/quality/test_check.py"
exec python3 "$LANDIN_ROOT/compiler/tests/quality/check.py" \
    --refine "$LANDIN_BUILD_DIR/bin/refine" \
    --toolchain "$LANDIN_GNAT_HOME" \
    --output "$Output"
