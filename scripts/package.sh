#!/usr/bin/env bash
#  Package an installed toolchain: refine and the library it finds beside
#  itself, in the layout `refine` looks for, as one reproducible archive.
#
#    scripts/package.sh [--debug DEBUG_ASSET] BINARY ASSET
#
#  The archive holds bin/refine, libexec/landin/refine-NAME for each split
#  command compiler/ada/split-commands.json lists (the directory even when
#  it lists none), lib/landin/{core,hosted,platform}, the
#  lib/landin/citations.txt `refine explain` reads a construct or a
#  decision from (D1240), and the licences, which is what a consumer
#  receives.  Each split command is taken from where the build published
#  it beside BINARY, BINARY's ../libexec/landin/refine-NAME, and one that
#  is missing there is refused: the dispatcher and its splits ship in
#  lockstep or not at all.  It is portable across GNU
#  tar and the bsdtar macOS ships, which has no --sort, no --mtime and no
#  --owner: the members are listed in byte order, every timestamp is fixed
#  at 1980, late enough that GNU tar does not call it implausibly old,
#  every member is root's with a mode set here, and gzip -n drops the
#  archive's own, so two runs on one host agree whoever runs them and
#  under whatever umask.
#
#  --debug takes refine's debug information out of the packaged copy and
#  writes it to DEBUG_ASSET, an archive of its own (D531): on Linux
#  refine.debug, which the stripped refine names by its .gnu_debuglink, and
#  on Darwin refine.dSYM; each split command's likewise, as
#  refine-NAME.debug or refine-NAME.dSYM.  The 0.2.8 compiler was 100 MB
#  with it and 27.6 MB without.  The BINARY given is never changed.
#
#  A Linux ELF BINARY that requests no program interpreter has glibc linked
#  into it, as a release build does (compiler/ada/landin_common.gpr), and
#  glibc is under the LGPL, version 2.1 or later.  Such an archive also
#  holds LICENSE-GLIBC, the copyright file of the Debian package whose
#  libc.a was linked, and NOTICE-GLIBC, which names that glibc, where its
#  source is and how to relink refine against a modified one.  Both are
#  read from the libc6-dev package of the host that packages, which must be
#  the host that built BINARY, a Debian or Ubuntu one as the release
#  workflow's runners are; on any other host such a BINARY is refused.
#
#  The archive is whatever BINARY is.  One that requests a program
#  interpreter outside the system's own directories, as a compiler built in
#  `nix develop` does, is packaged with a warning that names the path: the
#  archive starts only where that path exists.  An archive for others is
#  packaged from a compiler built with the pinned toolchain outside nix
#  (the README, "From source"), as the release workflow's is.
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

#  The split commands, by the one list, and each one's built executable.
command -v python3 > /dev/null || {
    echo "package: python3 is needed to read compiler/ada/split-commands.json" >&2
    exit 2
}
splits=$(python3 "$root/scripts/build_identity.py" --root "$root" \
    --split-commands | cut -d' ' -f1)
libexec=$(dirname "$binary")/../libexec/landin
for name in $splits; do
    test -x "$libexec/refine-$name" || {
        echo "package: compiler/ada/split-commands.json lists $name, and" \
            "$libexec/refine-$name is not an executable; scripts/build.sh" \
            "publishes it beside bin/refine" >&2
        exit 1
    }
done

#  The debug information is split by the host's objcopy, and the archive
#  is named for the host, so an ELF executable of another architecture is
#  refused here rather than failing inside objcopy.  A Mach-O one is
#  packaged on the Darwin host it was built for.
if [ "$(uname -s)" = Linux ]; then
    built_for=$(python3 - "$binary" <<'EOF'
import struct, sys
data = open(sys.argv[1], "rb").read(20)
machines = {62: "x86_64", 183: "aarch64", 243: "riscv64"}
if data[:4] == b"\x7fELF" and len(data) == 20:
    order = "<" if data[5] == 1 else ">"
    number, = struct.unpack_from(order + "H", data, 18)
    print(machines.get(number, "ELF machine %d" % number))
EOF
)
    host_machine=$(uname -m)
    if [ -n "$built_for" ] && [ "$built_for" != "$host_machine" ]; then
        echo "package: $binary is built for $built_for, and this host is" \
            "$host_machine; package.sh packages the host's own executables," \
            "with the host's objcopy.  Package it on that architecture's host, or" \
            "in that architecture's development shell, such as nix develop" \
            "'.#devShells.$built_for-linux.default' under emulation." >&2
        exit 1
    fi
fi

static=no
if command -v python3 > /dev/null; then
    inspected=0
    loader=$(python3 "$root/scripts/program_interpreter.py" "$binary") \
        || inspected=$?
    if [ "$inspected" = 3 ]; then
        cat >&2 <<EOF
package: warning: $binary requests the program interpreter
package:   $loader
package: which is not a system path. The archive will start only on a machine
package: that has that path; on any other the shell says "cannot execute:
package: required file not found". A compiler built in nix develop is linked
package: this way. For an archive that starts elsewhere, package a compiler
package: built with the pinned toolchain outside nix, as the README's "From
package: source" builds it and the release workflow does.
EOF
    elif [ "$inspected" != 0 ]; then
        exit "$inspected"
    elif [ -z "$loader" ] && [ -n "${built_for:-}" ]; then
        static=yes
    fi
else
    echo "package: python3 is not on PATH, so the program interpreter" \
         "$binary requests was not inspected" >&2
fi

#  The glibc a static BINARY holds: the libc6-dev package that supplied
#  libc.a, its source package and the distribution it came from.
if [ "$static" = yes ]; then
    glibc_refused() {
        echo "package: $binary has glibc linked into it, and its archive" \
            "must carry glibc's licence and name the glibc it holds;" \
            "$1.  Package it on the Debian or Ubuntu host that built it," \
            "as the release workflow does." >&2
        exit 1
    }
    command -v dpkg-query > /dev/null \
        || glibc_refused "this host has no dpkg-query to say which glibc that is"
    glibc_package=$(dpkg-query -W \
        -f='${Package} ${Version} ${source:Package} ${source:Version}' \
        libc6-dev 2>/dev/null) \
        || glibc_refused "this host has no libc6-dev package, which supplies libc.a"
    glibc_copyright=$(dpkg-query -L libc6-dev 2>/dev/null \
        | grep '/copyright$' | head -1) || true
    [ -n "$glibc_copyright" ] && [ -f "$glibc_copyright" ] \
        || glibc_refused "libc6-dev lists no copyright file on this host"
    glibc_distribution=unknown
    if [ -f /etc/os-release ]; then
        glibc_distribution=$(. /etc/os-release \
            && printf '%s' "${PRETTY_NAME:-${NAME:-unknown}}")
    fi
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

#  Every member belongs to root, by number and with no name.  tar restores
#  recorded ownership when root unpacks, so an archive that recorded the
#  packaging account, a CI runner's uid 1001 or 501, gave the compiler and
#  its library to whichever local account has that number on a machine
#  where an administrator installed it.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    owner=(--owner=0 --group=0 --numeric-owner)
else
    owner=(--uid 0 --gid 0 --uname '' --gname '')
fi

#  Directories are members of their own, so --no-recursion keeps each
#  file to the one entry the sorted list gives it.  Modes are set here and
#  not inherited from the packaging account's umask: a directory and a
#  file its owner may execute are 755, any other file 644.
archive() {
    local stage=$1 into=$2
    (
        cd "$stage"
        find . -type d -exec chmod 755 {} +
        find . -type f -perm -u+x -exec chmod 755 {} +
        find . -type f ! -perm -u+x -exec chmod 644 {} +
        find . -exec touch -h -t 198001010000 {} +
        find . -mindepth 1 \( -type f -o -type d \) | sed 's|^\./||' \
            | LC_ALL=C sort > "$work/members"
    )
    tar -cf - "${owner[@]}" -C "$stage" --no-recursion -T "$work/members" \
        | gzip -n -9 > "$into"
}

stage=$work/stage
mkdir -p "$stage/bin" "$stage/libexec/landin" "$stage/lib/landin"
cp "$binary" "$stage/bin/refine"
chmod 755 "$stage/bin/refine"
#  The packaged executables, by their path in the archive.
executables=bin/refine
for name in $splits; do
    cp "$libexec/refine-$name" "$stage/libexec/landin/refine-$name"
    chmod 755 "$stage/libexec/landin/refine-$name"
    executables="$executables libexec/landin/refine-$name"
done
for namespace in core hosted platform; do
    cp -R "$root/$namespace" "$stage/lib/landin/$namespace"
done
#  D1240: the citations ship in the library, and an archive without them
#  is not one to publish: its `refine explain D275` could only say which
#  file it looked for.
if [ ! -f "$root/citations.txt" ]; then
    echo "package: $root/citations.txt is missing;" \
        "python3 check.py --catalogue writes it" >&2
    exit 2
fi
cp "$root/citations.txt" "$stage/lib/landin/citations.txt"
cp "$root/LICENSE" "$root/LICENSE-MIT" "$root/LICENSE-APACHE" "$stage/"
if [ "$static" = yes ]; then
    read -r package version source source_version <<EOF
$glibc_package
EOF
    cp "$glibc_copyright" "$stage/LICENSE-GLIBC"
    cat > "$stage/NOTICE-GLIBC" <<EOF
The executables in this archive, bin/refine and libexec/landin/refine-*,
are linked statically with the GNU C Library, glibc: the libc.a of the
package $package $version of $glibc_distribution, built from its
source package $source $source_version.

glibc is free software, licensed under the GNU Lesser General Public
License, version 2.1 or later.  LICENSE-GLIBC is that package's copyright
file, which holds the licence and the copyright notices of glibc's parts.

glibc's source is the source package $source $source_version, in the
archive of $glibc_distribution; on that system,
apt-get source $source=$source_version fetches it.

To relink refine with a modified glibc: refine's complete source is
public, under the MIT or Apache-2.0 licence, at
https://github.com/701-dev/Landin, a release at its tag.  Build it as
its README's "From source" says, with LANDIN_BUILD_MODE=release and the
modified libc.a where the C compiler finds its own.
EOF
fi

if [ -n "$debug_asset" ]; then
    debug=$work/debug
    mkdir -p "$debug"
    for executable in $executables; do
        name=$(basename "$executable")
        if [ "$(uname -s)" = Darwin ]; then
            #  The executable holds only a map to its objects' DWARF, which
            #  dsymutil gathers while the objects are still where the link
            #  left them.
            dsymutil "$stage/$executable" -o "$debug/$name.dSYM"
            strip -S "$stage/$executable"
        else
            objcopy --only-keep-debug "$stage/$executable" "$debug/$name.debug"
            objcopy --strip-all --add-gnu-debuglink="$debug/$name.debug" \
                "$stage/$executable"
        fi
    done
    archive "$debug" "$debug_asset"
fi

archive "$stage" "$asset"
