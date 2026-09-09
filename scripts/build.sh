#!/bin/sh
#  Build `refine` and the test program.
#
#  Staleness is decided by content, not by timestamps.  The ordinary gate
#  rebuilds from clean when content changes.  scripts/dev-build.sh selects
#  GPRbuild's checksum-based minimum recompilation instead; it is feedback,
#  never a substitute for the ordinary clean debug and release gates.
#
#  Two rules from R4.21.  One build per tag and mode at a time: a lock
#  directory beside the build tree serialises concurrent runs, because two
#  gprbuilds sharing one object directory corrupted each other's archive.
#  A manifest is written only after both projects built, and a build tree
#  without one is a failed or interrupted build and is rebuilt from clean,
#  because gprbuild would otherwise reuse its half-written objects by
#  timestamp.

. "$(dirname -- "$0")/env.sh"

landin_require gprbuild

"$LANDIN_ROOT/scripts/toolchain.sh"

Manifest="$LANDIN_BUILD_DIR/source-manifest.txt"

#  Everything that invalidates an object: the sources and project files,
#  the compiler and builder actually on PATH, the mode and tag, and the
#  scripts that decide all of this.  A pin file names what should be on
#  PATH; the tools themselves say what is.
landin_manifest() {
    find "$LANDIN_ADA_DIR/src" "$LANDIN_ADA_DIR/tests/src" \
         -type f \( -name '*.ad[bs]' -o -name '*.c' -o -name '*.h' \) \
         -exec cksum {} + | sort
    cksum "$LANDIN_ADA_DIR"/*.gpr | sort
    cksum "$LANDIN_ROOT/scripts/build.sh" "$LANDIN_ROOT/scripts/env.sh" \
        | sort
    printf 'mode %s tag %s\n' "$LANDIN_BUILD_MODE" "$LANDIN_BUILD_TAG"
    printf 'gnat %s\n' "$(gnat --version 2>/dev/null | head -n 1)"
    printf 'gprbuild %s\n' "$(gprbuild --version 2>/dev/null | head -n 1)"
}

Current="$(landin_manifest)"
Incremental="${LANDIN_BUILD_INCREMENTAL:-no}"

case "$Incremental" in
    yes | no) ;;
    *)
        echo "landin: LANDIN_BUILD_INCREMENTAL must be yes or no" >&2
        exit 2
        ;;
esac

landin_build_lock "$LANDIN_BUILD_TAG-$LANDIN_BUILD_MODE"

if [ -d "$LANDIN_BUILD_DIR" ] && [ ! -f "$Manifest" ]; then
    echo "landin: the last build did not finish; rebuilding from clean"
    rm -rf "$LANDIN_BUILD_DIR"
fi

if [ -f "$Manifest" ] && [ "$Current" != "$(cat "$Manifest")" ]; then
    if [ "$Incremental" = "yes" ]; then
        #  The manifest is sorted by its whole checksum row, so changing a
        #  file can move its path.  Inventory equality is set equality:
        #  extract the paths and sort those independently.
        Old_Paths="$(awk '$NF ~ /[.](ad[bs]|c|h|gpr|sh)$/ {print $NF}' "$Manifest" \
            | sort)"
        New_Paths="$(printf '%s\n' "$Current" \
            | awk '$NF ~ /[.](ad[bs]|c|h|gpr|sh)$/ {print $NF}' | sort)"
        Old_Fixed="$(grep -E '^(mode |gnat |gprbuild )|[.](gpr|sh)$' "$Manifest")"
        New_Fixed="$(printf '%s\n' "$Current" \
            | grep -E '^(mode |gnat |gprbuild )|[.](gpr|sh)$')"

        if [ "$Old_Paths" != "$New_Paths" ] \
           || [ "$Old_Fixed" != "$New_Fixed" ]
        then
            #  Scripts and the toolchain identity count as the project here.
            echo "landin: source inventory or project changed; rebuilding from clean"
            rm -rf "$LANDIN_BUILD_DIR"
        else
            echo "landin: source content changed; using checksum recompilation"
        fi
    else
        echo "landin: sources changed since the last build; rebuilding from clean"
        rm -rf "$LANDIN_BUILD_DIR"
    fi
fi

Noop_Arguments=no
case "$#" in
    0) Noop_Arguments=yes ;;
    1)
        if [ "$1" = "-q" ]; then
            Noop_Arguments=yes
        fi
        ;;
esac

if [ "$Incremental" = "yes" ] \
   && [ "$Noop_Arguments" = "yes" ] \
   && [ -f "$Manifest" ] \
   && [ "$Current" = "$(cat "$Manifest")" ] \
   && [ -x "$LANDIN_BUILD_DIR/bin/refine" ] \
   && [ -x "$LANDIN_BUILD_DIR/bin/landin_tests" ]
then
    echo "landin: checksum manifest unchanged; developer build is current"
    echo "built: $LANDIN_BUILD_DIR/bin/refine"
    exit 0
fi

if [ "$Incremental" = "yes" ]; then
    #  -m2 is the pinned GPRbuild's checksum-based Ada recompilation mode.
    #  It catches edit/build/revert even when mtimes would reuse the edited
    #  object.  Inventory and project changes above still force a clean tree.
    set -- -m2 "$@"
fi

mkdir -p "$LANDIN_BUILD_DIR"

#  An edit during the build leaves objects the manifest would not describe;
#  the manifest goes only when both projects built from the tree as it was
#  when this run began, and is published in one rename.
rm -f "$Manifest"

cd "$LANDIN_ADA_DIR"
gprbuild -p -P refine.gpr "$@" || exit
gprbuild -p -P landin_tests.gpr "$@" || exit

printf '%s\n' "$Current" > "$Manifest.tmp"
mv -f "$Manifest.tmp" "$Manifest"

echo "built: $LANDIN_BUILD_DIR/bin/refine"
