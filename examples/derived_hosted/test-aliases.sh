#!/bin/sh
# Run with the path to a built log-filter executable.
set -eu

filter=$1
mkdir -p /tmp/landin-loop
scratch=$(mktemp -d /tmp/landin-loop/log-filter-aliases.XXXXXX)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
cd "$scratch"

for kind in relative parent symlink hardlink exact distinct; do
    printf 'INFO keep\nERROR keep\n' > input.log
    cp input.log saved.log
    rm -f output.log link.log
    case "$kind" in
        relative) target=./input.log ;;
        parent) mkdir -p sub; target=sub/../input.log ;;
        symlink) ln -s input.log link.log; target=link.log ;;
        hardlink) ln input.log link.log; target=link.log ;;
        exact) target=input.log ;;
        distinct) printf 'stale\n' > output.log; target=output.log ;;
    esac

    if "$filter" --out "$target" input.log > stdout.txt 2> stderr.txt; then
        test "$kind" = distinct
        cmp -s output.log saved.log
    else
        test "$kind" != distinct
        cmp -s "$target" saved.log
    fi
    cmp -s input.log saved.log
    printf '%s: pass\n' "$kind"
done

# A genuinely absent output is permitted. Lookup failures must preserve the
# input, and a missing input must leave an existing output untouched.
rm -f output.log
"$filter" --out output.log input.log > stdout.txt 2> stderr.txt
cmp -s output.log saved.log
printf 'absent output: pass\n'

ln -s cycle-b cycle-a
ln -s cycle-a cycle-b
for target in cycle-a input.log/child; do
    if "$filter" --out "$target" input.log > stdout.txt 2> stderr.txt; then
        exit 1
    fi
    cmp -s input.log saved.log
done
printf 'output lookup failures: pass\n'

if "$filter" --out output.log absent-input.log > stdout.txt 2> stderr.txt; then
    exit 1
fi
cmp -s output.log saved.log
printf 'missing input preserves output: pass\n'
