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
#  and writes what the shell exports beyond a bare environment.  Its
#  scratch directory and TMPDIR are left out, so sourcing the file creates
#  nothing, and PATH is written as a prefix of the PATH it is sourced into.
#  Claude Code takes it through a SessionStart hook; see "Local agent
#  feedback" in docs/process.md.
#
#  Where there is no nix, it prints /dev/null and succeeds, so
#  `. "$(./scripts/agent_env.sh)"` holds in every shell and a hook calling
#  it is harmless on every host.  So it does where python3 and gprbuild are
#  already on PATH from this checkout's shell, which exports LANDIN_ENV_KEY
#  as this key, or from a toolchain that is no flake's.  When they come
#  from another checkout's shell, one whose flake or pins differ, as a
#  session started in one checkout and working in another's worktree has,
#  it says so on standard error and prints this checkout's file instead,
#  whose PATH comes first.

set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v nix > /dev/null; then
    #  Nothing to add, and an empty path would make the sourcing shell
    #  fail with no word of why.
    printf '%s\n' /dev/null
    exit 0
fi

#  flake.nix computes the same key for the LANDIN_ENV_KEY its shell exports.
key=$(cat "$root/flake.nix" "$root/flake.lock" "$root/environments/pins.sh" |
    sha256sum | cut -c1-16)
if command -v python3 > /dev/null && command -v gprbuild > /dev/null; then
    #  A flake's shell exports its key; one made before it did so still
    #  names its build tag nix-SYSTEM.  Anything else is a toolchain of the
    #  host's own, scripts/env.sh's among them, and is left as it is.
    theirs=${LANDIN_ENV_KEY:-}
    case ${LANDIN_BUILD_TAG:-} in
        nix-*) flake_shell=true ;;
        *) flake_shell=${theirs:+true} ;;
    esac
    if [ "$theirs" = "$key" ] || [ -z "$flake_shell" ]; then
        printf '%s\n' /dev/null
        exit 0
    fi
    printf 'agent_env: the python3 and gprbuild on PATH are the shell of' >&2
    printf ' another flake.nix, flake.lock or pins.sh (LANDIN_ENV_KEY=%s),' \
        "${theirs:-none}" >&2
    printf " not %s's (%s);" "$root" "$key" >&2
    printf " this checkout's is printed, and sourcing it puts its tools" >&2
    printf ' first on PATH\n' >&2
fi
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
#  compare what it exports with what the child started with.  Both start
#  from a bare environment, so the file holds every export of this
#  checkout's shell whatever the caller has: an export another checkout's
#  shell already set to the same value would otherwise be left out, and
#  the file, kept for every later caller, would lack it.
env -i HOME="$HOME" PATH="$PATH" env -0 > "$script.before"
#  shellcheck disable=SC2016 # $1 is the child's, expanded there
env -i HOME="$HOME" PATH="$PATH" \
    bash -c '. "$1" > /dev/null 2>&1; env -0' agent_env "$script" \
    > "$script.out"
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
        if [ "$name" = XDG_DATA_DIRS ]; then
            #  The shell's own, before whatever the sourcing shell has.
            printf "export XDG_DATA_DIRS='%s'\"\${XDG_DATA_DIRS:+:\$XDG_DATA_DIRS}\"\n" \
                "$value"
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
