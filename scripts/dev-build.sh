#!/bin/sh
#  Fast checksum-safe developer compilation.  The ordinary build remains the
#  clean-on-change build; use it before making a claim about the tree.  The
#  gate's one use of this build is held to a clean one (docs/process.md).

set -eu

LANDIN_BUILD_INCREMENTAL=yes
export LANDIN_BUILD_INCREMENTAL

exec "$(dirname -- "$0")/build.sh" "$@"
