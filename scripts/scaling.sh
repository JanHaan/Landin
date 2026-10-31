#!/bin/sh
#  Build the release compiler and hold it to its scaling bound.
#
#  scripts/scaling.py generates programs of 1,000 to 16,000 declarations,
#  checks and emits each five times and fails a doubling whose median
#  frontend or emission time, or largest reported peak memory, grows more
#  than 2.5 times, at size and at speed.  A ratio compares two runs on one
#  machine, so the verdict does not depend on how fast that machine is.  It
#  does depend on how busy the machine is, so every row gives the host's
#  load, a doubling over its limit is measured again before it fails, and
#  one that misses only under contention exits 3, asking for a quieter host.
#  Release mode,
#  because that is the compiler people run and the one the bound was
#  measured on; the debug build's checks make every size slower alike.
#
#  Arguments are passed to scaling.py.  scripts/image_bounds.py then holds
#  compact static images to the same kind of bound with the host assembler.

LANDIN_BUILD_MODE=release
export LANDIN_BUILD_MODE

. "$(dirname -- "$0")/env.sh"

landin_build_lock mode "$@"

"$LANDIN_ROOT/scripts/build.sh" --compiler-only -q

python3 "$LANDIN_ROOT/scripts/scaling.py" \
    --refine "$LANDIN_BUILD_DIR/bin/refine" "$@" || exit

#  The same bound for the assembler: a few lines asking for a large static
#  image cost the assembly and the assembler the source's size (D536), and
#  one past the target's budget is refused before any tool runs (D537).
exec python3 "$LANDIN_ROOT/scripts/image_bounds.py" \
    --refine="$LANDIN_BUILD_DIR/bin/refine"
