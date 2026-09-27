"""Small native-runner timeout witness; never invokes a compiler or toolchain."""

import os
from pathlib import Path
import sys
import time


def main():
    marker = Path(sys.argv[1])
    child = os.fork()
    if child == 0:
        print("child ready", flush=True)
        # Past the runner's deadline, so only a child that survived the
        # timeout can write it.  Even a broken runner leaves only one short,
        # harmless child behind.
        time.sleep(4)
        marker.write_text("child survived the timeout\n")
        os._exit(0)
    time.sleep(8)
    os.waitpid(child, 0)


if __name__ == "__main__":
    main()
