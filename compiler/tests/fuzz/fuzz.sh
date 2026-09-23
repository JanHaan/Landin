#!/bin/sh
#  Mutate every single-source positive and negative fixture and flag each
#  mutant refine does not answer with a verdict: any exit other than 0 or 1,
#  a run past the time limit, or a defect or exhaustion line.  A refusal is
#  the expected answer to a mutant, so it is never a hit.
#
#  usage: fuzz.sh REFINE ROUNDS SEED [OUT]
#
#  Seeds run from SEED upward, one per mutant, over the fixtures in sorted
#  order, so a seed names the same mutant only against the same fixture tree.
#  Each hit is kept as OUT/hit-SEED.ldn.  OUT defaults to a new temporary
#  directory, printed at the end.

set -eu

if [ $# -lt 3 ] || [ $# -gt 4 ]; then
   echo "usage: fuzz.sh REFINE ROUNDS SEED [OUT]" >&2
   exit 2
fi
here=$(cd -- "$(dirname -- "$0")" && pwd)
refine=$(cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")
rounds=$2
seed_base=$3
out=${4:-$(mktemp -d)}
limit=${LANDIN_FUZZ_SECONDS:-30}
mkdir -p "$out"
case_file=$out/case.ldn

cd "$here/../fixtures"
total=0
hits=0
for fixture in $(ls -d positive/*/ negative/*/ | sort); do
   set -- "$fixture"*.ldn
   [ $# -eq 1 ] && [ -f "$1" ] || continue
   source=$1
   round=1
   while [ "$round" -le "$rounds" ]; do
      seed=$((seed_base + total))
      perl "$here/mutate.pl" "$seed" "$source" "$case_file"
      status=0
      report=$(timeout "$limit" "$refine" "$case_file" 2>&1) || status=$?
      total=$((total + 1))
      if { [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; } \
         || printf '%s\n' "$report" | grep -q \
            -e 'internal compiler defect' -e 'host resources exhausted' \
            -e '^raised ' -e 'CONSTRAINT_ERROR' -e 'PROGRAM_ERROR'
      then
         hits=$((hits + 1))
         cp "$case_file" "$out/hit-$seed.ldn"
         echo "HIT seed=$seed rc=$status src=$source ::" \
            "$(printf '%s\n' "$report" | tail -2 | tr '\n' ' ')"
      fi
      round=$((round + 1))
   done
done
rm -f "$case_file"
echo "total=$total hits=$hits out=$out"
