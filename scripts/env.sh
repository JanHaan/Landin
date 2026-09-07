#!/bin/sh
#  Shared environment for every Landin bootstrap command.
#
#  Provider-neutral on purpose: no CI system, package manager or container
#  runtime is named here.  A host makes the pinned toolchain reachable, by
#  whatever means it has, and every command below behaves the same.
#
#  LANDIN_GNAT_HOME      directory whose bin/ holds the pinned GNAT
#  LANDIN_GPRBUILD_HOME  directory whose bin/ holds the pinned GPRbuild
#  LANDIN_BUILD_MODE     debug (default) or release
#  LANDIN_BUILD_TAG      per-host object directory (default: os-arch)
#  LANDIN_BUILD_INCREMENTAL  yes only through the developer wrappers

set -eu

landin_root() {
    CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd
}

LANDIN_ROOT="$(landin_root)"
LANDIN_ADA_DIR="$LANDIN_ROOT/compiler/ada"
LANDIN_BUILD_MODE="${LANDIN_BUILD_MODE:-debug}"
export LANDIN_BUILD_MODE

#  One checkout, more than one host: the macOS loop and the linux/amd64
#  container build the same directory.  The tag keeps their object files
#  apart, and the default names the host rather than assuming there is only
#  one.
if [ -z "${LANDIN_BUILD_TAG:-}" ]; then
    LANDIN_BUILD_TAG="$(uname -s)-$(uname -m)"
    LANDIN_BUILD_TAG="$(printf '%s' "$LANDIN_BUILD_TAG" | tr 'A-Z' 'a-z')"
fi

#  The tag is concatenated into a path, so it may not be able to leave the
#  build directory or name anything but itself.
case "$LANDIN_BUILD_TAG" in
    *[!a-z0-9._-]* | '' | .* | *..*)
        echo "landin: LANDIN_BUILD_TAG must match [a-z0-9._-]+ and not start with a dot" >&2
        echo "landin: got '$LANDIN_BUILD_TAG'" >&2
        exit 2
        ;;
esac
export LANDIN_BUILD_TAG

LANDIN_BUILD_DIR="$LANDIN_ADA_DIR/build/$LANDIN_BUILD_TAG/$LANDIN_BUILD_MODE"
export LANDIN_BUILD_DIR

if [ -n "${LANDIN_GNAT_HOME:-}" ]; then
    PATH="$LANDIN_GNAT_HOME/bin:$PATH"
fi

if [ -n "${LANDIN_GPRBUILD_HOME:-}" ]; then
    PATH="$LANDIN_GPRBUILD_HOME/bin:$PATH"
fi

export PATH

#  One build per tag and mode at a time.  mkdir is the portable atomic
#  test-and-set; the lock lives beside the build trees so removing one
#  does not remove it, and the pid inside lets a lock left by a dead
#  process be reclaimed rather than waited on forever.  Held until this
#  shell exits, so a caller that runs a build and then a test keeps it.
landin_build_lock() {
    Lock_Dir="$LANDIN_ADA_DIR/build/.lock-$1"
    mkdir -p "$LANDIN_ADA_DIR/build"
    Waited=0
    while ! mkdir "$Lock_Dir" 2>/dev/null; do
        Holder="$(cat "$Lock_Dir/pid" 2>/dev/null || true)"
        if [ -n "$Holder" ] && ! kill -0 "$Holder" 2>/dev/null; then
            echo "landin: reclaiming a build lock left by process $Holder" >&2
            rm -rf "$Lock_Dir"
            continue
        fi
        if [ "$Waited" -eq 0 ]; then
            echo "landin: waiting for another build of $1 (pid ${Holder:-unknown})" >&2
        fi
        Waited=$((Waited + 1))
        if [ "$Waited" -gt 3600 ]; then
            echo "landin: gave up waiting for the build lock $Lock_Dir" >&2
            exit 2
        fi
        sleep 1
    done
    printf '%s\n' "$$" > "$Lock_Dir/pid"
    trap 'rm -rf "$Lock_Dir"' EXIT
}

landin_require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "landin: $1 is not on PATH" >&2
        echo "landin: set LANDIN_GNAT_HOME and LANDIN_GPRBUILD_HOME, or" >&2
        echo "landin: install the toolchain pinned in compiler/ada/TOOLCHAIN.md" >&2
        exit 127
    fi
}
