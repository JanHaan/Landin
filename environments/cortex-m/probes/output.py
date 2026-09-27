# Runs inside Renode's IronPython, first in every script run.py writes.  The
# script's own output goes to the file LANDIN_RENODE_OUTPUT names, a stream
# with one writer: the console is shared with Renode's logger thread, which
# can write in the middle of a line the script prints.
import sys
from System import Environment


class Output(object):
    def __init__(self, path):
        self.file = open(path, 'w')

    def write(self, text):
        self.file.write(text)
        self.file.flush()

    def flush(self):
        self.file.flush()


sys.stdout = Output(Environment.GetEnvironmentVariable('LANDIN_RENODE_OUTPUT'))
