#!/bin/sh
#  Build `refine` and the test program.
#
#  Staleness is decided by content, not by timestamps.  The ordinary gate
#  rebuilds from clean when content changes.  scripts/dev-build.sh selects
#  GPRbuild's checksum-based minimum recompilation instead; it is feedback,
#  never a substitute for the ordinary clean debug and release gates.

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
Incremental="${LANDIN_BUILD_INCREMENTAL:-no}"

case "$Incremental" in
    yes | no) ;;
    *)
        echo "landin: LANDIN_BUILD_INCREMENTAL must be yes or no" >&2
        exit 2
        ;;
esac

if [ -f "$Manifest" ] && [ "$Current" != "$(cat "$Manifest")" ]; then
    if [ "$Incremental" = "yes" ]; then
        #  The manifest is sorted by its whole checksum row, so changing a
        #  file can move its path.  Inventory equality is set equality:
        #  extract the paths and sort those independently.
        Old_Paths="$(awk '{print $NF}' "$Manifest" | sort)"
        New_Paths="$(printf '%s\n' "$Current" \
            | awk '{print $NF}' | sort)"
        Old_Projects="$(awk '$NF ~ /[.]gpr$/ {print}' "$Manifest")"
        New_Projects="$(printf '%s\n' "$Current" \
            | awk '$NF ~ /[.]gpr$/ {print}')"

        if [ "$Old_Paths" != "$New_Paths" ] \
           || [ "$Old_Projects" != "$New_Projects" ]
        then
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

cd "$LANDIN_ADA_DIR"
gprbuild -p -P refine.gpr "$@"
gprbuild -p -P landin_tests.gpr "$@"

printf '%s\n' "$Current" > "$Manifest"

echo "built: $LANDIN_BUILD_DIR/bin/refine"
