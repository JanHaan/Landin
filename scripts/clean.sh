#!/bin/sh
#  Remove this host's build artefacts, so the next build is a clean-checkout
#  build.  One checkout is built by more than one host, and removing another
#  host's objects from inside a container is not tidying up, it is breaking
#  somebody else's next run.
#
#  Usage: scripts/clean.sh [--all]

. "$(dirname -- "$0")/env.sh"

if [ "${1:-}" = "--all" ]; then
    rm -rf "$LANDIN_ADA_DIR/build"
    echo "removed: compiler/ada/build (every host)"
else
    #  Both modes of this tag go, so both locks are taken first: a build
    #  in flight in either would otherwise lose its objects underneath it.
    landin_build_lock "$LANDIN_BUILD_TAG-debug"
    Debug_Lock="$Lock_Dir"
    landin_build_lock "$LANDIN_BUILD_TAG-release"
    trap 'rm -rf "$Debug_Lock" "$Lock_Dir"' EXIT
    rm -rf "$LANDIN_ADA_DIR/build/$LANDIN_BUILD_TAG"
    echo "removed: compiler/ada/build/$LANDIN_BUILD_TAG"
fi
