#!/usr/bin/env python3
"""Prepare a Pico 2 boot or recovery UF2 without accessing a board.

Copy the result onto BOOTSEL storage only with the Pico 2 off the cascade.
This tool never opens a debug probe. The family identifier is pico-sdk
2.2.0's RP2350_ARM_S or RP2350_RISCV; the payload is the ELF's flash
load segments. The default preserves the Arm recovery invocation.
"""
import argparse
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common

# pico-sdk 2.2.0, src/common/boot_uf2_headers/include/boot/uf2.h:
# SHA-256 c8dcf52331974b5d397a135f4e44fb318f9ea5172eaafcb3195ae706ee1cefa0.
# Its boot_picobin_headers/include/boot/picobin.h supplies IMAGE_TYPE bits:
# SHA-256 b1d05a8e0baf252c5a07b28d5515c2f9bfcc697f3a419023cada73d7558a50a0.
FAMILY = 0xe48bff59
FAMILIES = {'arm': FAMILY, 'hazard3': 0xe48bff5a}
FLASH, FLASH_END = 0x10000000, 0x10400000
IMAGE_DEF = (0xffffded3, 0x10210142, 0x000001ff, 0, 0xab123579)
RISCV_IMAGE_DEF = (0xffffded3, 0x11010142, 0x000001ff, 0, 0xab123579)


def convert(elf, architecture='arm'):
    common.require(architecture in FAMILIES, 'unknown Pico 2 UF2 architecture')
    arm = architecture == 'arm'
    data = Path(elf).read_bytes()
    headers, programs = common._elf32_tables(data)
    common.require(struct.unpack_from('<HH', data, 16) == (2, 40 if arm else 243),
                   'recovery ELF is not a %s executable' % ('Arm' if arm else 'RISC-V'))
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
    common.require(vectors[3] == (FLASH if arm else FLASH + 512) and vectors[5] == 68 * 4,
                   'recovery vectors are not 68 words at the Pico 2 architecture vector origin')
    common.require(block[3] == vectors[3] + vectors[5] and block[5] == 20
                   and block[3] + block[5] <= FLASH + 4096,
                   'recovery IMAGE_DEF is not directly after vectors in the first 4 KiB')
    expected = struct.pack('<5I', *(IMAGE_DEF if arm else RISCV_IMAGE_DEF))
    common.require(data[block[4]:block[4] + block[5]] == expected,
                   'recovery IMAGE_DEF is not the minimum %s RP2350 block' % architecture)
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
    entry = struct.unpack_from('<I', data, 24)[0]
    if arm:
        stack, reset = struct.unpack_from('<2I', data, vectors[4])
        common.require(0x20000000 < stack <= 0x20082000 and stack % 8 == 0,
                       'recovery vectors have no aligned Pico 2 initial stack')
        common.require(reset & 1 and FLASH <= (reset & ~1) < FLASH_END
                       and (reset & ~1) in memory and (reset & ~1) + 1 in memory,
                       'recovery reset vector is not loaded Thumb code in flash')
        common.require(entry == reset, 'recovery ELF entry differs from its reset vector')
    else:
        common.require(entry % 2 == 0 and entry in memory and entry + 1 in memory,
                       'recovery RISC-V ELF entry is not loaded flash code')
        common.require(all(FLASH + i in memory for i in range(4)),
                       'recovery RISC-V image has no flash entry word')
        word = int.from_bytes(bytes(memory[FLASH + i] for i in range(4)), 'little')
        target = jal_target(word, FLASH)
        common.require(entry == FLASH and target is not None
                       and target in memory and target + 1 in memory,
                       'recovery RISC-V flash entry is not a jump to loaded flash code at the ELF entry')
        for index, word in enumerate(struct.unpack_from('<68I', data, vectors[4])):
            target = jal_target(word, vectors[3] + index * 4)
            common.require(target is not None and target in memory and target + 1 in memory,
                           'recovery RISC-V trap slot %d does not jump to loaded flash code' % index)
    pages = sorted({address & ~255 for address in memory})
    blocks = []
    for number, page in enumerate(pages):
        payload = bytes(memory.get(page + offset, 0) for offset in range(256))
        header = struct.pack('<8I', 0x0a324655, 0x9e5d5157, 0x2000,
                             page, 256, number, len(pages), FAMILIES[architecture])
        blocks.append(header + payload + bytes(220) + struct.pack('<I', 0x0ab16f30))
    return b''.join(blocks)


def jal_target(word, address):
    """Decode only JAL x0, the ROM entry and this port's trap slots."""
    if word & 0xfff != 0x06f:
        return None
    offset = (((word >> 31) & 1) << 20 | ((word >> 21) & 0x3ff) << 1
              | ((word >> 20) & 1) << 11 | ((word >> 12) & 0xff) << 12)
    return (address + offset - ((1 << 21) if offset & (1 << 20) else 0)) & 0xffffffff


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('elf', type=Path)
    parser.add_argument('uf2', type=Path)
    parser.add_argument('--architecture', choices=FAMILIES, default='arm')
    args = parser.parse_args()
    image = convert(args.elf, args.architecture)
    with args.uf2.open('xb') as output:
        output.write(image)
    print('%s: %d UF2 blocks; Pico 2 recovery must be off the cascade' %
          (args.uf2, len(image) // 512))


if __name__ == '__main__':
    main()
