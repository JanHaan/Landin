# Writing a command for refine

This page is the whole contract between `refine` and a contributed
`refine-NAME`, a tool of your own that `refine NAME` runs. It is derived
from the dispatcher and held to it by `scripts/tests/test_cli_native.py`,
which runs this page's example. It decides nothing: `spec.md`'s decisions
D1384, D1385, D1387, D1484-D1488 and D1603 do, and `refine explain D1384`
prints one.

## Finding the command

`refine NAME ARGS...` runs a contributed command when NAME is an ASCII
letter followed by letters, digits, `-` and `_`, and is neither one of
`refine`'s built-in commands, which `refine help` lists, nor one of the
split commands `refine` ships, today `svd`, `bindings`, `site` and `dap`.
A word with `/` or `.` in it is never a command name (D1484).

The executable is `refine-NAME` in a directory on `PATH`. The first
directory that has one wins. An empty `PATH` element is skipped, not read
as the working directory (D1384, D1484).

`build` is such a name. `refine` has no build command of its own, so
`refine build` runs a contributed `refine-build` (D1603). With none on
`PATH`, `refine build` is refused with L0002, which says so.

An option written before NAME, as in `refine -v NAME`, is `refine`'s own,
and the request is refused. Write the tool's options after its name. A
name that nothing answers is refused as an unknown command.

## What refine asks of it

`refine` runs the tool in five ways. A tool must answer the first; the
others matter as soon as someone uses the feature behind them.

### 1. `refine-NAME --describe`

Asked before every run, before `refine help NAME`, before forwarding an
explanation, and for every listing in `refine help`. The tool must exit 0
within 10 seconds and print one JSON object on standard output. It is run
without `LANDIN_REFINE`, since a description must not depend on its caller.

| key | required | value |
|---|---|---|
| `format` | yes | the string `"landin-command-1"` |
| `name` | yes | a string equal to NAME |
| `summary` | yes | a string, which may be empty; `refine help` shows it beside the command and its path |
| `codes` | yes | an array, which may be empty, of the diagnostic-code prefixes the tool claims |
| `source_digest` | no | only for commands shipped with `refine`; leave it out, it is not checked for a contributed command |

Each prefix in `codes` is two to eight capital ASCII letters. `L` is
Landin's own and is never claimed. Other keys are ignored.

A refused description is error L0695 (D1387). It names the tool's path,
what `refine` asked, what came back and what to do, and the command is not
run. The description is refused when the tool could not be started, did
not answer within 10 seconds, was ended by a signal or exited with a
nonzero status; when the answer is not JSON or not an object; when a key
is missing or has the wrong type; and when it gives another format or
another name, claims `L`, or has a malformed prefix.

### 2. `refine-NAME ARGS...`

Run for `refine NAME ARGS...`. The tool receives every word after NAME,
exactly as written, in order, empty ones included. `refine` expands no
`@file` and parses no option in them, so `--help` and `@args` there are
the tool's own. Standard input, output and error are the terminal's, and
`refine` exits with the tool's status (D1484).

### 3. `refine-NAME --help`

Run for `refine help NAME`. It is the tool's own help, shown as the tool
prints it (D1488).

### 4. `refine-NAME --complete -- WORD...`

Run from the shell completion scripts that `refine completion bash`, `zsh`
or `fish` writes. WORD... are the words after NAME up to and including the
one being completed. That one comes last and is empty when nothing has
been typed yet, so completing right after `refine NAME ` passes
`--complete -- ""`. Print one candidate a line and exit 0. The scripts
call it through `refine NAME --complete -- ...`, so the same lookup and
the same description check apply (D1485).

### 5. `refine-NAME explain CODE`

Run for `refine explain CODE` when CODE is a claimed prefix followed by at
least one digit, such as `RB0102` for the prefix `RB`, and exactly one
contributed command on `PATH` claims that prefix. Before running it,
`refine` prints on standard output:

```text
CODE is explained by refine-NAME at PATH, not by Landin
```

If no command claims the prefix, or more than one does, `refine` refuses
the code and names them (D1385).

## The environment

For runs, `--help`, `--complete` and `explain`, `refine` sets
`LANDIN_REFINE` to the absolute path of its own executable, links
resolved, replacing any value the caller had. It is empty when the host
cannot name that path. A tool that calls the compiler back should run that
path, and fall back to `refine` on `PATH` when the variable is unset, as
it is when the tool is run by its own name (D1486).

## An example

A complete `refine-hello`. Save it as `refine-hello` in a directory on
`PATH` and make it executable.

```sh
#!/bin/sh
case "$1" in
--describe)
    printf '%s\n' '{"format":"landin-command-1","name":"hello","summary":"Greet someone","codes":["HELLO"]}'
    ;;
--help)
    printf 'usage: refine hello [NAME]\n'
    ;;
--complete)
    printf 'world\nlandin\n'
    ;;
explain)
    case "$2" in
    HELLO1)
        printf 'HELLO1: hello was given more than one name.\n'
        ;;
    *)
        printf 'unknown code: %s\n' "$2" >&2
        exit 2
        ;;
    esac
    ;;
*)
    if [ "$#" -gt 1 ]; then
        printf 'error[HELLO1]: hello takes one name\n' >&2
        exit 1
    fi
    printf 'hello, %s\n' "${1-world}"
    ;;
esac
```

It offers the same two candidates whatever has been typed; a real tool
would filter them by the last word. It does not call the compiler, so it
does not read `LANDIN_REFINE`.

```text
$ refine help hello
usage: refine hello [NAME]
$ refine hello Ada
hello, Ada
$ refine explain HELLO1
HELLO1 is explained by refine-hello at /home/you/bin/refine-hello, not by Landin
HELLO1: hello was given more than one name.
```
