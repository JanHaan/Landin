#!/usr/bin/env python3
"""Precise source refusals against the checked-in device interface."""
import argparse
import json
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent

CASES = {
    'read-write-only': ('import rp2040/sio\n', '_ = sio.gpio_out_set_read(sio.base)', 'L0201'),
    'write-read-only': ('import rp2040/uart0\n', 'uart0.uartfr_write(uart0.base, 0)', 'L0201'),
    'ambiguous-error-clear': ('import rp2040/uart0\n', 'uart0.uartrsr_write(uart0.base, 0)', 'L0201'),
    'alias-write': ('import rp2040/dma\n', 'dma.ch0_al1_ctrl_write(dma.base, 0)', 'L0201'),
    'metadata-directive': ('compiler.vendor_svd("RP2040")\n', '', 'L0203'),
    'eight-byte-mmio': ('', 'port: ptr u64 = ptr(0x40070000)\n    _ = compiler.volatile_load(port)', 'L0301'),
    'atomic-rmw': ('', 'port: ptr mut u32 = ptr(0x20000000)\n    _ = compiler.atomic_add(port, 1, compiler.relaxed)', 'L0301'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    records = []
    for name, (imports, body, code) in CASES.items():
        folder = args.output / name
        folder.mkdir()
        source = folder / 'main.ldn'
        source.write_text(imports+'start: () -> none =\n    '+body+'\nend start\n')
        command = [str(args.refine.resolve()), '--root='+str(HERE/'generated'),
                   '--target=cortex-m0', str(folder.resolve())]
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        (folder / 'stdout.txt').write_text(result.stdout)
        (folder / 'stderr.txt').write_text(result.stderr)
        actual = re.findall(r'error\[(L\d+)\]', result.stderr)
        records.append({'case':name, 'argv':command, 'exit':result.returncode,
                        'expected':[code], 'actual':actual, 'timeout_seconds':30})
        (args.output / 'result.json').write_text(json.dumps(records,indent=2)+'\n')
        if result.returncode != 1 or actual != [code]:
            raise RuntimeError(name+': expected '+code+', got '+repr(actual))
    print('R680_SOURCE_REFUSALS_PASS '+str(len(records)))


if __name__ == '__main__':
    main()
