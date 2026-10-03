#!/usr/bin/env python3
"""Exercise the native input channel with ready, ended, and invalid stdin."""
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CHANNEL = ROOT / "compiler/ada/src/platform/landin_channel.c"
HARNESS = r"""
#include <unistd.h>

long landin_channel_read(char *into, long length);
int landin_channel_pending(void);

int main(void)
{
    int ends[2];
    char byte;

    if (pipe(ends) != 0 || dup2(ends[0], STDIN_FILENO) < 0)
        return 1;
    close(ends[0]);
    if (landin_channel_pending() != 0)
        return 2;
    if (write(ends[1], "x", 1) != 1 || landin_channel_pending() != 1)
        return 3;
    if (landin_channel_read(&byte, 1) != 1 || byte != 'x')
        return 4;
    close(ends[1]);
    if (landin_channel_pending() != 1 || landin_channel_read(&byte, 1) != 0)
        return 5;
    close(STDIN_FILENO);
    if (landin_channel_pending() != -1 || landin_channel_read(&byte, 1) != -1)
        return 6;
    return 0;
}
"""


class ChannelPending(unittest.TestCase):
    def test_stdin_states(self):
        with tempfile.TemporaryDirectory(prefix="landin-channel-") as scratch:
            source = Path(scratch) / "main.c"
            binary = Path(scratch) / "channel-test"
            source.write_text(HARNESS)
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                            str(CHANNEL), str(source), "-o", str(binary)],
                           check=True)
            result = subprocess.run([str(binary)], stdin=subprocess.DEVNULL,
                                    check=False)
            self.assertEqual(result.returncode, 0,
                             "channel harness failed at step %d" % result.returncode)


if __name__ == "__main__":
    unittest.main()
