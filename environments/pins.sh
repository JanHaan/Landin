#!/bin/sh
#  The pinned toolchain, in one place.
#
#  compiler/ada/TOOLCHAIN.md records these for a reader; this file is what
#  the container recipe and the CI manifest use, so a version can only be
#  changed in one place.  check.py compares all three on a full run: three
#  files naming a compiler version is three chances to be wrong, and the one
#  that drifts is the one nobody reads.

LANDIN_GNAT_VERSION=16.1.0-1
LANDIN_GPRBUILD_VERSION=26.0.0-1
LANDIN_RELEASES=https://github.com/alire-project/GNAT-FSF-builds/releases/download

#  sha256 of each archive, verified before it is unpacked.
LANDIN_GNAT_SHA256_X86_64_LINUX=9f74f58a827a2ad40dd84c72a413e75ea52888e0d8f7e252fba4d26762402703
LANDIN_GPRBUILD_SHA256_X86_64_LINUX=e3f27f2515ec04d963f6badade6595993b1c091ba15d1919a7c75aad1b7ed49b
LANDIN_GNAT_SHA256_AARCH64_DARWIN=657cf254323eb91f79768918e8bd8887d6da7ac6056732a38f21e2848267da18
LANDIN_GPRBUILD_SHA256_AARCH64_DARWIN=6bf7d80c8a9702d851c5b992d7c72a07a9dbf13e8de9947b80927ea2667b6be8

#  Installs the pinned toolchain for one platform into $1, verifying each
#  archive against the checksum above before unpacking it.  A mismatch is
#  not a slower build, it is a different compiler.
landin_install_toolchain() {
    Into="$1"
    Platform="$2"        # x86_64-linux or aarch64-darwin

    case "$Platform" in
        x86_64-linux)
            Gnat_Sha="$LANDIN_GNAT_SHA256_X86_64_LINUX"
            Gpr_Sha="$LANDIN_GPRBUILD_SHA256_X86_64_LINUX"
            ;;
        aarch64-darwin)
            Gnat_Sha="$LANDIN_GNAT_SHA256_AARCH64_DARWIN"
            Gpr_Sha="$LANDIN_GPRBUILD_SHA256_AARCH64_DARWIN"
            ;;
        *)
            echo "landin: no pinned toolchain for platform '$Platform'" >&2
            return 2
            ;;
    esac

    mkdir -p "$Into"

    landin_fetch "$Into" \
        "gnat-$Platform-$LANDIN_GNAT_VERSION.tar.gz" \
        "$LANDIN_RELEASES/gnat-$LANDIN_GNAT_VERSION" \
        "$Gnat_Sha" \
        "gnat-$LANDIN_GNAT_VERSION" || return 1

    landin_fetch "$Into" \
        "gprbuild-$Platform-$LANDIN_GPRBUILD_VERSION.tar.gz" \
        "$LANDIN_RELEASES/gprbuild-$LANDIN_GPRBUILD_VERSION" \
        "$Gpr_Sha" \
        "gprbuild-$LANDIN_GPRBUILD_VERSION" || return 1
}

landin_fetch() {
    Into="$1"
    Archive="$2"
    From="$3"
    Sha="$4"
    Directory="$5"

    curl -fsSL -o "$Into/$Archive" "$From/$Archive" || return 1
    ( cd "$Into" && printf '%s  %s\n' "$Sha" "$Archive" | sha256sum -c - ) \
        || return 1

    mkdir -p "$Into/$Directory"
    tar xzf "$Into/$Archive" -C "$Into/$Directory" --strip-components=1 \
        || return 1
    rm -f "$Into/$Archive"
}
