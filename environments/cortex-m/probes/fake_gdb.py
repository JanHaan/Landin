#!/usr/bin/env python3
"""A stand-in for gdb-multiarch that serves sessions without a debugger.

Invoked as `fake_gdb.py -q -nx -batch -x gdb_server.py`, it runs the real
serving loop against a `gdb` module that understands only what the controls
need: a sourced script's `python` blocks run in `__main__`, `fail` raises a
debugger error, `die` ends the process, `sleep` stalls, and the logging
settings redirect output to the session's log.
"""
import sys
import time
from pathlib import Path


class error(RuntimeError):
    pass


class Gdb:
    error = error
    STDERR = 1

    def __init__(self):
        self.log = None
        self.logging = False
        self.path = None

    def write(self, text, stream=None):
        (self.log if self.logging else sys.stdout).write(text)

    def execute(self, command, to_string=False):
        words = command.split(' ', 1)
        if command.startswith('set logging file '):
            self.path = command[len('set logging file '):]
        elif command == 'set logging enabled on':
            self.log, self.logging = open(self.path, 'w'), True
        elif command == 'set logging enabled off':
            self.log.close()
            self.logging = False
        elif words[0] == 'source':
            self.source(Path(words[1]))
        return ''

    def source(self, path):
        import __main__
        lines = iter(path.read_text().splitlines())
        for line in lines:
            if line == 'python':
                block = []
                for inner in lines:
                    if inner == 'end':
                        break
                    block.append(inner)
                stdout, sys.stdout = sys.stdout, self.log
                try:
                    exec('\n'.join(block), vars(__main__))
                except Exception as problem:
                    raise error('Error occurred in Python: %s' % problem)
                finally:
                    sys.stdout = stdout
            elif line == 'fail':
                raise error('Undefined command: "fail".')
            elif line == 'die':
                sys.exit(3)
            elif line.startswith('sleep '):
                time.sleep(float(line.split()[1]))


if __name__ == '__main__':
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    import gdb_server
    gdb_server.serve(Gdb())
