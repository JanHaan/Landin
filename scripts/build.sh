#!/bin/sh
#  Build `refine` and the test program.
#
#  Staleness is decided by content, not by timestamps.  A source that is
#  edited and reverted keeps a newer mtime than the object built from it, so
#  gprbuild would happily serve objects that no longer match the tree; that
#  really happened, and the suite reported on a binary nobody had built.

. "$(dirname -- "$0")/env.sh"

landin_require gprbuild

"$LANDIN_ROOT/scripts/toolchain.sh"

Manifest="$LANDIN_BUILD_DIR/source-manifest.txt"

landin_manifest() {
    find "$LANDIN_ADA_DIR/src" "$LANDIN_ADA_DIR/tests/src" \
         -type f -name '*.ad[bs]' -exec cksum {} + | sort
    cksum "$LANDIN_ADA_DIR"/*.gpr | sort
}

Current="$(landin_manifest)"

if [ -f "$Manifest" ] && [ "$Current" != "$(cat "$Manifest")" ]; then
    echo "landin: sources changed since the last build; rebuilding from clean"
    rm -rf "$LANDIN_BUILD_DIR"
fi

mkdir -p "$LANDIN_BUILD_DIR"

cd "$LANDIN_ADA_DIR"
gprbuild -p -P refine.gpr "$@"
gprbuild -p -P landin_tests.gpr "$@"

printf '%s\n' "$Current" > "$Manifest"

echo "built: $LANDIN_BUILD_DIR/bin/refine"
