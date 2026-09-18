"""Fail-closed selection of the supported ELF32 Cortex source artifacts.

No target read is performed, including through pointers to device registers.
This is build matching, not an authenticity or hostile-modification guarantee.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Image:
    def __init__(self, path):
        self.data = Path(path).read_bytes()
        data = self.data
        require(len(data) >= 52 and data[:7] == b'\x7fELF\x01\x01\x01',
                'expected little-endian ELF32')
        h = struct.unpack_from('<16sHHIIIIIHHHHHH', data)
        require(h[1:4] == (2, 40, 1) and h[8:10] == (52, 32)
                and h[11] == 40 and 0 < h[12] < 65535 and h[13] < h[12],
                'unsupported Cortex ELF headers')
        require(h[7] == 0x05000200, 'expected EABI5 soft-float firmware')
        self.entry = h[4]
        require(self.entry & 1 and self.entry < 32768, 'invalid firmware entry')
        require(h[5] + 32*h[10] <= len(data) and h[6] + 40*h[12] <= len(data),
                'truncated ELF table')
        self.loads = []
        self.load_ranges = []
        for i in range(h[10]):
            kind, offset, vma, lma, size, extent, flags, align = struct.unpack_from(
                '<8I', data, h[5]+32*i)
            require(size <= extent and offset+size <= len(data), 'invalid ELF segment')
            if kind == 1:
                require((vma < 32768 and vma+extent <= 32768) or
                        (0x20000000 <= vma and vma+extent <= 0x20003000),
                        'load segment exceeds firmware map')
                require(not size or lma+size <= 32768, 'load image exceeds flash')
                require(size or not extent or lma == vma, 'invalid zero-fill LMA')
                self.loads.append(dict(vma=vma, lma=lma, size=size, extent=extent,
                                       flags=flags, sha256=digest(data[offset:offset+size])))
                self.load_ranges.append((offset,offset+size))
        raw = [struct.unpack_from('<10I', data, h[6]+40*i) for i in range(h[12])]
        names = raw[h[13]]
        strings = self.bytes(names[4], names[5])
        self.sections = {}
        for row in raw[1:]:
            name_at, kind, flags, address, offset, size, link, info, align, entry = row
            require(name_at < len(strings), 'invalid ELF section name')
            end = strings.find(b'\0', name_at)
            require(end >= 0, 'unterminated ELF section name')
            name = strings[name_at:end].decode('ascii')
            require(name not in self.sections, 'duplicate ELF section')
            payload = b'' if kind == 8 else self.bytes(offset, size)
            self.sections[name] = dict(kind=kind, flags=flags, address=address,
                size=size, alignment=align, sha256=digest(payload), payload=payload)
            if name.startswith('.debug') or name == '.landin_id':
                require(flags & 2 == 0, 'debug metadata is allocated')
                require(not any(size and offset < high and offset+size > low
                                for low,high in self.load_ranges if high > low),
                        'debug metadata overlaps a load image')
        require(self.loads, 'ELF has no load image')

    def bytes(self, offset, size):
        require(offset+size <= len(self.data), 'truncated ELF section')
        return self.data[offset:offset+size]

    def loaded_identity(self):
        return self.entry, self.loads

    def resources(self):
        flash = max(s['lma']+s['size'] for s in self.loads if s['size'])
        ram = max((s['vma']+s['extent'] for s in self.loads
                   if s['vma'] >= 0x20000000), default=0x20000000)-0x20000000
        sections = {n:{k:v for k,v in s.items() if k != 'payload'}
                    for n,s in self.sections.items()}
        return dict(flash_load_extent=flash, static_ram_extent=ram,
                    flash_payload_bytes=sum(s['size'] for s in self.loads),
                    ram_segment_bytes=sum(s['extent'] for s in self.loads
                                          if s['vma'] >= 0x20000000),
                    stack_reservation=4096, flash_remaining=32768-flash,
                    nonloadable_debug_bytes=sum(s['size'] for n,s in sections.items()
                                               if n.startswith('.debug')),
                    nonloadable_identity_bytes=sections.get('.landin_id', {}).get('size', 0),
                    loads=self.loads, sections=sections)


def verify(executable, symbols, table, assembly, source_root):
    running, debug = Image(executable), Image(symbols)
    require(running.loaded_identity() == debug.loaded_identity(),
            'executable and debugger load images differ')
    for name in ('.debug_info', '.debug_abbrev', '.debug_line', '.debug_frame',
                 '.landin_id'):
        require(name in debug.sections and debug.sections[name]['size'],
                'missing Cortex debug section: '+name)
    mapping = json.loads(Path(table).read_text(encoding='ascii'))
    require('.landin_id' in running.sections and
            running.sections['.landin_id']['payload'] == debug.sections['.landin_id']['payload'],
            'executable and debugger build identities differ')
    require(debug.sections['.landin_id']['payload'].decode('ascii')
            == mapping['build_id'], 'debug/source identity mismatch')
    require(digest(Path(assembly).read_bytes()) == mapping['assembly_sha256'],
            'assembly/source identity mismatch')
    files = mapping['files']
    require(files and len({f['file_id'] for f in files}) == len(files),
            'missing or duplicate source identities')
    for entry in files:
        path = Path(os.fsdecode(bytes.fromhex(entry['path_hex'])))
        if not path.is_absolute():
            path = Path(source_root)/path
        require(digest(path.read_bytes()) == entry['source_sha256'],
                'stale source snapshot: '+str(path))
    return dict(contract='Cortex lines/functions; no source variables or types',
                executable_sha256=digest(running.data), symbols_sha256=digest(debug.data),
                build_id=mapping['build_id'], source_files=len(files),
                resources=debug.resources())


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('executable', type=Path)
    p.add_argument('--symbols', type=Path, required=True)
    p.add_argument('--sources', type=Path, required=True)
    p.add_argument('--assembly', type=Path, required=True)
    p.add_argument('--source-root', type=Path, required=True)
    a = p.parse_args()
    try:
        print(json.dumps(verify(a.executable, a.symbols, a.sources, a.assembly,
                                a.source_root), indent=2))
    except (ValueError, OSError, KeyError, TypeError, struct.error) as e:
        p.error(str(e))


if __name__ == '__main__':
    main()
