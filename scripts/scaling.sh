#!/bin/sh
#  Build the release compiler and hold the frontend to its scaling bound.
#
#  scripts/scaling.py generates programs of 1,000 to 16,000 declarations,
#  checks each five times and fails a doubling whose median frontend time
#  grows more than 2.5 times.  A ratio compares two runs on one machine, so
#  the verdict does not depend on how fast that machine is.  Release mode,
#  because that is the compiler people run and the one the bound was
#  measured on; the debug build's checks make every size slower alike.
#
#  Arguments are passed to scaling.py.

LANDIN_BUILD_MODE=release
export LANDIN_BUILD_MODE

. "$(dirname -- "$0")/env.sh"

landin_build_lock mode "$@"

"$LANDIN_ROOT/scripts/build.sh" -q

exec python3 "$LANDIN_ROOT/scripts/scaling.py" \
    --refine "$LANDIN_BUILD_DIR/bin/refine" "$@"
