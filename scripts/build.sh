#!/bin/sh
#  Build `refine` and the test program, or only `refine` with --compiler-only.
#
#  Staleness is decided by content, not by timestamps.  The ordinary gate
#  rebuilds from clean when content changes.  scripts/dev-build.sh selects
#  GPRbuild's checksum-based minimum recompilation instead; it is feedback,
#  never a substitute for the ordinary clean debug and release gates.
#
#  Two rules from a review repair.  One build per tag and mode at a time: an OS lock
#  beside the build tree serialises concurrent runs, because two
#  gprbuilds sharing one object directory corrupted each other's archive.
#  A manifest is written only after the selected projects built, and a build tree
#  without one is a failed or interrupted build and is rebuilt from clean,
#  because gprbuild would otherwise reuse its half-written objects by
#  timestamp.

. "$(dirname -- "$0")/env.sh"

landin_build_lock mode "$@"

landin_require gprbuild
landin_require gprconfig

Compiler_Only=no
for Argument do
    shift
    case "$Argument" in
        --compiler-only) Compiler_Only=yes ;;
        *) set -- "$@" "$Argument" ;;
    esac
done

#  Both projects must consume the snapshot whose identity the manifest records.
#  A caller-supplied configuration would escape that native toolchain boundary.
for Argument do
    case "$Argument" in
        --config | --config=* | --autoconf | --autoconf=*)
            echo "landin: build.sh owns the native GPR configuration" >&2
            exit 2
            ;;
    esac
done

"$LANDIN_ROOT/scripts/toolchain.sh"

Manifest="$LANDIN_BUILD_DIR/source-manifest.txt"
Tests_Manifest="$LANDIN_BUILD_DIR/tests-manifest.txt"
Configuration="$LANDIN_ADA_DIR/.build-locks/$LANDIN_BUILD_TAG-$LANDIN_BUILD_MODE.cgpr"

#  Everything that invalidates an object: the sources and project files,
#  the compiler and builder actually on PATH, the mode and tag, and the
#  scripts that decide all of this.  A pin file names what should be on
#  PATH; the tools themselves say what is.
landin_manifest() {
    Source_Rows="$(find "$LANDIN_ADA_DIR/src" "$LANDIN_ADA_DIR/tests/src" \
         -type f \( -name '*.ad[bs]' -o -name '*.c' -o -name '*.h' \) \
         -exec cksum {} +)" || return
    printf '%s\n' "$Source_Rows" | sort || return
    Project_Rows="$(cksum "$LANDIN_ADA_DIR"/*.gpr)" || return
    printf '%s\n' "$Project_Rows" | sort || return
    Script_Rows="$(cksum "$LANDIN_ROOT/scripts/build.sh" \
        "$LANDIN_ROOT/scripts/env.sh" \
        "$LANDIN_ROOT/scripts/build_lock.py" \
        "$LANDIN_ROOT/scripts/build_config.py")" || return
    printf '%s\n' "$Script_Rows" | sort || return
    Gnat_Banner="$(gnat --version 2>/dev/null)" || return
    Gnat_First="$(printf '%s\n' "$Gnat_Banner" | sed -n '1p')" || return
    Gpr_Banner="$(gprbuild --version 2>/dev/null)" || return
    Gpr_First="$(printf '%s\n' "$Gpr_Banner" | sed -n '1p')" || return
    Configuration_Identity="$(python3 "$LANDIN_ROOT/scripts/build_config.py" \
        "$Configuration")" || return
    printf 'mode %s tag %s\n' "$LANDIN_BUILD_MODE" "$LANDIN_BUILD_TAG"
    printf 'gnat %s\n' "$Gnat_First"
    printf 'gprbuild %s\n' "$Gpr_First"
    printf '%s\n' "$Configuration_Identity"
}

#  Capture each fallible producer before a downstream command can hide its
#  status.  These functions also fail when used in a guarded substitution,
#  where POSIX shells need not apply errexit to commands inside the function.
landin_paths() {
    Paths="$(awk '$NF ~ /[.](ad[bs]|c|h|gpr|sh|py)$/ {print $NF}' <<EOF
$1
EOF
)" || return
    printf '%s\n' "$Paths" | sort
}

landin_fixed() {
    grep -E '^(mode |gnat |gprbuild |toolchain )|[.](gpr|sh|py)$' <<EOF
$1
EOF
}

Current="$(landin_manifest)" || exit
Incremental="${LANDIN_BUILD_INCREMENTAL:-no}"
Reuse="${LANDIN_BUILD_REUSE:-no}"

case "$Incremental" in
    yes | no) ;;
    *)
        echo "landin: LANDIN_BUILD_INCREMENTAL must be yes or no" >&2
        exit 2
        ;;
esac

case "$Reuse" in
    yes | no) ;;
    *)
        echo "landin: LANDIN_BUILD_REUSE must be yes or no" >&2
        exit 2
        ;;
esac

#  CI may import executables and a successful manifest from a build job in
#  this workflow run.  Verify the checkout and native toolchain identity,
#  then use those executables without asking GPRbuild to rebuild them.
if [ "$Reuse" = "yes" ]; then
    if [ "$#" -ne 1 ] || [ "$1" != "-q" ]; then
        echo "landin: LANDIN_BUILD_REUSE requires build.sh -q" >&2
        exit 2
    fi
    if [ ! -f "$Manifest" ]; then
        echo "landin: imported build has no successful source manifest" >&2
        exit 1
    fi
    Imported="$(cat "$Manifest")" || exit
    if [ "$Current" != "$Imported" ] \
       || [ ! -x "$LANDIN_BUILD_DIR/bin/refine" ] \
       || [ ! -x "$LANDIN_BUILD_DIR/bin/landin_tests" ]
    then
        echo "landin: imported build does not match this source and toolchain" >&2
        exit 1
    fi
    echo "landin: imported build matches source and toolchain"
    echo "built: $LANDIN_BUILD_DIR/bin/refine"
    exit 0
fi

if [ -d "$LANDIN_BUILD_DIR" ] && [ ! -f "$Manifest" ]; then
    echo "landin: the last build did not finish; rebuilding from clean"
    rm -rf "$LANDIN_BUILD_DIR"
fi

Previous=''
if [ -f "$Manifest" ]; then
    Previous="$(cat "$Manifest")" || exit
fi

if [ -f "$Manifest" ] && [ "$Current" != "$Previous" ]; then
    if [ "$Incremental" = "yes" ]; then
        #  The manifest is sorted by its whole checksum row, so changing a
        #  file can move its path.  Inventory equality is set equality:
        #  extract the paths and sort those independently.
        Old_Paths="$(landin_paths "$Previous")" || exit
        New_Paths="$(landin_paths "$Current")" || exit
        Old_Fixed="$(landin_fixed "$Previous")" || exit
        New_Fixed="$(landin_fixed "$Current")" || exit

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
   && [ "$Current" = "$Previous" ] \
   && [ -x "$LANDIN_BUILD_DIR/bin/refine" ] \
   && { [ "$Compiler_Only" = "yes" ] \
        || { [ -x "$LANDIN_BUILD_DIR/bin/landin_tests" ] \
             && [ -f "$Tests_Manifest" ] \
             && [ "$(cat "$Tests_Manifest")" = "$Current" ]; }; }
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
#  the manifest goes only when the selected projects built from the tree as it
#  was when this run began.  The test stamp records separately whether the
#  test executable belongs to this snapshot after a compiler-only build.
rm -f "$Manifest"

cd "$LANDIN_ADA_DIR"
gprbuild -p -P refine.gpr --config="$Configuration" "$@" || exit
if [ "$Compiler_Only" = "no" ]; then
    gprbuild -p -P landin_tests.gpr --config="$Configuration" "$@" || exit
    printf '%s\n' "$Current" > "$Tests_Manifest.tmp"
    mv -f "$Tests_Manifest.tmp" "$Tests_Manifest"
fi

Finished="$(landin_manifest)" || exit
if [ "$Finished" != "$Current" ]; then
    echo "landin: sources changed during build; leaving build unverified" >&2
    exit 1
fi

printf '%s\n' "$Current" > "$Manifest.tmp"
mv -f "$Manifest.tmp" "$Manifest"

echo "built: $LANDIN_BUILD_DIR/bin/refine"
