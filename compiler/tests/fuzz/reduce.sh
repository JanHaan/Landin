#!/bin/sh
#  Reduce a hit by deleting runs of lines, 16 down to 1, for as long as
#  refine still exits with the same status.  The status is the only
#  signature kept, so compare the reduced file's defect with the original's
#  under a debugger before trusting that it is the same one.
#
#  usage: reduce.sh REFINE IN OUT [STATUS]
#
#  STATUS defaults to 70, the defect exit.

set -eu

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
   echo "usage: reduce.sh REFINE IN OUT [STATUS]" >&2
   exit 2
fi
refine=$1
want=${4:-70}
limit=${LANDIN_FUZZ_SECONDS:-30}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trial=$work/trial.ldn

keeps() {
   status=0
   timeout "$limit" "$refine" "$1" >/dev/null 2>&1 || status=$?
   [ "$status" -eq "$want" ]
}

cp "$2" "$3"
if ! keeps "$3"; then
   echo "reduce.sh: $2 does not exit $want" >&2
   exit 1
fi
for chunk in 16 8 4 2 1; do
   changed=1
   while [ "$changed" -eq 1 ]; do
      changed=0
      last=$(wc -l < "$3")
      while [ "$last" -ge 1 ]; do
         first=$((last - chunk + 1))
         [ "$first" -lt 1 ] && first=1
         sed "${first},${last}d" "$3" > "$trial"
         if keeps "$trial"; then
            cp "$trial" "$3"
            changed=1
         fi
         last=$((first - 1))
      done
   done
done
