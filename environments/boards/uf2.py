#!/usr/bin/env python3
"""Prepare a Pico 2 Arm recovery UF2 without accessing a board.

Copy the result onto BOOTSEL storage only with the Pico 2 off the cascade.
This tool never opens a debug probe. The family identifier is pico-sdk
2.2.0's RP2350_ARM_S; the payload is the ELF's flash load segments.
"""
import argparse
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common

FAMILY = 0xe48bff59


def convert(elf):
    data, sections = common.elf_sections(elf)
    common.require('.embedded_block' in sections, 'recovery ELF has no RP2350 image block')
    common.require(data[18:20] == struct.pack('<H', 40), 'recovery ELF is not Arm')
    memory = {}
    for address, body, _ in common.elf_segments(elf):
        if not body:
            continue
        common.require(0x10000000 <= address and address + len(body) <= 0x10400000,
                       'recovery segment is outside Pico 2 flash')
        for offset, byte in enumerate(body):
            common.require(address + offset not in memory, 'overlapping recovery segments')
            memory[address + offset] = byte
    pages = sorted({address & ~255 for address in memory})
    common.require(pages and pages[0] == 0x10000000, 'recovery image does not start at flash origin')
    blocks = []
    for number, page in enumerate(pages):
        payload = bytes(memory.get(page + offset, 0) for offset in range(256))
        header = struct.pack('<8I', 0x0a324655, 0x9e5d5157, 0x2000,
                             page, 256, number, len(pages), FAMILY)
        blocks.append(header + payload + bytes(220) + struct.pack('<I', 0x0ab16f30))
    return b''.join(blocks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('elf', type=Path)
    parser.add_argument('uf2', type=Path)
    args = parser.parse_args()
    image = convert(args.elf)
    with args.uf2.open('xb') as output:
        output.write(image)
    print('%s: %d UF2 blocks; Pico 2 recovery must be off the cascade' %
          (args.uf2, len(image) // 512))


if __name__ == '__main__':
    main()
