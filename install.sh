#!/bin/sh
#  Install Landin's compiler, refine, from a release archive.
#
#    curl -fsSL https://www.701.dev/install.sh | sh
#    curl -fsSL https://www.701.dev/install.sh | sh -s -- --version 0.2.11 --dir ~/opt/landin
#
#  It names the release archive for the host it runs on, downloads it and
#  the .sha256 published beside it, refuses an archive whose digest
#  differs, unpacks it into a directory of its own and says what to put on
#  PATH.  It asks for nothing and changes nothing outside that directory:
#  no shell profile is edited and nothing is run as root.
#
#  The archive holds bin/refine, the commands it runs from libexec/landin
#  and the standard library under lib/landin, which refine finds beside
#  itself.  The README's "Installing" names the other routes: Homebrew, a
#  container, nix and building from source.
#
#  This is the copy in the repository, https://github.com/701-dev/Landin,
#  file install.sh; the site serves it unchanged.  Read it before you pipe
#  it into a shell.
#
#  Options:
#    --version VERSION  install that release, 0.2.11 or v0.2.11; the
#                       newest release when not given
#    --dir DIR          install into DIR; $HOME/.landin when not given.  A
#                       DIR holding an earlier install is replaced; any
#                       other DIR that is not empty is refused.
#    --platform NAME    install the archive for NAME rather than for this
#                       host: x86_64-linux, aarch64-linux or aarch64-darwin
#    --list             print the archive and checksum names the release
#                       publishes for every platform, and install nothing
#    --help             print this text
#
#  LANDIN_RELEASES names where releases are read from, by default
#  https://github.com/701-dev/Landin/releases: VERSION's archive is
#  $LANDIN_RELEASES/download/vVERSION/landin-VERSION-PLATFORM.tar.gz, and
#  $LANDIN_RELEASES/latest redirects to the newest release's tag.

set -eu

releases=${LANDIN_RELEASES:-https://github.com/701-dev/Landin/releases}
repository=701-dev/Landin
platforms="x86_64-linux aarch64-linux aarch64-darwin"

say() { printf 'install.sh: %s\n' "$*"; }
refuse() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '/^#  Options:/,/^set -eu/p' "$0" | sed '$d; s/^#  \{0,1\}//'
}

other_routes() {
    cat >&2 <<EOF
install.sh: the release archives serve Linux on x86-64 and arm64, and
install.sh: macOS on Apple Silicon.  Elsewhere, install Landin
install.sh: with nix:     nix profile install github:$repository
install.sh: or build it from source, as the README's "From source" says:
install.sh:   https://github.com/$repository#from-source
EOF
}

version=
dir=
platform=
list=no
native=no
while [ "$#" -gt 0 ]; do
    case $1 in
        --version) [ "$#" -ge 2 ] || refuse "--version needs a version, such as 0.2.11"
                   version=$2; shift 2 ;;
        --version=*) version=${1#--version=}; shift ;;
        --dir) [ "$#" -ge 2 ] || refuse "--dir needs a directory"
               dir=$2; shift 2 ;;
        --dir=*) dir=${1#--dir=}; shift ;;
        --platform) [ "$#" -ge 2 ] || refuse "--platform needs one of: $platforms"
                    platform=$2; shift 2 ;;
        --platform=*) platform=${1#--platform=}; shift ;;
        --list) list=yes; shift ;;
        --help|-h)
            if [ -f "$0" ] && grep -q '^#  Options:' "$0" 2>/dev/null; then
                usage
            else
                echo "usage: install.sh [--version VERSION] [--dir DIR] [--platform NAME] [--list]"
                echo "The script's own text explains each: https://www.701.dev/install.sh"
            fi
            exit 0 ;;
        *) refuse "unknown option $1; --help lists the options" ;;
    esac
done

command -v curl > /dev/null 2>&1 \
    || refuse "curl is needed to download the release; install it and run this again"

#  The archive this host runs, by the names the release workflow publishes.
host_platform() {
    system=$(uname -s)
    reported=$(uname -m)
    machine=$reported
    case $machine in
        x86_64|amd64) machine=x86_64 ;;
        aarch64|arm64) machine=aarch64 ;;
    esac
    case "$system/$machine" in
        Linux/x86_64|Linux/aarch64) echo "$machine-linux" ;;
        Darwin/aarch64) echo aarch64-darwin ;;
        Darwin/x86_64)
            say "no release archive serves macOS on an Intel processor" >&2
            other_routes; exit 1 ;;
        *)
            say "no release archive serves $system on $reported" >&2
            other_routes; exit 1 ;;
    esac
}

if [ -n "$platform" ]; then
    case " $platforms " in
        *" $platform "*) ;;
        *) refuse "no release archive is named for $platform; the platforms are: $platforms" ;;
    esac
elif [ "$list" = no ]; then
    platform=$(host_platform)
    native=yes
fi

#  The newest release: $releases/latest redirects to .../tag/vVERSION.
version=${version#v}
if [ -z "$version" ]; then
    latest=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$releases/latest") \
        || refuse "could not reach $releases/latest to find the newest release"
    case $latest in
        */tag/v*) version=${latest##*/tag/v} ;;
        *) refuse "$releases/latest led to $latest, which names no release tag; name one with --version" ;;
    esac
fi
case $version in
    ''|*[!0-9.]*|.*|*.|*..*) refuse "$version is not a release version, such as 0.2.11" ;;
esac

if [ "$list" = yes ]; then
    for one in $platforms; do
        echo "landin-$version-$one.tar.gz"
        echo "landin-$version-$one.tar.gz.sha256"
    done
    exit 0
fi

archive="landin-$version-$platform.tar.gz"
url="$releases/download/v$version/$archive"

if [ -z "$dir" ]; then
    [ -n "${HOME:-}" ] || refuse "HOME is not set; name a directory with --dir"
    dir="$HOME/.landin"
fi
case $dir in
    /*) ;;
    *) dir="$(pwd)/$dir" ;;
esac
if [ -e "$dir" ] && [ ! -d "$dir" ]; then
    refuse "$dir is not a directory"
fi
replacing=no
if [ -d "$dir" ] && [ -n "$(ls -A "$dir")" ]; then
    if [ -x "$dir/bin/refine" ] && [ -d "$dir/lib/landin" ]; then
        replacing=yes
    else
        refuse "$dir is not empty and holds no earlier install; name another with --dir"
    fi
fi

if command -v sha256sum > /dev/null 2>&1; then
    digest() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum > /dev/null 2>&1; then
    digest() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
    refuse "sha256sum or shasum is needed to check the archive; install one and run this again"
fi

parent=$(dirname "$dir")
mkdir -p "$parent"
work=$(mktemp -d "$parent/.landin-install.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

say "downloading Landin $version for $platform"
say "  $url"
curl -fSL --progress-bar -o "$work/$archive" "$url" \
    || refuse "could not download $url; is $version a release? $releases lists them"
curl -fsSL -o "$work/$archive.sha256" "$url.sha256" \
    || refuse "could not download $url.sha256"

expected=$(cut -d' ' -f1 < "$work/$archive.sha256")
named=$(sed -n 's/^[0-9a-f]*  *\**//p' < "$work/$archive.sha256")
case $expected in
    *[!0-9a-f]*|'') refuse "$archive.sha256 holds no SHA-256 digest" ;;
esac
[ "${#expected}" -eq 64 ] || refuse "$archive.sha256 holds no SHA-256 digest"
[ "$named" = "$archive" ] || refuse "$archive.sha256 names $named, not $archive"
actual=$(digest "$work/$archive")
if [ "$actual" != "$expected" ]; then
    refuse "$archive does not match its checksum: it is $actual, and $archive.sha256 says $expected.  Nothing was installed; download it again, and if it still differs report it at https://github.com/$repository/issues"
fi
say "checksum matches $archive.sha256"

mkdir "$work/prefix"
tar -xzf "$work/$archive" -C "$work/prefix" \
    || refuse "could not unpack $archive; nothing was installed"
[ -x "$work/prefix/bin/refine" ] && [ -d "$work/prefix/lib/landin" ] \
    || refuse "$archive holds no bin/refine and lib/landin; nothing was installed"

#  A Linux archive's refine has glibc linked into it and starts on any
#  Linux, musl and NixOS ones among them.  The archives of 0.2.11 and
#  earlier did not: they ask for glibc 2.38 or later and its loader at the
#  standard path.  An archive for this host whose refine does not start
#  here is refused rather than installed.
if [ "$native" = yes ]; then
    if ! started=$("$work/prefix/bin/refine" version 2>&1); then
        say "refine $version from $archive does not start on this host; nothing was installed." >&2
        printf '%s\n' "$started" | sed -n '1,3s/^/install.sh:   /p' >&2
        case $platform in
            *-linux)
                say "The Linux archives of 0.2.11 and earlier need glibc 2.38 or later and its loader;" >&2
                say "a later release's archive starts on any Linux." >&2 ;;
        esac
        other_routes; exit 1
    fi
fi

#  The new install is complete before the old one is moved aside, so an
#  interrupted run leaves one or the other.
if [ "$replacing" = yes ]; then
    mv "$dir" "$work/earlier"
elif [ -d "$dir" ]; then
    rmdir "$dir"
fi
mv "$work/prefix" "$dir"
say "installed refine $version in $dir"

if command -v gh > /dev/null 2>&1; then
    cat <<EOF
install.sh: The checksum says the archive arrived whole, not who built it.
install.sh: With the GitHub CLI you can check that the release workflow did:
  gh release download v$version --repo $repository --pattern $archive
  gh attestation verify $archive --repo $repository \\
    --signer-workflow $repository/.github/workflows/release.yml \\
    --source-ref refs/tags/v$version --deny-self-hosted-runners
EOF
fi

case ":${PATH:-}:" in
    *":$dir/bin:"*)
        say "$dir/bin is on your PATH already; run: refine version" ;;
    *)
        cat <<EOF
install.sh: To run refine, put $dir/bin on your PATH.  For this shell:
  export PATH="$dir/bin:\$PATH"
install.sh: and add that line to your shell's startup file, such as
install.sh: ~/.profile, ~/.bashrc or ~/.zshrc, for the next ones.
install.sh: Then run: refine version
EOF
        ;;
esac
case $platform in
    *-linux) say "refine run links with the system's GCC driver, gcc; install it if you have none." ;;
    *-darwin) say "refine run links with Xcode's command-line tools: xcode-select --install" ;;
esac
