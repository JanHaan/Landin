#!/usr/bin/env bash
#  The flake's development shell as a file of exports, for an agent harness
#  that runs every command in a fresh shell.
#
#      ./scripts/agent_env.sh            # prints the file's path
#
#  `nix develop -c CMD` evaluates the flake, copying the checkout into the
#  store, before every command: about two seconds each, which an agent pays
#  thousands of times an item, and a command without it finds no python3.
#  This evaluates once per flake.nix, flake.lock and environments/pins.sh,
#  and writes only what the shell exports differently from the caller's
#  environment.  Its scratch directory and TMPDIR are left out, so sourcing
#  the file creates nothing, and PATH is written as a prefix of the PATH it
#  is sourced into.  Claude Code takes it through a SessionStart hook; see
#  "Local agent feedback" in docs/process.md.
#
#  Where there is no nix, or python3 and gprbuild are already on PATH, it
#  prints /dev/null and succeeds, so `. "$(./scripts/agent_env.sh)"` holds
#  in every shell and a hook calling it is harmless on every host.  A
#  worktree whose flake or pins differ from the checkout the file was made
#  for still needs `nix develop` of its own.

set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v nix > /dev/null ||
    { command -v python3 > /dev/null && command -v gprbuild > /dev/null; }; then
    #  Nothing to add, and an empty path would make the sourcing shell
    #  fail with no word of why.
    printf '%s\n' /dev/null
    exit 0
fi

key=$(cat "$root/flake.nix" "$root/flake.lock" "$root/environments/pins.sh" |
    sha256sum | cut -c1-16)
cache=${XDG_CACHE_HOME:-$HOME/.cache}/landin/agent-env
file=$cache/$key.sh

#  A cached file stays good while the store paths it names exist; the
#  profile beside it is the garbage collector's root for them.
if [ -s "$file" ]; then
    first=$(sed -n "s/^export PATH='\([^:']*\).*/\1/p" "$file")
    if [ -n "$first" ] && [ -d "$first" ]; then
        printf '%s\n' "$file"
        exit 0
    fi
fi

mkdir -p "$cache"
script=$(mktemp "$cache/print-dev-env.XXXXXX")
trap 'rm -f "$script" "$script".*' EXIT
nix --extra-experimental-features 'nix-command flakes' print-dev-env \
    --option warn-dirty false --profile "$cache/$key.profile" "$root" \
    > "$script"

#  Source the shell's script in a child, discarding the hook's output, and
#  compare what it exports with what the child started with.
env -0 > "$script.before"
bash -c '. "$1" > /dev/null 2>&1; env -0' agent_env "$script" > "$script.out"
changed_exports() {
    #  Lines are NAME=VALUE separated by NUL; a value may hold newlines.
    local name value before_path
    declare -A before=()
    while IFS= read -r -d '' entry; do
        before[${entry%%=*}]=${entry#*=}
    done < "$script.before"
    before_path=${before[PATH]:-}
    while IFS= read -r -d '' entry; do
        name=${entry%%=*}
        value=${entry#*=}
        case $name in
            TMP | TMPDIR | TEMP | TEMPDIR | NIX_BUILD_TOP | PWD | OLDPWD | \
                SHLVL | _ | HOME | USER | LOGNAME | SHELL | TERM | \
                BASH_FUNC_*) continue ;;
            *[!A-Za-z0-9_]* | '') continue ;;
        esac
        if [ "$name" = PATH ]; then
            #  Store paths hold no quote, so the prefix is quoted plainly.
            printf "export PATH='%s':\"\$PATH\"\n" "${value%":$before_path"}"
            continue
        fi
        if [ "${before[$name]+set}" = set ] && [ "${before[$name]}" = "$value" ]; then
            continue
        fi
        printf 'export %s=%q\n' "$name" "$value"
    done < "$script.out"
}
changed_exports > "$script.env"
mv "$script.env" "$file"
printf '%s\n' "$file"
