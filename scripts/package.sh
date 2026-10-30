#!/usr/bin/env bash
#  Package an installed toolchain: refine and the library it finds beside
#  itself, in the layout `refine` looks for, as one reproducible archive.
#
#    scripts/package.sh [--debug DEBUG_ASSET] BINARY ASSET
#
#  The archive holds bin/refine, lib/landin/{core,hosted,platform} and the
#  licences, which is what a consumer receives.  It is portable across GNU
#  tar and the bsdtar macOS ships, which has no --sort, no --mtime and no
#  --owner: the members are listed in byte order, every timestamp is fixed
#  at 1980, late enough that GNU tar does not call it implausibly old,
#  and gzip -n drops the archive's own, so two runs on one host agree.
#
#  --debug takes refine's debug information out of the packaged copy and
#  writes it to DEBUG_ASSET, an archive of its own (D531): on Linux
#  refine.debug, which the stripped refine names by its .gnu_debuglink, and
#  on Darwin refine.dSYM.  The 0.2.8 compiler was 100 MB with it and 27.6
#  MB without.  The BINARY given is never changed.
set -euo pipefail

usage() {
    echo "usage: scripts/package.sh [--debug DEBUG_ASSET] BINARY ASSET" >&2
    exit 2
}

debug_asset=
if [ "${1:-}" = --debug ]; then
    [ "$#" -ge 2 ] || usage
    debug_asset=$2
    shift 2
fi
[ "$#" -eq 2 ] || usage
binary=$1
asset=$2
root=$(cd "$(dirname "$0")/.." && pwd)

test -x "$binary" || { echo "package: $binary is not an executable" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

#  Directories are members of their own, so --no-recursion keeps each
#  file to the one entry the sorted list gives it.
archive() {
    local stage=$1 into=$2
    (
        cd "$stage"
        find . -exec touch -h -t 198001010000 {} +
        find . -mindepth 1 \( -type f -o -type d \) | sed 's|^\./||' \
            | LC_ALL=C sort > "$work/members"
    )
    tar -cf - -C "$stage" --no-recursion -T "$work/members" | gzip -n -9 > "$into"
}

stage=$work/stage
mkdir -p "$stage/bin" "$stage/lib/landin"
cp "$binary" "$stage/bin/refine"
chmod 755 "$stage/bin/refine"
for namespace in core hosted platform; do
    cp -R "$root/$namespace" "$stage/lib/landin/$namespace"
done
cp "$root/LICENSE" "$root/LICENSE-MIT" "$root/LICENSE-APACHE" "$stage/"

if [ -n "$debug_asset" ]; then
    debug=$work/debug
    mkdir -p "$debug"
    if [ "$(uname -s)" = Darwin ]; then
        #  The executable holds only a map to its objects' DWARF, which
        #  dsymutil gathers while the objects are still where the link
        #  left them.
        dsymutil "$stage/bin/refine" -o "$debug/refine.dSYM"
        strip -S "$stage/bin/refine"
    else
        objcopy --only-keep-debug "$stage/bin/refine" "$debug/refine.debug"
        objcopy --strip-all --add-gnu-debuglink="$debug/refine.debug" \
            "$stage/bin/refine"
    fi
    archive "$debug" "$debug_asset"
fi

archive "$stage" "$asset"
