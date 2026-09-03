#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
integration=false
case "${1-}" in
    "") ;;
    --integration) integration=true ;;
    *) echo "usage: $0 [--integration]" >&2; exit 2 ;;
esac

test_tmp=$(mktemp -d "${TMPDIR:-/tmp}/landin-highlight-tests.XXXXXX")
trap 'rm -rf -- "$test_tmp"' EXIT HUP INT TERM

python3 "$root/highlight/generate.py" --check
python3 "$root/highlight/test_adapters.py"

if test -d "$root/highlight/textmate/node_modules" && command -v node >/dev/null 2>&1; then
    extension_tmp="$test_tmp/vsix"
    mkdir -p "$extension_tmp"
    (
        cd "$root/highlight/textmate"
        npm test
        npm run package:check
        ./node_modules/.bin/vsce package \
          --out "$extension_tmp/landin-language.vsix" >/dev/null
    )
    test -s "$extension_tmp/landin-language.vsix"
    echo "TextMate tokenizer and VSIX packaging clean"
else
    echo "TextMate test dependencies absent; tokenizer smoke skipped"
fi

tree_cli="$root/highlight/tree-sitter/node_modules/.bin/tree-sitter"
if test -x "$tree_cli"; then
    tree_work="$test_tmp/tree-sitter"
    mkdir -p "$tree_work/config" "$tree_work/cache"
    XDG_CONFIG_HOME="$tree_work/config" "$tree_cli" init-config >/dev/null 2>&1 || :
    (
        cd "$root/highlight/tree-sitter"
        export XDG_CONFIG_HOME="$tree_work/config"
        export XDG_CACHE_HOME="$tree_work/cache"
        npm run generate
        "$tree_cli" test
        "$tree_cli" parse --quiet \
          "$root/highlight/tests/structural.ldn"
        if ! "$tree_cli" highlight --check \
          "$root/highlight/tests/structural.ldn" \
          > /dev/null 2> "$tree_work/highlight-errors"; then
            cat "$tree_work/highlight-errors" >&2
            exit 1
        fi
        for query in queries/*.scm; do
            "$tree_cli" query "$query" \
              "$root/highlight/tests/structural.ldn" >/dev/null
        done
        if test "$integration" = true; then
            find "$root/compiler/tests/fixtures/positive" \
                 "$root/compiler/tests/fixtures/runtime" \
                 "$root/core" -name '*.ldn' -print \
              | sort \
              | xargs "$tree_cli" parse --quiet
            echo "tree-sitter compiler/core integration corpus clean"
        fi
        echo "tree-sitter isolated parser and queries clean"
    )
else
    echo "tree-sitter CLI absent; structural checks skipped"
fi

if command -v vim >/dev/null 2>&1; then
    LANDIN_HIGHLIGHT_ROOT="$root/highlight" \
      vim -Nu NONE -n -es -i NONE -S "$root/highlight/tests/vim-smoke.vim"
    echo "Vim filetype and syntax smoke clean"
else
    echo "Vim absent; native Vim smoke skipped"
fi

if command -v luac >/dev/null 2>&1; then
    find "$root/highlight/nvim" -name '*.lua' -print \
      | sort \
      | xargs -n 1 luac -p
    echo "Neovim Lua syntax clean"
else
    echo "Lua compiler absent; Neovim Lua syntax check skipped"
fi

if command -v nvim >/dev/null 2>&1 && command -v cc >/dev/null 2>&1; then
    nvim_runtime="$test_tmp/nvim"
    mkdir -p "$nvim_runtime/parser" "$nvim_runtime/data" \
             "$nvim_runtime/state" "$nvim_runtime/cache"
    if test "$(uname -s)" = Darwin; then
        shared=-dynamiclib
    else
        shared=-shared
    fi
    cc -O2 -fPIC "$shared" \
      -I"$root/highlight/tree-sitter/src" \
      -o "$nvim_runtime/parser/landin.so" \
      "$root/highlight/tree-sitter/src/parser.c" \
      "$root/highlight/tree-sitter/src/scanner.c"
    XDG_DATA_HOME="$nvim_runtime/data" \
    XDG_STATE_HOME="$nvim_runtime/state" \
    XDG_CACHE_HOME="$nvim_runtime/cache" \
    LANDIN_FIXTURE="$root/highlight/tests/structural.ldn" \
    LANDIN_NVIM_SMOKE="$root/highlight/tests/nvim-smoke.lua" \
      nvim -n --headless --clean \
      --cmd "set runtimepath^=$nvim_runtime" \
      --cmd "set runtimepath^=$root/highlight/nvim" \
      '+lua dofile(assert(os.getenv("LANDIN_NVIM_SMOKE")))'
    echo "Neovim parser and query smoke clean"
else
    echo "Neovim or C compiler absent; live Neovim smoke skipped"
fi

if command -v emacs >/dev/null 2>&1; then
    LANDIN_HIGHLIGHT_ROOT="$root/highlight" \
      emacs --batch -Q -l "$root/highlight/tests/emacs-smoke.el"
else
    echo "Emacs absent; native Emacs smoke skipped"
fi

if command -v pwsh >/dev/null 2>&1; then
    LANDIN_SCRIPT="$root/highlight/visual-studio/install.ps1" \
      pwsh -NoProfile -Command \
      '$tokens = $null; $errors = $null; [System.Management.Automation.Language.Parser]::ParseFile($env:LANDIN_SCRIPT, [ref]$tokens, [ref]$errors) > $null; if ($errors.Count) { exit 1 }'
    echo "Visual Studio installer syntax clean"
fi

echo "highlight packages clean"
