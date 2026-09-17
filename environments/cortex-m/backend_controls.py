"""Independent ABI/frame and D227 controls over actual emitted M0 code."""
import argparse
import json
from pathlib import Path
from backend import build, execute
from run import Run
from setup import DEFAULT, HERE, sha, supported_host


def frame_control(run, refine, opt, spec, veneer=False):
    elf = build(run, refine, [HERE / 'probes/backend-abi.ldn'], opt, spec,
                extra=[HERE / 'probes/backend-abi.S'],
                linker=HERE / 'probes/backend-veneer.ld' if veneer else None)
    checks = [
        'break cm_gap', 'continue', 'python', 'import gdb',
        'def v(expr): return int(gdb.parse_and_eval(expr)) & 0xffffffff',
        'entry_sp=v("$sp"); entry_lr=v("$lr"); old_fp=v("$r11")',
        'assert entry_sp % 8 == 0 and old_fp == 0',
        'assert v("$r0") == 1 and v("$r2") == 0x44332211 and v("$r3") == 0x88776655',
        'assert v("*(unsigned*)$sp") == 2', 'end',
        'stepi 4', 'python',
        'assert v("$r11") == old_fp',
        'assert v("$sp") == entry_sp-24',
        'assert v("*(unsigned*)$sp") == old_fp',
        'assert v("*(unsigned*)($sp+4)") == entry_lr', 'end',
        'stepi', 'python', 'assert v("$r11") == v("$sp")', 'end',
        'delete breakpoints', 'break cm_leaf', 'continue', 'python',
        'parent=v("$r11"); child_lr=v("$lr"); child_sp=v("$sp")',
        'assert parent != 0 and v("*(unsigned*)$r11") == 0',
        'assert child_sp % 8 == 0', 'end', 'stepi 4', 'python',
        'assert v("$r11") == parent',
        'assert v("*(unsigned*)$sp") == parent',
        'assert v("*(unsigned*)($sp+4)") == child_lr', 'end',
        'stepi', 'python', 'assert v("$r11") == child_sp-24',
        'assert v("**(unsigned**)$r11") == 0',
        'print("R650_CONSTRUCTED_FRAME_PASS")', 'end', 'delete breakpoints',
    ]
    if veneer:
        text = (run.out / 'disassembly.log').read_text()
        from run import require
        require('cm_leaf_veneer' in text, 'linker did not construct the reach control')
    execute(run, elf, 42, False, checks)


def instruction_controls(run):
    # Independent assembly uses no generated Landin instructions.
    from run import FLAGS, require
    elf = run.out / 'instructions.elf'
    run.command('assemble-instructions', [run.bin / 'arm-none-eabi-gcc', *FLAGS,
                '-Wl,-T,' + str(HERE / 'probes/backend-memory.ld') + ',--gc-sections,-Map,instructions.map',
                HERE / 'probes/backend-start.S', HERE / 'probes/backend-instructions.S', '-o', elf])
    run.command('disassembly', [run.bin / 'arm-none-eabi-objdump', '-dr', elf])
    execute(run, elf, 42, False)
    illegal = {
        'later-thumb': 'movw r0, #1', 'exclusive': 'ldrex r0, [r1]',
        'float': 'vadd.f32 s0, s1, s2', 'high-base': 'ldr r0, [r8]',
        'word-offset': 'ldr r0, [r1, #128]', 'half-offset': 'ldrh r0, [r1, #64]',
        'byte-offset': 'ldrb r0, [r1, #32]', 'stack-offset': 'sub sp, #512',
        'literal-reach': 'ldr r0, far\n.space 1024\n.balign 4\nfar: .word 1',
        'branch-reach': 'b far\n.space 2050\nfar: bx lr',
        'condition-reach': 'beq far\n.space 258\nfar: bx lr',
    }
    for name, body in illegal.items():
        source = run.out / (name + '.s')
        source.write_text('.syntax unified\n.cpu cortex-m0\n.thumb\n.text\n.balign 4\n' + body + '\n')
        try:
            run.command(name, [run.bin / 'arm-none-eabi-as', '-mcpu=cortex-m0', '-mthumb',
                        source, '-o', run.out / (name + '.o')])
        except RuntimeError:
            require(run.commands[-1].get('exit') == 1, 'assembler refusal was not a diagnostic')
            require('Error:' in (run.out / (name + '.log')).read_text(), 'missing encoding diagnostic')
        else:
            raise RuntimeError('independent forbidden encoding assembled: ' + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--tools', type=Path, default=DEFAULT)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--optimize', default='none')
    parser.add_argument('--specialize', default='off')
    args = parser.parse_args()
    supported_host()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    for name in ('abi', 'veneer', 'memory', 'boundaries', 'words', 'symbols',
                 'signed-multiply-trap', 'unsigned-multiply-trap', 'instructions'):
        out = args.output / name
        out.mkdir()
        run = Run(out, args.tools.resolve())
        if name in ('abi', 'veneer'):
            frame_control(run, args.refine.resolve(), args.optimize, args.specialize,
                          veneer=name == 'veneer')
        elif name == 'instructions':
            instruction_controls(run)
        else:
            source = HERE / ('probes/backend-' + name + '.ldn')
            elf = build(run, args.refine.resolve(), [source],
                        args.optimize, args.specialize)
            execute(run, elf, 42, name.endswith('-trap'))
        (out / 'result.json').write_text(json.dumps({'status': 'passed',
            'files': {str(p.relative_to(out)): sha(p) for p in out.rglob('*') if p.is_file()}}, indent=2)+'\n')
        print('DEVELOPMENT / FILTERED / NOT ACCEPTANCE: generated ' + name + ' passed', flush=True)


if __name__ == '__main__':
    main()
