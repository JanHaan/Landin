#!/bin/sh
#  Remove this host's build artefacts, so the next build is a clean-checkout
#  build.  One checkout is built by more than one host, and removing another
#  host's objects from inside a container is not tidying up, it is breaking
#  somebody else's next run.
#
#  Usage: scripts/clean.sh [--all]

. "$(dirname -- "$0")/env.sh"

if [ "${1:-}" = "--all" ]; then
    landin_build_lock all "$@"
    rm -rf "$LANDIN_ADA_DIR/build"
    echo "removed: compiler/ada/build (every host)"
else
    landin_build_lock tag "$@"
    rm -rf "$LANDIN_ADA_DIR/build/$LANDIN_BUILD_TAG"
    echo "removed: compiler/ada/build/$LANDIN_BUILD_TAG"
fi
