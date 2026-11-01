"""Mandatory compiler-generated execution lanes, within run.py's pinned tool/evidence boundary."""
from concurrent.futures import ThreadPoolExecutor
import json
from backend import build, derived, execute as qemu
from backend_corpus import LANES as CORPUS_LANES, execute as corpus
from backend_controls import frame_control, instruction_controls
from backend_peripheral import execute as peripheral, dma, byte
from packed_native import PROFILES
from run import Run, require, workers
from setup import HERE, sha


def execute(parent, refine):
    root = parent.out / 'backend'
    root.mkdir()
    refine = refine.resolve(strict=True)
    compiler_hash = sha(refine)
    parent.command('backend-refine-identity', [refine, '--identify'])
    corpus_out = root / 'corpus'
    corpus_out.mkdir()
    summary = corpus(corpus_out, parent.tools, refine)
    def control(item):
        opt, spec, kind = item
        out = root / (kind + '-' + opt + '-' + spec)
        out.mkdir()
        run = Run(out, parent.tools)
        if kind in ('abi', 'veneer'):
            frame_control(run, refine, opt, spec, veneer=kind == 'veneer')
        elif kind in ('memory', 'boundaries', 'words', 'symbols',
                      'signed-multiply-trap', 'unsigned-multiply-trap'):
            elf = build(run, refine, [HERE / ('probes/backend-' + kind + '.ldn')], opt, spec)
            qemu(run, elf, 42, kind.endswith('-trap'))
        elif kind == 'dma':
            dma(run, refine, opt, spec)
        elif kind == 'byte':
            byte(run, refine, opt, spec)
        else:
            peripheral(run, refine, kind == 'hole', opt, spec)
        record = {'kind': kind, 'optimize': opt, 'specialize': spec, 'status': 'passed',
                  'artifacts': {str(p.relative_to(out)): sha(p)
                                for p in sorted(out.rglob('*')) if p.is_file()}}
        (out / 'result.json').write_text(json.dumps(record, indent=2)+'\n')
        return out.name, record

    work = [(opt, spec, kind) for opt, spec in PROFILES
            for kind in ('abi', 'veneer', 'memory', 'boundaries', 'words', 'symbols',
                         'signed-multiply-trap', 'unsigned-multiply-trap',
                         'images', 'hole', 'dma', 'byte')]
    controls = []
    #  Independent programs on independent emulators; a failure propagates
    #  from `map` in inventory order, as the sequential loop raised it.
    with ThreadPoolExecutor(max_workers=workers()) as pool:
        for name, record in pool.map(control, work):
            controls.append(record)
            print('cortex backend control: ' + name + ' passed', flush=True)
    out = root / 'independent-instructions'
    out.mkdir()
    run = Run(out, parent.tools)
    instruction_controls(run, derived(run, refine))
    require(sha(refine) == compiler_hash, 'compiler changed during embedded execution')
    record = {'status': 'passed', 'compiler_sha256': compiler_hash,
              'corpus_rows': len(summary['results']), 'controls': controls,
              'independent_instruction_controls': 'passed'}
    (root / 'result.json').write_text(json.dumps(record, indent=2)+'\n')


def execute_lane(parent, refine, lane):
    """The whole inventory alone on one emulator lane of backend_corpus.LANES,
    run.py's lane of the same name: QEMU's mps2-an505 at armv8-m.main
    (D605-D607), or mps2-an500 at armv7e-m with its float unit (D615-D619).
    Every row's verdict there, its executed images held to what the lane's
    level and unit select."""
    root = parent.out / lane
    root.mkdir()
    refine = refine.resolve(strict=True)
    compiler_hash = sha(refine)
    parent.command(lane + '-refine-identity', [refine, '--identify'])
    corpus_out = root / 'corpus'
    corpus_out.mkdir()
    summary = corpus(corpus_out, parent.tools, refine, lane=lane)
    require(sha(refine) == compiler_hash, 'compiler changed during embedded execution')
    (root / 'result.json').write_text(json.dumps({
        'status': 'passed', 'compiler_sha256': compiler_hash, 'lane': lane,
        'level': CORPUS_LANES[lane], 'corpus_rows': len(summary['results'])}, indent=2) + '\n')
