"""Actual compiler-generated ARMv6-M instructions driving synthetic devices."""
import argparse
import json
from pathlib import Path

from backend import build
from machine import Machine
from models import EncodingPeripheral, PrototypePeripheral
from packed import TRACE
from packed_native import PROFILES
from run import Run, require
from setup import DEFAULT, HERE, sha, supported_host

def symbols(run, elf):
    text = run.command('symbols', [run.bin / 'arm-none-eabi-nm', elf])
    return {s[2]: int(s[0], 16) for line in text.splitlines() if len(s := line.split()) == 3}


def settled(run, elf, name, base, size, model):
    """Run ELF against MODEL until it is idle; return the external harness's words.

    The harness ends at `backend_done` or, after a fault, `backend_fault_done`;
    both branch to themselves, so the firmware is idle at one of them.
    """
    s = symbols(run, elf)
    with Machine(run, elf, name) as m:
        m.map(base, size, model)
        m.settle()
        pc = m.register('pc')
        require(pc in (s['backend_done'], s['backend_fault_done']),
                '%s idle at %#x, not at the harness end' % (name, pc))
        values = {'backend_fault': m.u32(s['backend_fault']),
                  'result': m.u32(s['backend_result']),
                  'r12': m.u32(s['backend_result'] + 4)}
    return s, values


def execute(run, refine, hole, optimize, specialize):
    source = HERE / ('probes/packed-cortex-hole.ldn' if hole else 'probes/packed-cortex.ldn')
    elf = build(run, refine, [source], optimize, specialize)
    model = EncodingPeripheral()
    s, got = settled(run, elf, 'peripheral', 0x40030000, 0x20, model)
    require(got['backend_fault'] == (3 if hole else 0), 'backend fault status')
    require(model.trace == ('r32:4:0000009b' if hole else TRACE),
            'backend trace differs: ' + model.trace)
    if not hole:
        require(got['result'] == 0x640 and got['r12'] == 0, 'backend result')
        require(model.normal == 0xa50000d0 and model.command == 0x51 and model.pending == 0xf1
                and model.count == 0xffff and model.ones == 0xffffff51, 'backend device images')
    (run.out / 'peripheral-trace.txt').write_text(model.trace + '\n')
    return {'source_sha256': sha(source), 'execution': 'compiler Cortex-M0 / synthetic QEMU window',
            'optimize': optimize, 'specialize': specialize, 'hole': hole, 'status': 'passed'}


def byte(run, refine, optimize, specialize):
    source = HERE / 'probes/backend-byte.ldn'
    elf = build(run, refine, [source], optimize, specialize)
    model = EncodingPeripheral()
    s, got = settled(run, elf, 'byte', 0x40030000, 0x20, model)
    require(got['backend_fault'] == 0 and got['result'] == 42 and got['r12'] == 0, 'byte result')
    require(model.trace == 'r8:18:a5;r8:18:00;w8:19:41;w8:1a:02;r8:1a:f1',
            'byte trace differs: ' + model.trace)
    require(model.byte_command == 0x41 and model.byte_pending == 0xf1, 'byte device images')
    (run.out / 'byte-trace.txt').write_text(model.trace + '\n')
    return {'status': 'passed', 'optimize': optimize, 'specialize': specialize,
            'source_sha256': sha(source)}


def dma(run, refine, optimize, specialize):
    elf = build(run, refine, [HERE / 'probes/backend-dma.ldn'], optimize, specialize)
    s = symbols(run, elf)
    model = PrototypePeripheral()
    with Machine(run, elf, 'dma') as m:
        m.map(0x40020000, 0x7000, model)
        m.settle()
        require(m.u32(s['backend_result']) == 0, 'ready: result')
        require(model.transfers == 0 and model.errors == 0, 'ready: transfers')
        require(model.remaining == 4 and model.configuration == 0x80000401, 'ready: descriptor')
        require(model.count_half_writes == 1 and model.count_word_writes == 0, 'ready: count width')
        model.feed(42)
        model.feed(43)
        m.settle()
        require(m.u32(s['backend_result']) == 0, 'half: result')
        require(model.transfers == 2 and model.remaining == 2, 'half: model')
        model.feed(44)
        model.feed(45)
        m.settle()
        require(m.u32(s['backend_result']) == 174 and m.u32(s['backend_result'] + 4) == 0,
                'done: result')
        require(m.u32(s['backend_fault']) == 0, 'done: fault')
    require(model.transfers == 4 and model.errors == 0 and model.remaining == 0, 'done: model')
    require(model.configuration == 0x80000400, 'done: configuration')
    require(model.count_half_reads == 1 and model.count_word_reads == 0, 'done: count reads')
    require(model.count_half_writes == 1 and model.count_word_writes == 0, 'done: count writes')
    (run.out / 'dma-trace.txt').write_text(
        'half-write=1;half-read=1;word-count-access=0;transfers=4;sum=174\n')
    return {'status': 'passed', 'optimize': optimize, 'specialize': specialize,
            'source_sha256': sha(HERE / 'probes/backend-dma.ldn')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--all-profiles', action='store_true')
    args = parser.parse_args()
    supported_host()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    results = []
    for opt, spec in PROFILES if args.all_profiles else PROFILES[:1]:
        for hole in (False, True):
            out = args.output / f'{opt}-{spec}-{"hole" if hole else "images"}'
            out.mkdir()
            result = execute(Run(out, args.tools.resolve()), args.refine.resolve(), hole, opt, spec)
            result['artifacts'] = {str(p.relative_to(out)): sha(p) for p in sorted(out.rglob('*')) if p.is_file()}
            results.append(result)
            print('DEVELOPMENT / FILTERED / NOT ACCEPTANCE: ' + out.name + ' passed', flush=True)
        out = args.output / f'{opt}-{spec}-dma'
        out.mkdir()
        result = dma(Run(out, args.tools.resolve()), args.refine.resolve(), opt, spec)
        result['artifacts'] = {str(p.relative_to(out)): sha(p) for p in sorted(out.rglob('*')) if p.is_file()}
        results.append(result)
        print('DEVELOPMENT / FILTERED / NOT ACCEPTANCE: ' + out.name + ' passed', flush=True)
        out = args.output / f'{opt}-{spec}-byte'
        out.mkdir()
        result = byte(Run(out, args.tools.resolve()), args.refine.resolve(), opt, spec)
        result['artifacts'] = {str(p.relative_to(out)): sha(p) for p in sorted(out.rglob('*')) if p.is_file()}
        results.append(result)
        print('DEVELOPMENT / FILTERED / NOT ACCEPTANCE: ' + out.name + ' passed', flush=True)
    (args.output / 'result.json').write_text(json.dumps(results, indent=2)+'\n')


if __name__ == '__main__':
    main()
