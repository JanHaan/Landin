#!/bin/sh
#  The local Linux loop.
#
#  Builds the pinned linux/amd64 image and runs the ordinary build and test
#  commands inside it, against a bind mount of this repository.  The result
#  is convenience, not authority: ROADMAP.md R0.70 keeps native Linux
#  x86-64 as the gate, and this runs amd64 userspace under Rosetta.
#
#  Usage: scripts/linux-loop.sh [command ...]
#  With no command, it builds and runs the test program.

. "$(dirname -- "$0")/env.sh"

CONTAINERFILE="$LANDIN_ROOT/environments/linux-amd64/Containerfile"

#  The tag carries the Containerfile's content, so editing the recipe and
#  running again cannot silently reuse the image built from the old one.
#  A digest pin and a checksum check are worth nothing if the image they
#  describe is never rebuilt.
RECIPE_TAG="$(cksum "$CONTAINERFILE" | awk '{print $1}')"
IMAGE="${LANDIN_LINUX_IMAGE:-landin-linux-amd64:$RECIPE_TAG}"

if ! command -v container >/dev/null 2>&1; then
    echo "landin: the container command is not installed" >&2
    echo "landin: see docs/environments.md" >&2
    exit 127
fi

if [ "${LANDIN_LINUX_REBUILD:-no}" = "yes" ] \
   || ! container image inspect "$IMAGE" >/dev/null 2>&1
then
    echo "landin: building $IMAGE"
    container build \
        --platform linux/amd64 \
        --file "$CONTAINERFILE" \
        --tag "$IMAGE" \
        "$LANDIN_ROOT/environments/linux-amd64"
fi

if [ "$#" -eq 0 ]; then
    #  test.sh owns the build.  Calling build.sh here as well used to run the
    #  toolchain probe, manifest and two no-op GPRbuilds twice on every loop.
    set -- ./scripts/test.sh
fi

#  Release needs the memory, and the default does not have it.  A release
#  build is -O2 with -gnatn, so gprbuild's -j0 runs one gnat1 per core doing
#  cross-unit inlining, and in a default-sized VM the kernel kills one:
#  "gcc: fatal error: Killed signal terminated program gnat1", reported
#  against whichever unit was unlucky.  That reads like a compiler defect in
#  that file and is not one -- the same build passes natively and on the
#  x86-64 gate -- so the size is set here rather than rediscovered.
LANDIN_LINUX_MEMORY="${LANDIN_LINUX_MEMORY:-4g}"

#  LANDIN_BUILD_TAG keeps Linux object files out of the macOS ones: the
#  repository is the same directory in both, and .ali files from two hosts
#  in one object directory is a build that fails in a confusing way.
exec container run \
    --rm \
    --arch amd64 \
    --rosetta \
    --memory "$LANDIN_LINUX_MEMORY" \
    --volume "$LANDIN_ROOT:/work" \
    --workdir /work \
    --env LANDIN_BUILD_TAG=linux-amd64 \
    --env "LANDIN_BUILD_MODE=$LANDIN_BUILD_MODE" \
    "$IMAGE" \
    "$@"
