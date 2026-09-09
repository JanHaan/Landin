#!/bin/sh
# Measure an already-built compiler, never race a build or record a golden.
. "$(dirname -- "$0")/env.sh"
: "${LANDIN_GNAT_HOME:?set LANDIN_GNAT_HOME to the pinned Linux installation}"
exec python3 "$LANDIN_ROOT/compiler/tests/quality/check.py" \
    --refine "$LANDIN_BUILD_DIR/bin/refine" \
    --toolchain "$LANDIN_GNAT_HOME" \
    --output "$LANDIN_BUILD_DIR/quality"
