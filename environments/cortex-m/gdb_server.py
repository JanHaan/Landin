"""One GDB process, many debugger sessions.

A Cortex-M run debugs about two thousand programs, each under its own QEMU,
and starting `gdb-multiarch` is most of what a session costs: sixty shared
libraries and an embedded Python before the first command.  This keeps one
GDB and hands it each session's unchanged script.

A session must not be able to see the one before it, or a definition left by
one program's script could satisfy another's assertion.  Before every session
the server restores the Python `__main__` namespace it started with, discards
breakpoints, disconnects and loads the session's own executable; the script
then connects to its own fresh emulator.  Each session's output, including
GDB and Python errors, goes to its own log, which the caller's oracle reads
exactly as it read a batch GDB's output.  A session that times out or leaves
the server unusable kills the process, and the next session starts a new one.

This file is both halves: imported, it is the client `Run` uses; sourced by
GDB, it is the loop that serves requests.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


class GdbServer:
    def __init__(self, gdb, env, cwd):
        #  `gdb` may be a Python stand-in, which the failure controls use.
        self.gdb, self.env, self.cwd = Path(gdb), env, cwd
        self.process = None

    def start(self):
        self.directory = Path(tempfile.mkdtemp(prefix='landin-gdb-'))
        requests, replies = self.directory / 'requests', self.directory / 'replies'
        os.mkfifo(requests)
        os.mkfifo(replies)
        env = dict(self.env, LANDIN_GDB_REQUESTS=str(requests),
                   LANDIN_GDB_REPLIES=str(replies))
        self.console = (self.directory / 'console.log').open('wb')
        argv = ([str(self.gdb)] if self.gdb.resolve().suffix != '.py' else
                [sys.executable, str(self.gdb.resolve())])
        self.process = subprocess.Popen(
            [*argv, '-q', '-nx', '-batch', '-x', __file__],
            cwd=self.cwd, env=env, stdin=subprocess.DEVNULL, stdout=self.console,
            stderr=subprocess.STDOUT, start_new_session=True)
        # Opening a FIFO blocks until the other end opens it; GDB opens the
        # request end first, so this order cannot deadlock.
        self.requests = requests.open('w', buffering=1)
        self.replies = os.open(replies, os.O_RDONLY | os.O_NONBLOCK)
        self.pending = b''

    def stop(self):
        if self.process is None:
            return
        for close in (self.requests.close, lambda: os.close(self.replies), self.console.close):
            try:
                close()
            except OSError:
                pass
        if self.process.poll() is None:
            os.killpg(self.process.pid, 9)
        self.process.wait()
        for path in self.directory.iterdir():
            path.unlink()
        self.directory.rmdir()
        self.process = None

    def session(self, elf, script, log, timeout):
        """Run one script; return whether GDB completed it without an error.

        A batch script ends in `quit`, which here would end the server.  It
        is served from a copy without that final line; the retained script
        is the one a batch GDB would run.
        """
        if self.process is None or self.process.poll() is not None:
            self.stop()
            self.start()
        script = Path(self.cwd, script)
        lines = script.read_text().splitlines()
        while lines and lines[-1].strip() in ('', 'quit'):
            lines.pop()
        if any(line.strip() == 'quit' for line in lines):
            raise RuntimeError('a served debugger script may quit only at its end')
        served = self.directory / 'session.gdb'
        served.write_text('\n'.join(lines) + '\n')
        request = {'elf': str(Path(self.cwd, elf)), 'script': str(served), 'log': str(log),
                   'cwd': str(self.cwd)}
        try:
            self.requests.write(json.dumps(request) + '\n')
            reply = self.reply(time.monotonic() + timeout)
        except (OSError, TimeoutError):
            self.stop()
            raise
        return reply['ok']

    def reply(self, deadline):
        while b'\n' not in self.pending:
            if self.process.poll() is not None:
                raise OSError('GDB exited during a session')
            if time.monotonic() > deadline:
                raise TimeoutError('GDB session timed out')
            try:
                chunk = os.read(self.replies, 4096)
            except BlockingIOError:
                chunk = None
            if chunk:
                self.pending += chunk
            else:
                time.sleep(.002)
        line, self.pending = self.pending.split(b'\n', 1)
        return json.loads(line)


def serve(gdb=None):
    """The loop GDB runs.  `gdb` is GDB's own module unless a control fakes it."""
    import __main__
    if gdb is None:
        import gdb

    pristine = dict(vars(__main__))
    gdb.execute('set pagination off')
    gdb.execute('set confirm off')
    requests = open(os.environ['LANDIN_GDB_REQUESTS'])
    replies = open(os.environ['LANDIN_GDB_REPLIES'], 'w', buffering=1)
    for line in requests:
        job = json.loads(line)
        namespace = vars(__main__)
        namespace.clear()
        namespace.update(pristine)
        for command in ('delete breakpoints', 'disconnect'):
            try:
                gdb.execute(command, to_string=True)
            except gdb.error:
                pass
        #  A batch GDB ran in the session's own directory, and scripts name
        #  files relative to it.
        gdb.execute('cd ' + job['cwd'], to_string=True)
        gdb.execute('set logging file ' + job['log'])
        gdb.execute('set logging overwrite on')
        gdb.execute('set logging redirect on')
        gdb.execute('set logging enabled on')
        ok = True
        try:
            gdb.execute('file ' + job['elf'])
            gdb.execute('source ' + job['script'])
        except gdb.error as error:
            ok = False
            gdb.write('Error in debugger session: %s\n' % error, gdb.STDERR)
        finally:
            gdb.execute('set logging enabled off')
        replies.write(json.dumps({'ok': ok}) + '\n')


if __name__ == '__main__':
    serve()
