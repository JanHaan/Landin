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
#  without one is a failed or interrupted build.  The ordinary build rebuilds
#  that from clean, because gprbuild would otherwise reuse its half-written
#  objects by timestamp.  The developer build keeps what a failed build
#  compiled, since GPRbuild's checksum mode recompiles whatever no longer
#  matches, and after an interrupted one discards only what that build
#  wrote, any of which may be half-written.
#
#  The executables are linked into link/ and published into bin/ by a
#  rename, while no tool that holds the build's readers lock is running
#  them (scripts/build_lock.py).  Cleaning keeps bin/, so a failed or
#  interrupted rebuild leaves the last published compiler where it was.
#
#  GPRbuild decides to rebuild the library and to relink from time stamps,
#  the library's at one-second resolution, and never from contents.  After
#  each project builds, scripts/build_link.py checks that the executable
#  was linked from the objects as they are, and has GPRbuild remake the
#  library or relink when it was not.  The manifest records each executable
#  that was linked, by content, and a build that finds nothing to do still
#  requires bin/ to hold exactly those executables.

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

#  The switches that can change what GPRbuild produces, for the manifest:
#  all of the caller's but those that only say how much to print and how
#  many jobs to run.  The exec directory build.sh adds changes only where
#  the executables are linked.
Switches=''
for Argument do
    case "$Argument" in
        -q | -v | -vP* | -j* | -k) ;;
        *) Switches="${Switches:+$Switches }$Argument" ;;
    esac
done

"$LANDIN_ROOT/scripts/toolchain.sh"

Manifest="$LANDIN_BUILD_DIR/source-manifest.txt"
Tests_Manifest="$LANDIN_BUILD_DIR/tests-manifest.txt"
#  What an unfinished build was building, and whether it failed or was cut
#  short: the next run reads them to recompile only what it must.
Attempt="$LANDIN_BUILD_DIR/attempt-manifest.txt"
State="$LANDIN_BUILD_DIR/build-state"
Identity_Source="$LANDIN_BUILD_DIR/generated/landin-build_identity.ads"
Configuration="$LANDIN_ADA_DIR/.build-locks/$LANDIN_BUILD_TAG-$LANDIN_BUILD_MODE.cgpr"

python3 "$LANDIN_ROOT/scripts/build_identity.py" \
    --root "$LANDIN_ROOT" --mode "$LANDIN_BUILD_MODE" \
    --output "$Identity_Source"

#  Everything that reaches an object: the project files and the files they
#  name, the sources they find, the generated provenance unit, the switches
#  GPRbuild is given, the mode and tag, and the compiler, builder and
#  configuration actually on PATH.  The project files are where the inputs
#  are found (scripts/build_identity.py), so a new kind of input counts when
#  a project names it.  The scripts that run the build are not rows: what
#  they decide arrives through the switches, the configuration and the
#  provenance unit, and editing one alone rebuilds nothing from clean.
landin_manifest() {
    python3 "$LANDIN_ROOT/scripts/build_identity.py" \
        --root "$LANDIN_ROOT" --mode "$LANDIN_BUILD_MODE" \
        --output "$Identity_Source" --manifest || return
    Gnat_Banner="$(gnat --version 2>/dev/null)" || return
    Gnat_First="$(printf '%s\n' "$Gnat_Banner" | sed -n '1p')" || return
    Gpr_Banner="$(gprbuild --version 2>/dev/null)" || return
    Gpr_First="$(printf '%s\n' "$Gpr_Banner" | sed -n '1p')" || return
    Configuration_Identity="$(python3 "$LANDIN_ROOT/scripts/build_config.py" \
        "$Configuration")" || return
    printf 'mode %s tag %s\n' "$LANDIN_BUILD_MODE" "$LANDIN_BUILD_TAG"
    printf 'switches %s\n' "$Switches"
    printf 'gnat %s\n' "$Gnat_First"
    printf 'gprbuild %s\n' "$Gpr_First"
    printf '%s\n' "$Configuration_Identity"
}

#  Capture each fallible producer before a downstream command can hide its
#  status.  These functions also fail when used in a guarded substitution,
#  where POSIX shells need not apply errexit to commands inside the function.
landin_paths() {
    Paths="$(awk '$1 == "source" || $1 == "project" {print $3}' <<EOF
$1
EOF
)" || return
    printf '%s\n' "$Paths" | sort
}

landin_fixed() {
    grep -E '^(mode|switches|gnat|gprbuild|toolchain|project) ' <<EOF
$1
EOF
}

#  A manifest as written holds the rows of what was linked as well; what
#  the build was asked to build is the rest.
landin_requested() {
    sed '/^linked /d' "$1"
}

#  Everything in the build tree but bin/: whoever is running the published
#  compiler keeps it, and the next successful build replaces it in one step.
landin_clean_objects() {
    for Entry in "$LANDIN_BUILD_DIR"/* "$LANDIN_BUILD_DIR"/.[!.]*; do
        case "$Entry" in
            "$LANDIN_BUILD_DIR/bin") continue ;;
        esac
        if [ -e "$Entry" ] || [ -L "$Entry" ]; then
            rm -rf "$Entry"
        fi
    done
}

#  The files an interrupted build wrote after it began, any of which a
#  killed compiler or archiver may have left half-written.  The earlier
#  objects are whole, and the checksum mode decides which of them are
#  current.  Coarse timestamps can only make this remove more.
landin_discard_since() {
    python3 - "$LANDIN_BUILD_DIR" "$1" <<'EOF'
import os, sys
root, began = sys.argv[1], os.stat(sys.argv[2]).st_mtime_ns
for directory, names, files in os.walk(root):
    if directory == root:
        names[:] = [name for name in names if name != "bin"]
    for name in files:
        path = os.path.join(directory, name)
        if os.lstat(path).st_mtime_ns >= began:
            os.remove(path)
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

#  CI may import executables and successful manifests from a build job in
#  this workflow run. Verify the checkout and native toolchain identity and,
#  for a full build, the test executable's separate successful-build stamp.
#  Compiler-only consumers need only refine and its source manifest.
if [ "$Reuse" = "yes" ]; then
    if [ "$#" -ne 1 ] || [ "$1" != "-q" ]; then
        echo "landin: LANDIN_BUILD_REUSE requires build.sh -q" >&2
        exit 2
    fi
    if [ ! -f "$Manifest" ]; then
        echo "landin: imported build has no successful source manifest" >&2
        exit 1
    fi
    Imported="$(landin_requested "$Manifest")" || exit
    if [ "$Current" != "$Imported" ] \
       || [ ! -x "$LANDIN_BUILD_DIR/bin/refine" ] \
       || ! python3 "$LANDIN_ROOT/scripts/build_link.py" published \
            "$LANDIN_BUILD_DIR" "$Manifest" refine
    then
        echo "landin: imported build does not match this source and toolchain" >&2
        exit 1
    fi
    if [ "$Compiler_Only" = "no" ]; then
        if [ ! -f "$Tests_Manifest" ] \
           || [ ! -x "$LANDIN_BUILD_DIR/bin/landin_tests" ]
        then
            echo "landin: imported build has no verified test executable" >&2
            exit 1
        fi
        Imported_Tests="$(landin_requested "$Tests_Manifest")" || exit
        if [ "$Imported_Tests" != "$Current" ] \
           || ! python3 "$LANDIN_ROOT/scripts/build_link.py" published \
                "$LANDIN_BUILD_DIR" "$Tests_Manifest" landin_tests
        then
            echo "landin: imported test build does not match this source and toolchain" >&2
            exit 1
        fi
    fi
    echo "landin: imported build matches source and toolchain"
    echo "built: $LANDIN_BUILD_DIR/bin/refine"
    exit 0
fi

Previous=''
if [ -f "$Manifest" ]; then
    Previous="$(landin_requested "$Manifest")" || exit
elif [ ! -d "$LANDIN_BUILD_DIR" ]; then
    echo "landin: no earlier build of $LANDIN_BUILD_TAG/$LANDIN_BUILD_MODE; building from clean"
else
    #  No manifest: the last build did not finish.  It wrote down what it
    #  was building and whether it got as far as failing.
    Last=interrupted
    if [ -f "$State" ]; then
        Last="$(cat "$State")" || exit
    fi
    Why="it was interrupted"
    if [ "$Last" = "failed" ]; then
        Why="it failed"
    fi
    if [ "$Incremental" = "yes" ] && [ -f "$Attempt" ] && [ -f "$State" ]; then
        Previous="$(cat "$Attempt")" || exit
        if [ "$Last" = "failed" ]; then
            echo "landin: the last build did not finish ($Why); keeping what it compiled"
        else
            echo "landin: the last build did not finish ($Why); discarding only what it wrote"
            landin_discard_since "$State" || exit
        fi
    else
        echo "landin: the last build did not finish ($Why); rebuilding from clean, keeping bin/"
        landin_clean_objects
    fi
fi

if [ -n "$Previous" ] && [ "$Current" != "$Previous" ]; then
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
            echo "landin: source inventory or project changed; rebuilding from clean, keeping bin/"
            landin_clean_objects
        else
            echo "landin: source content changed; using checksum recompilation"
        fi
    else
        echo "landin: sources changed since the last build; rebuilding from clean, keeping bin/"
        landin_clean_objects
    fi
fi

#  Only quiet output and a job count leave nothing for GPRbuild to decide.
Noop_Arguments=yes
for Argument do
    case "$Argument" in
        -q | -j*) ;;
        *) Noop_Arguments=no ;;
    esac
done

if [ "$Incremental" = "yes" ] \
   && [ "$Noop_Arguments" = "yes" ] \
   && [ -f "$Manifest" ] \
   && [ "$Current" = "$Previous" ] \
   && [ -x "$LANDIN_BUILD_DIR/bin/refine" ] \
   && python3 "$LANDIN_ROOT/scripts/build_link.py" published \
        "$LANDIN_BUILD_DIR" "$Manifest" refine \
   && { [ "$Compiler_Only" = "yes" ] \
        || { [ -x "$LANDIN_BUILD_DIR/bin/landin_tests" ] \
             && [ -f "$Tests_Manifest" ] \
             && [ "$(landin_requested "$Tests_Manifest")" = "$Current" ] \
             && python3 "$LANDIN_ROOT/scripts/build_link.py" published \
                  "$LANDIN_BUILD_DIR" "$Tests_Manifest" landin_tests; }; }
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
python3 "$LANDIN_ROOT/scripts/build_identity.py" \
    --root "$LANDIN_ROOT" --mode "$LANDIN_BUILD_MODE" \
    --output "$Identity_Source"

#  An edit during the build leaves objects the manifest would not describe;
#  the manifest goes only when the selected projects built from the tree as it
#  was when this run began.  The test stamp records separately whether the
#  test executable belongs to this snapshot after a compiler-only build.
#  What this attempt builds, and that it is running, are written first: the
#  next run reads them if this one does not finish.
rm -f "$Manifest"
printf '%s\n' "$Current" > "$Attempt"
printf 'running\n' > "$State"

#  GNAT reports any short write as "disk full", whatever cut it short: a gate
#  job on a guest with 37 GiB free failed so.  Its error stream is shown as it
#  comes and kept, and when it says so the build records what space and
#  descriptor limit there actually were, so the message is not taken at its word.
landin_gprbuild() {
    Errors="$LANDIN_BUILD_DIR/gprbuild-errors.txt"
    rm -f "$Errors" "$Errors.status"
    { { gprbuild "$@" 2>&1 1>&3 3>&-
        echo "$?" > "$Errors.status"; } | tee "$Errors" >&2; } 3>&1
    Status="$(cat "$Errors.status" 2>/dev/null)" || Status=1
    if [ "$Status" = 0 ]; then
        rm -f "$Errors" "$Errors.status"
        return 0
    fi
    if grep -q 'disk full' "$Errors"; then
        Free="$(df -Pk "$LANDIN_BUILD_DIR" | awk 'NR == 2 { print int($4 / 1024) }')"
        echo "landin: GNAT says \"disk full\" for any short write;" \
             "${Free:-unknown} MiB were free under $LANDIN_BUILD_DIR" \
             "and the open-file limit is $(ulimit -n)" >&2
    fi
    return "$Status"
}

#  A build that ran to a failure leaves whole objects behind; only one that
#  was cut short leaves the state saying it was running.
landin_failed() {
    Status=$?
    printf 'failed\n' > "$State"
    exit "$Status"
}

#  Build one project, then hold its executable to what it links
#  (scripts/build_link.py): when GPRbuild left the library or the
#  executable older than the objects, they are removed and GPRbuild runs
#  once more, which must then link.  The row naming what was linked is left
#  in Linked_Row.
landin_link() {
    Link_Project="$1"
    Link_Name="$2"
    Link_Objects="$3"
    shift 3
    for Link_Round in first second; do
        Link_Before="$(python3 "$LANDIN_ROOT/scripts/build_link.py" stamp \
            "$LANDIN_BUILD_DIR" "$Link_Name")" || return
        landin_gprbuild -p -P "$Link_Project" --config="$Configuration" \
            -XLANDIN_EXEC_SUBDIR=link "$@" || return
        Link_Status=0
        Linked_Row="$(python3 "$LANDIN_ROOT/scripts/build_link.py" verify \
            "$LANDIN_BUILD_DIR" "$Link_Name" "$Link_Objects" \
            "$Link_Before")" || Link_Status=$?
        if [ "$Link_Status" != 3 ]; then
            return "$Link_Status"
        fi
    done
    echo "landin: GPRbuild did not link $Link_Name from its objects twice" >&2
    return 1
}

cd "$LANDIN_ADA_DIR"
Executables=refine
landin_link refine.gpr refine refine-obj "$@" || landin_failed
Linked_Refine="$Linked_Row"
if [ "$Compiler_Only" = "no" ]; then
    landin_link landin_tests.gpr landin_tests tests-obj "$@" || landin_failed
    Linked_Tests="$Linked_Row"
    Executables="refine landin_tests"
fi

Finished="$(landin_manifest)" || landin_failed
if [ "$Finished" != "$Current" ]; then
    printf 'failed\n' > "$State"
    printf '%s\n' "$Finished" > "$LANDIN_BUILD_DIR/finished-manifest.txt"
    echo "landin: sources changed while this build ran, so what it built is" \
         "left unverified:" >&2
    python3 "$LANDIN_ROOT/scripts/build_identity.py" --changed "$Attempt" \
        "$LANDIN_BUILD_DIR/finished-manifest.txt" | sed 's/^/landin:   /' >&2
    rm -f "$LANDIN_BUILD_DIR/finished-manifest.txt"
    echo "landin: run the build again; it recompiles only what changed" >&2
    exit 1
fi

#  shellcheck disable=SC2086 # two fixed words
python3 "$LANDIN_ROOT/scripts/build_lock.py" --publish "$LANDIN_BUILD_DIR" \
    $Executables || landin_failed
if [ "$Compiler_Only" = "no" ]; then
    printf '%s\n%s\n' "$Current" "$Linked_Tests" > "$Tests_Manifest.tmp"
    mv -f "$Tests_Manifest.tmp" "$Tests_Manifest"
fi
printf '%s\n%s\n' "$Current" "$Linked_Refine" > "$Manifest.tmp"
mv -f "$Manifest.tmp" "$Manifest"
rm -f "$State" "$Attempt"

echo "built: $LANDIN_BUILD_DIR/bin/refine"
