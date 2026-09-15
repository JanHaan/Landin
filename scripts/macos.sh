#!/bin/sh
# Native R5.10 environment evidence, using the ordinary build environment.
. "$(dirname -- "$0")/env.sh"
exec python3 "$LANDIN_ROOT/scripts/macos_environment.py" "$@"
