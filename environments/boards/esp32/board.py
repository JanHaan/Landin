#!/usr/bin/env python3
"""Run the ESP32 board port from SRAM by default, with a verified warm entry.

Explicit --mode=boot checks ROM packaging and cold startup, then restores
and verifies the USB-silent fixed image. Build on epycmicro and consume a
checksummed bundle on rigpi through environments/boards/run.py.
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import xtensa
CHIP = xtensa.ESP32

def main():
    return xtensa.main(CHIP, __doc__)

if __name__ == '__main__':
    sys.exit(main())
