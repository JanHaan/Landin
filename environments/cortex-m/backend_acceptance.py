"""Mandatory compiler-generated execution lanes, within run.py's pinned tool/evidence boundary."""
import json
from backend import build, execute as qemu
from backend_corpus import execute as corpus
from backend_controls import frame_control, instruction_controls
from backend_peripheral import execute as peripheral, dma, byte
from packed_native import PROFILES
from run import Run, require
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
    controls = []
    for opt, spec in PROFILES:
        for kind in ('abi', 'veneer', 'memory', 'boundaries', 'words', 'symbols',
                     'signed-multiply-trap', 'unsigned-multiply-trap',
                     'images', 'hole', 'dma', 'byte'):
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
            controls.append(record)
            print('cortex backend control: ' + out.name + ' passed', flush=True)
    out = root / 'independent-instructions'
    out.mkdir()
    instruction_controls(Run(out, parent.tools))
    require(sha(refine) == compiler_hash, 'compiler changed during embedded execution')
    record = {'status': 'passed', 'compiler_sha256': compiler_hash,
              'corpus_rows': len(summary['results']), 'controls': controls,
              'independent_instruction_controls': 'passed'}
    (root / 'result.json').write_text(json.dumps(record, indent=2)+'\n')
