#!/bin/sh
# Exercise an already-built compiler; never race a build or hide a non-run.
. "$(dirname -- "$0")/env.sh"
# Help reads nothing of the build, so it does not wait for its lock.
for Argument do
    case "$Argument" in
        -h | --help) Help=yes ;;
    esac
done
if [ -z "${Help:-}" ]; then
    landin_build_lock mode "$@"
fi
# Target selection is explicit; native checks never fall back to a transport.
# A target this script has no lane for is refused with the one that debugs
# it, before anything is built or waited for.
for Argument do
    case "$Argument" in
        --target=linux-rv64)
            echo "landin: debug.sh has no linux-rv64 lane; RV64 GDB runs on a" >&2
            echo "landin: physical RISC-V Linux machine, through" >&2
            echo "landin:   compiler/tests/rv64/check.py --kind=debugger --prepare-only --refine=REFINE --output=DIR" >&2
            echo "landin: here, then --kind=debugger --prepared=DIR --output=DIR2 on that machine" >&2
            echo "landin: (compiler/tests/rv64/README.md); its gate lanes are suspended" >&2
            exit 2 ;;
        --target=freebsd-x86-64 | --target=freebsd-arm64)
            echo "landin: debug.sh has no FreeBSD lane; FreeBSD's LLDB sessions run in its VM," >&2
            echo "landin: through compiler/tests/freebsd/check.py --kind=debugger --arch=amd64|arm64" >&2
            echo "landin: (compiler/tests/freebsd/README.md)" >&2
            exit 2 ;;
        --target=cortex-m0)
            echo "landin: debug.sh has no cortex-m0 lane; Cortex-M source stops run" >&2
            echo "landin: under QEMU and GDB in the Cortex-M lane, environments/cortex-m/run.py" >&2
            echo "landin: (environments/cortex-m/README.md)" >&2
            exit 2 ;;
    esac
done
if [ "${1:-}" = "--target=darwin-arm64" ]; then
    shift
    landin_require python3
    python3 "$LANDIN_ROOT/scripts/tests/test_macho_identity.py"
    exec python3 "$LANDIN_ROOT/compiler/tests/debugging/darwin.py" \
        --refine "$LANDIN_BUILD_DIR/bin/refine" "$@"
fi

#  The pinned installation: LANDIN_GNAT_HOME when it is set, as env.sh
#  reads it, and otherwise the one whose gnat is on PATH, which is how
#  `nix develop` and an installation added to PATH both provide it.
if [ -z "${LANDIN_GNAT_HOME:-}" ]; then
    if Gnat="$(command -v gnat)"; then
        LANDIN_GNAT_HOME="$(CDPATH='' cd -- "$(dirname -- "$Gnat")/.." && pwd)"
    else
        echo "landin: debug.sh needs the pinned Linux GNAT installation:" >&2
        echo "landin: no gnat is on PATH and LANDIN_GNAT_HOME is unset" >&2
        echo "landin: run inside nix develop, or set LANDIN_GNAT_HOME" >&2
        exit 127
    fi
fi
if [ ! -x "$LANDIN_GNAT_HOME/bin/gnat" ]; then
    echo "landin: LANDIN_GNAT_HOME is '$LANDIN_GNAT_HOME', which has no bin/gnat;" >&2
    echo "landin: name the pinned Linux GNAT installation" >&2
    exit 2
fi
landin_require python3

if [ -n "${LANDIN_GDB:-}" ]; then
    set -- --gdb "$LANDIN_GDB" "$@"
fi
if [ -n "${LANDIN_QEMU:-}" ]; then
    set -- --qemu "$LANDIN_QEMU" "$@"
fi

#  --target=linux-arm64 or linux-x86-64 passes through to the GDB lane,
#  which otherwise debugs this host's own Linux target.
python3 "$LANDIN_ROOT/compiler/tests/debugging/test_check.py"
exec python3 "$LANDIN_ROOT/compiler/tests/debugging/check.py" \
    --refine "$LANDIN_BUILD_DIR/bin/refine" \
    --toolchain "$LANDIN_GNAT_HOME" \
    --output "$LANDIN_BUILD_DIR/debugging" \
    "$@"
