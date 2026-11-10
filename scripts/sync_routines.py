#!/usr/bin/env python3
"""Copy each published example's shared routines into the fixtures that carry them.

A published example is one file, so the fixtures that run its routine
where the example cannot -- on firmware through `core/io.memory`, over a
closed standard input -- carry the routine themselves, and `check.py`
holds every copy to the published text, byte for byte
(`SHARED_ROUTINES`).  After an edit to a published example's routine,
this writes the routine over each copy:

    python3 scripts/sync_routines.py

The published file is always the source.  It prints each routine it
rewrote and exits 0, or 1 when a copy does not declare a routine it
should carry, which is not guessed at.  Run `python3 check.py` after it,
and re-record what the edited fixtures emit if the edit was more than
cosmetic.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import check  # noqa: E402


def main(argv):
    if argv[1:]:
        print(__doc__.strip(), file=sys.stderr)
        return 0 if argv[1:] in (["--help"], ["-h"]) else 2
    written, refusals = check.sync_shared_routines()
    for copy, name in written:
        print("wrote %s into %s" % (name, copy))
    if not written and not refusals:
        print("every copy already carries its published routine")
    for refusal in refusals:
        print("sync_routines: " + refusal, file=sys.stderr)
    return 1 if refusals else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
