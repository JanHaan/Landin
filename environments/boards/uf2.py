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
FLASH, FLASH_END = 0x10000000, 0x10400000
IMAGE_DEF = (0xffffded3, 0x10210142, 0x000001ff, 0, 0xab123579)


def convert(elf):
    data = Path(elf).read_bytes()
    headers, programs = common._elf32_tables(data)
    common.require(struct.unpack_from('<HH', data, 16) == (2, 40),
                   'recovery ELF is not an Arm executable')
    shnames = struct.unpack_from('<H', data, 50)[0]
    strings_at, strings_size = headers[shnames][4:6]
    strings = data[strings_at:strings_at + strings_size]
    sections = {}
    for header in headers:
        name_at = header[0]
        common.require(name_at < len(strings), 'invalid recovery ELF section name')
        end = strings.find(b'\0', name_at)
        common.require(end >= 0, 'unterminated recovery ELF section name')
        name = strings[name_at:end]
        common.require(name not in sections, 'duplicate recovery ELF section name')
        sections[name] = header
    common.require(b'.embedded_block' in sections, 'recovery ELF has no RP2350 image block')
    common.require(b'.isr_vector' in sections, 'recovery ELF has no vector table')
    vectors, block = sections[b'.isr_vector'], sections[b'.embedded_block']
    common.require(vectors[3] == FLASH and vectors[5] == 68 * 4,
                   'recovery vectors are not 68 words at Pico 2 flash origin')
    common.require(block[3] == FLASH + vectors[5] and block[5] == 20
                   and block[3] + block[5] <= FLASH + 4096,
                   'recovery IMAGE_DEF is not directly after vectors in the first 4 KiB')
    expected = struct.pack('<5I', *IMAGE_DEF)
    common.require(data[block[4]:block[4] + block[5]] == expected,
                   'recovery IMAGE_DEF is not the minimum Arm Secure RP2350 block')
    memory = {}
    for kind, offset, _, address, size, _, _, _ in programs:
        if kind != 1 or not size:
            continue
        common.require(FLASH <= address and address + size <= FLASH_END,
                       'recovery segment is outside Pico 2 flash')
        for index, byte in enumerate(data[offset:offset + size]):
            common.require(address + index not in memory, 'overlapping recovery segments')
            memory[address + index] = byte
    common.require(FLASH in memory, 'recovery image does not start at flash origin')
    for section in (vectors, block):
        body = data[section[4]:section[4] + section[5]]
        common.require(all(memory.get(section[3] + index) == byte
                           for index, byte in enumerate(body)),
                       'recovery vectors or IMAGE_DEF differ from flash load bytes')
    stack, reset = struct.unpack_from('<2I', data, vectors[4])
    common.require(0x20000000 < stack <= 0x20082000 and stack % 8 == 0,
                   'recovery vectors have no aligned Pico 2 initial stack')
    common.require(reset & 1 and FLASH <= (reset & ~1) < FLASH_END
                   and (reset & ~1) in memory and (reset & ~1) + 1 in memory,
                   'recovery reset vector is not loaded Thumb code in flash')
    common.require(struct.unpack_from('<I', data, 24)[0] == reset,
                   'recovery ELF entry differs from its reset vector')
    pages = sorted({address & ~255 for address in memory})
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
