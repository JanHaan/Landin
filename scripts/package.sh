#!/usr/bin/env bash
#  Package an installed toolchain: refine and the library it finds beside
#  itself, in the layout `refine` looks for, as one reproducible archive.
#
#    scripts/package.sh BINARY ASSET
#
#  The archive holds bin/refine, lib/landin/{core,hosted,platform} and the
#  licences, which is what a consumer receives.  It is portable across GNU
#  tar and the bsdtar macOS ships, which has no --sort, no --mtime and no
#  --owner: the members are listed in byte order, every timestamp is fixed
#  at 1980, late enough that GNU tar does not call it implausibly old,
#  and gzip -n drops the archive's own, so two runs on one host agree.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: scripts/package.sh BINARY ASSET" >&2
    exit 2
fi
binary=$1
asset=$2
root=$(cd "$(dirname "$0")/.." && pwd)

test -x "$binary" || { echo "package: $binary is not an executable" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage=$work/stage
mkdir -p "$stage/bin" "$stage/lib/landin"
cp "$binary" "$stage/bin/refine"
chmod 755 "$stage/bin/refine"
for namespace in core hosted platform; do
    cp -R "$root/$namespace" "$stage/lib/landin/$namespace"
done
cp "$root/LICENSE" "$root/LICENSE-MIT" "$root/LICENSE-APACHE" "$stage/"

#  Directories are members of their own, so --no-recursion keeps each
#  file to the one entry the sorted list gives it.
(
    cd "$stage"
    find . -exec touch -h -t 198001010000 {} +
    find . -mindepth 1 \( -type f -o -type d \) | sed 's|^\./||' \
        | LC_ALL=C sort > "$work/members"
)
tar -cf - -C "$stage" --no-recursion -T "$work/members" | gzip -n -9 > "$asset"
