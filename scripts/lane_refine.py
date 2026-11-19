"""The `--refine PATH` every lane takes, and the command it runs.

    sys.path.insert(0, str(ROOT / 'scripts'))
    import lane_refine

    lane_refine.argument(parser)                    # --refine PATH, required
    lane_refine.argument(parser, required=False)    # optional, None if absent
    lane_refine.argument(parser, environment=True)  # $LANDIN_REFINE if absent
    args = parser.parse_args()
    subprocess.run([*lane_refine.command(args.refine, 'svd'), ...])

`argument` adds `--refine` to an argparse parser.  Its value is a `Path`,
as given, and parsing it asks scripts/refine_revision.py once whether that
binary is the one this checkout builds, writing D1307's one-line warning
to standard error when it is not; a warning never changes a lane's status.
A value from $LANDIN_REFINE is asked the same way.

`command(refine, name)` is the start of the argument vector that runs the
command NAME with the binary a lane was given: `[refine, NAME]` for the
`refine` dispatcher, `[refine-NAME]` alone for the split command's own
executable (D1383), so one suite runs `refine svd ...` or `refine-svd ...`
by the path it was handed.  A split command named for another command is
refused.  `dispatcher(refine)` is the `refine` for the commands a split
does not run, the one installed beside it (D1384).

Every lane that takes `--refine` takes it here; the rig's board tools,
which run with no scripts/ beside them, take it from
environments/boards/common.py, which asks through `warn`.
scripts/tests/test_refine_revision.py holds both to it.
"""
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import refine_revision  # noqa: E402

#  The variable a lane taking `environment=True` reads without --refine.
ENVIRONMENT = 'LANDIN_REFINE'

_asked = set()


class LaneError(ValueError):
    """A refine that cannot run what the lane asks of it."""


def warn(refine):
    """Ask once whether REFINE is this checkout's (refine_revision.warn),
    and return REFINE; None and an empty path are not asked."""
    if refine:
        key = os.path.abspath(str(refine))
        if key not in _asked:
            _asked.add(key)
            refine_revision.warn(refine)
    return refine


def _given(text):
    return warn(Path(text))


def argument(parser, *, required=True, environment=False, help=None):
    """Add `--refine PATH` to PARSER, asked once when parsed.

    REQUIRED: the lane refuses to run without one.  ENVIRONMENT: an absent
    --refine is $LANDIN_REFINE's, and a required one is required only when
    the variable is unset or empty.  Returns the argparse action."""
    default = None
    if environment:
        default = os.environ.get(ENVIRONMENT) or None
        required = required and default is None
    return parser.add_argument('--refine', type=_given, required=required,
                               default=default, help=help)


def split_name(refine):
    """NAME when REFINE is the split command `refine-NAME`, else None."""
    return refine_revision.split_name(refine)


def command(refine, name):
    """The argument vector's start that runs command NAME with REFINE:
    [REFINE] for `refine-NAME`, [REFINE, NAME] for `refine`."""
    split = split_name(refine)
    if split == name:
        return [str(refine)]
    if split is not None:
        raise LaneError('%s is the split command %s, not %s: name the refine'
                        ' that dispatches it, or refine-%s itself'
                        % (refine, split, name, name))
    return [str(refine), name]


def dispatcher(refine):
    """The `refine` that runs the commands REFINE does not: REFINE itself,
    or for a split command the refine installed beside it (D1384)."""
    if split_name(refine) is None:
        return refine
    found = refine_revision.installation_refine(refine)
    if found is None:
        raise LaneError('%s is a split command with no refine installed'
                        ' beside it, in ../../bin/: the cases that compile'
                        ' need one; name refine instead' % refine)
    return found
