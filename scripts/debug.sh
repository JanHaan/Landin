#!/bin/sh
# Exercise an already-built compiler; never race a build or hide a non-run.
. "$(dirname -- "$0")/env.sh"
landin_build_lock mode "$@"
# Target selection is explicit; native checks never fall back to a transport.
if [ "${1:-}" = "--target=darwin-arm64" ]; then
    shift
    landin_require python3
    python3 "$LANDIN_ROOT/scripts/tests/test_macho_identity.py"
    exec python3 "$LANDIN_ROOT/compiler/tests/debugging/darwin.py" \
        --refine "$LANDIN_BUILD_DIR/bin/refine" "$@"
fi

: "${LANDIN_GNAT_HOME:?set LANDIN_GNAT_HOME to the pinned Linux installation}"
landin_require python3

if [ -n "${LANDIN_GDB:-}" ]; then
    set -- --gdb "$LANDIN_GDB" "$@"
fi
if [ -n "${LANDIN_QEMU:-}" ]; then
    set -- --qemu "$LANDIN_QEMU" "$@"
fi

python3 "$LANDIN_ROOT/compiler/tests/debugging/test_check.py"
exec python3 "$LANDIN_ROOT/compiler/tests/debugging/check.py" \
    --refine "$LANDIN_BUILD_DIR/bin/refine" \
    --toolchain "$LANDIN_GNAT_HOME" \
    --output "$LANDIN_BUILD_DIR/debugging" \
    "$@"
