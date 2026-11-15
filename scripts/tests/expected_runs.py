"""A stand-in for subprocess.run that answers only the calls a test expects.

The board tests once patched subprocess.run with one reply for every call,
a `str` stdout among them, so a tool that added a call of its own got that
reply too and failed deep in the new code, with an AttributeError on a
`str` it took for `bytes`, rather than with a word about the mock.  This
answers each call by its program, the last component of argv[0], and
refuses a call to any other program by name:

    with mock.patch.object(subprocess, 'run', side_effect=expect({
            'ssh': SimpleNamespace(returncode=0, stdout='/tmp/x\\n', stderr='')})):

A reply is returned as it is, raised when it is an exception, or called
with the call's argv and keywords when it is callable.  The side effect
keeps every argv it was asked to run in its `calls`.
"""
from pathlib import Path


class Unexpected(AssertionError):
    """A call to a program the test did not expect."""


def expect(replies):
    """subprocess.run's side effect, answering the programs REPLIES names."""
    def run(argv, *args, **keywords):
        argv = [str(part) for part in argv] if not isinstance(argv, str) else [argv]
        run.calls.append(argv)
        program = Path(argv[0]).name if argv else ''
        if program not in replies:
            raise Unexpected(
                'subprocess.run was asked to run %r, and this test expects only %s;'
                ' name %r and its reply in the test\'s expect({...})'
                % (argv, ', '.join(sorted(replies)) or 'no call', program))
        reply = replies[program]
        if isinstance(reply, BaseException):
            raise reply
        return reply(argv, *args, **keywords) if callable(reply) else reply
    run.calls = []
    return run
