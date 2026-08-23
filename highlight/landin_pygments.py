"""A Pygments lexer for Landin, over the scanner of landin_highlight.py.

Pygments does not require a lexer to be a pile of regexes: a `Lexer` that
implements `get_tokens_unprocessed` can wrap a scanner that already
exists, which is the whole point here.  The reading copies under
docs/site/ and this lexer are two renderings of one scanner, so neither
can drift into colouring the language differently from the other.

    python3 -m landin_pygments file.ldn        as 256-colour terminal text

Installed, it registers itself as the `landin` lexer, and `.ldn` files are
recognised by name:

    from pygments.lexers import get_lexer_by_name
    get_lexer_by_name("landin")
"""

from __future__ import annotations

from pygments.lexer import Lexer
from pygments.token import (Comment, Keyword, Name, Number, Operator, String,
                            Text)

from landin_highlight import CLASSES, Scanner, collect_symbols

#  Every class the scanner emits, mapped onto the token Pygments styles.
TOKENS = {
    "k":  Keyword,
    "t":  Keyword.Type,
    "v":  Name.Constant,
    "b":  Name.Builtin,
    "f":  Name.Function,
    "s":  Name.Attribute,
    "d":  Name.Variable,
    "n":  Number,
    "q":  String,
    "o":  Operator,
    "c":  Comment,
    "cd": Comment.Special,
    None: Text,
}

#  A class the scanner gains and this map does not is a class that would
#  quietly lose its colour here.  Fail at import instead.
_missing = set(CLASSES) - set(TOKENS)
if _missing:
    raise ImportError(
        "landin_pygments: landin_highlight emits classes this lexer does "
        "not map: " + ", ".join(sorted(str(c) for c in _missing)))


class LandinLexer(Lexer):
    """Landin, as its own scanner sees it."""

    name = "Landin"
    aliases = ["landin", "ldn"]
    filenames = ["*.ldn"]
    mimetypes = ["text/x-landin"]
    url = "https://www.701.dev"

    def get_tokens_unprocessed(self, text):
        lines = text.splitlines(keepends=True)

        #  The file's own type and atom names, so that a name it declares
        #  reads as one everywhere it is used.  This is the reason the
        #  lexer takes the whole file rather than a line at a time.
        scanner = Scanner(*collect_symbols(
            [line.rstrip("\r\n") for line in lines]))

        pos = 0
        for line in lines:
            body = line.rstrip("\r\n")
            for cls, piece in scanner.scan(body):
                yield pos, TOKENS[cls], piece
                pos += len(piece)
            ending = line[len(body):]
            if ending:
                yield pos, Text, ending
                pos += len(ending)


def main(argv):
    from pygments import highlight
    from pygments.formatters import Terminal256Formatter

    if len(argv) != 2:
        print(__doc__.strip().split("\n\n")[-1], flush=True)
        return 2
    with open(argv[1], encoding="utf-8") as handle:
        print(highlight(handle.read(), LandinLexer(),
                        Terminal256Formatter()), end="")
    return 0


if __name__ == "__main__":
    import sys
    raise SystemExit(main(sys.argv))
