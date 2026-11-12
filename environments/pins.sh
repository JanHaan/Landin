#!/bin/sh
#  The pinned toolchain, in one place.
#
#  compiler/ada/TOOLCHAIN.md records these for a reader; this file is what
#  the container recipe, native acceptance and the nix shell use, so a version
#  can only be changed in one place.  check.py compares them all on a full
#  run -- including that flake.nix reads this file rather than naming a
#  version of its own: every file naming a compiler version is another
#  chance to be wrong, and the one that drifts is the one nobody reads.

LANDIN_GNAT_VERSION=16.1.0-1
LANDIN_GPRBUILD_VERSION=26.0.0-1
LANDIN_RELEASES=https://github.com/alire-project/GNAT-FSF-builds/releases/download
#  The container recipe's Debian 13 (trixie-20260824) base image, by its
#  multi-platform index digest, which aligns its clang-19/libc6-dev package set
#  with the native Debian stable gate.  check.py holds the recipe to it.
#  Nothing else reads it.
LANDIN_BASE_IMAGE=docker.io/library/debian@sha256:f324c7ff54321e8d9c588493a20244965938ce0aa50bbd1022d38010e9ffc4b1

#  The gate's other tools.  The C binding generator's Clang is Ubuntu 24.04's
#  clang-19 package at this exact version, installed and asserted by the
#  bindings job; compiler/ada/TOOLCHAIN.md records it.  The structural editor
#  grammar's CLI is the release binary tree-sitter publishes for this version,
#  checked against this sha256 before it replaces the npm package's
#  unverified download; highlight/tree-sitter/package.json names the same
#  version.  check.py holds all three to agreeing.  The nix shell fetches
#  the same release binary for its own system, held to the same checksums.
LANDIN_CLANG_UBUNTU=1:19.1.1-1ubuntu1~24.04.2
LANDIN_TREE_SITTER_VERSION=0.26.9
LANDIN_TREE_SITTER_SHA256_X86_64_LINUX=9ce82137caa65864e7ca8b869fd391cef88c9bd2a01c4371b9c4dd26c2585efb
LANDIN_TREE_SITTER_SHA256_AARCH64_LINUX=c8feeb32115958cb44442ca4d68f6d66cf7605dbd65681e62342181ebdd6db3b
LANDIN_TREE_SITTER_SHA256_AARCH64_DARWIN=e46725b2417c085b0761948abc0cc240bff6a3ab5d2128e3ad0de467ded3388d

#  The workflows' linter: the release binary actionlint publishes for this
#  version, checked against this sha256 before it runs.  The gate's scripts
#  job fetches the Linux x86-64 one through scripts/actionlint.py, which
#  refuses an actionlint of another version, and the nix shell fetches its
#  own system's.  .github/actionlint.yaml names the runner labels GitHub
#  does not host.  check.py holds compiler/ada/TOOLCHAIN.md and flake.nix
#  to these.
LANDIN_ACTIONLINT_VERSION=1.7.12
LANDIN_ACTIONLINT_RELEASES=https://github.com/rhysd/actionlint/releases/download
LANDIN_ACTIONLINT_SHA256_X86_64_LINUX=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
LANDIN_ACTIONLINT_SHA256_AARCH64_LINUX=325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
LANDIN_ACTIONLINT_SHA256_AARCH64_DARWIN=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f

#  The shell linter actionlint runs over every workflow's `run:` scripts:
#  the release binary shellcheck publishes for this version, checked
#  against this sha256 before it runs.  The release publishes no checksum
#  file; these were taken from the archives fetched from its release page.
#  scripts/actionlint.py fetches the Linux x86-64 one beside actionlint
#  and names it to actionlint by its path, refusing a shellcheck of
#  another version, and the nix shell fetches its own system's.  check.py
#  holds compiler/ada/TOOLCHAIN.md and flake.nix to these.
LANDIN_SHELLCHECK_VERSION=0.11.0
LANDIN_SHELLCHECK_RELEASES=https://github.com/koalaman/shellcheck/releases/download
LANDIN_SHELLCHECK_SHA256_X86_64_LINUX=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
LANDIN_SHELLCHECK_SHA256_AARCH64_LINUX=12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
LANDIN_SHELLCHECK_SHA256_AARCH64_DARWIN=56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79

#  The cross lane: QEMU's user emulation and the cross drivers that link
#  another Linux target's executables.  The nix shell takes both from
#  flake.lock's nixpkgs and refuses to build when that revision's versions
#  are not these, so moving the lock moves these on purpose.  The gate's
#  linux-rv64 lane runs the same QEMU, the flake's qemu-user, and refuses
#  another; it links with Ubuntu 24.04's riscv64 cross packages, whose
#  version is not this GCC and which it prints.  check.py holds flake.nix
#  to reading these.
LANDIN_CROSS_QEMU_NIX=11.1.0
LANDIN_CROSS_GCC_NIX=15.3.0

#  The Cortex-M lane's GCC and binutils: GNAT's arm-elf archive from
#  the release the host GNAT comes from, whose driver is `arm-eabi-gcc`.
#  environments/cortex-m/setup.py installs the Linux x86-64 one and the nix
#  shell its own system's; QEMU and the GDB whose Python the debugger
#  sessions run stay in environments/cortex-m/tools.lock.json.
LANDIN_GNAT_ARM_ELF_VERSION=16.1.0-1

#  The RV32 lanes' GCC and binutils: GNAT's riscv64-elf archive from the
#  same release, whose driver is `riscv64-elf-gcc` and whose multilibs
#  hold rv32imc and rv32imac with the ilp32 ABI (D660).  The nix shell
#  fetches its own system's; the RV32 lane installs the Linux x86-64 one.
LANDIN_GNAT_RISCV64_ELF_VERSION=16.1.0-1

#  Espressif's configured Xtensa compiler and binutils. The chip wrappers
#  select distinct ISA plugins and matching windowed-ABI multilibs.
LANDIN_XTENSA_ESP_ELF_VERSION=16.1.0_20260609
LANDIN_XTENSA_ESP_ELF_RELEASE=esp-16.1.0_20260609
LANDIN_XTENSA_ESP_ELF_RELEASES=https://github.com/espressif/crosstool-NG/releases/download
LANDIN_XTENSA_ESP_ELF_SHA256_X86_64_LINUX=f708752ebb35cab21f184b2574114ed1187619db0edb8a4ba913c06ca2fa675e
LANDIN_XTENSA_ESP_ELF_SHA256_AARCH64_LINUX=785ee242bfbdb3ac4e764e85d2f87109c7c5f3da57d742da9a7c58c0d0906149
LANDIN_XTENSA_ESP_ELF_SHA256_AARCH64_DARWIN=be4eb81c12c9bbf6ead79c758bfa81b8e6ec9a695372f946ac924c70c32f273d

#  sha256 of each archive, verified before it is unpacked.
LANDIN_GNAT_SHA256_X86_64_LINUX=9f74f58a827a2ad40dd84c72a413e75ea52888e0d8f7e252fba4d26762402703
LANDIN_GPRBUILD_SHA256_X86_64_LINUX=e3f27f2515ec04d963f6badade6595993b1c091ba15d1919a7c75aad1b7ed49b
LANDIN_GNAT_SHA256_AARCH64_DARWIN=657cf254323eb91f79768918e8bd8887d6da7ac6056732a38f21e2848267da18
LANDIN_GPRBUILD_SHA256_AARCH64_DARWIN=6bf7d80c8a9702d851c5b992d7c72a07a9dbf13e8de9947b80927ea2667b6be8
LANDIN_GNAT_SHA256_AARCH64_LINUX=8e297497f2d6d6845920a363a277b6ef5bc454e48a66d0d606b89d71e31ee623
LANDIN_GPRBUILD_SHA256_AARCH64_LINUX=c125424447144944973d24de43a53b3e7008dbda306e0d540db07e635dea24e4
LANDIN_GNAT_ARM_ELF_SHA256_X86_64_LINUX=9e6bb6696de1b84e26a3fbeebd67d5e7c9aad28a6bdee4cb8e59328b6fd99078
LANDIN_GNAT_ARM_ELF_SHA256_AARCH64_LINUX=6f09f8efe4f36cc4a8c1f9da1c554bca043722fd11bb8475dbe100f03543b2a3
LANDIN_GNAT_ARM_ELF_SHA256_AARCH64_DARWIN=10fc8bc6b6a67def53c2497e21b06289bfadf845a609f6a3679cad06c8bbf5d4
LANDIN_GNAT_RISCV64_ELF_SHA256_X86_64_LINUX=01cb5e97d6b51ed21f677912bc09bd6caca430515d09c8feda171c17b4fa95db
LANDIN_GNAT_RISCV64_ELF_SHA256_AARCH64_LINUX=e08cbbf929ffcb9ca931ad41d7fd6d9a95a2ab46ad2830daf9e3a4ea11104a32
LANDIN_GNAT_RISCV64_ELF_SHA256_AARCH64_DARWIN=c4b76df21e1518b9b3ba9a34a515ef951f8a1a333640df2d5f2382e5c23d6df3

#  Installs the pinned toolchain for one platform into $1, verifying each
#  archive against the checksum above before unpacking it.  A mismatch is
#  not a slower build, it is a different compiler.
landin_install_toolchain() {
    Into="$1"
    Platform="$2"        # x86_64-linux, aarch64-linux or aarch64-darwin

    case "$Platform" in
        x86_64-linux)
            Gnat_Sha="$LANDIN_GNAT_SHA256_X86_64_LINUX"
            Gpr_Sha="$LANDIN_GPRBUILD_SHA256_X86_64_LINUX"
            ;;
        aarch64-linux)
            Gnat_Sha="$LANDIN_GNAT_SHA256_AARCH64_LINUX"
            Gpr_Sha="$LANDIN_GPRBUILD_SHA256_AARCH64_LINUX"
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

    #  curl asks again, a bounded number of times, only where the server
    #  said to wait (408, 429, 500, 502, 503, 504) or the connection
    #  failed; a 404 ends at once.  A failure names the archive, its URL
    #  and the status, so an upstream outage is told from a broken pin.
    Status=$(curl -fsSL --retry "${LANDIN_FETCH_RETRIES:-3}" \
        --retry-delay "${LANDIN_FETCH_RETRY_DELAY:-2}" -w '%{http_code}' \
        -o "$Into/$Archive" "$From/$Archive") || {
        echo "landin_fetch: $Archive: cannot fetch $From/$Archive:" \
            "HTTP status ${Status:-none} after up to" \
            "$((${LANDIN_FETCH_RETRIES:-3} + 1)) attempts" >&2
        rm -f "$Into/$Archive"
        return 1
    }
    #  Never asked again: the bytes arrived and are not the pinned ones.
    ( cd "$Into" && printf '%s  %s\n' "$Sha" "$Archive" | sha256sum -c - ) || {
        echo "landin_fetch: $Archive: $From/$Archive is not the pinned" \
            "archive: its SHA-256 is not $Sha" >&2
        return 1
    }

    mkdir -p "$Into/$Directory"
    tar xzf "$Into/$Archive" -C "$Into/$Directory" --strip-components=1 \
        || return 1
    rm -f "$Into/$Archive"
}
