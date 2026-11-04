#!/usr/bin/env python3
"""Native Xtensa controls and the shared freestanding fixture inventory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / 'environments/cortex-m'))
from backend_corpus import PROFILES, SPECIALIZATION_PROFILES, inventory  # noqa: E402
from backend import metadata  # noqa: E402
from remote import observe  # noqa: E402
from run import workers  # noqa: E402

CONTROLS = ROOT / 'compiler/tests/xtensa'
INVENTORY = ROOT / 'compiler/tests/cortex-m/corpus.json'
COUNTERPARTS = ROOT / 'compiler/tests/cortex-m/counterparts.json'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def disposition(row, target='xtensa'):
    """The sole inventory's target override, retaining all other row facts."""
    return {**row, **row.get('targets', {}).get(target, {})}


class Run:
    def __init__(self, output):
        self.out = output
        output.mkdir(parents=True, exist_ok=False)
        self.commands = []

    def command(self, name, arguments, timeout=60, expected=0):
        command = [str(part) for part in arguments]
        try:
            result = subprocess.run(command, cwd=self.out, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    timeout=timeout)
        except subprocess.TimeoutExpired as error:
            captured = error.stdout or b''
            if isinstance(captured, bytes):
                captured = captured.decode('utf-8', errors='replace')
            (self.out / (name + '.log')).write_text(captured)
            self.commands.append({'name': name, 'command': command, 'exit': 'timeout'})
            (self.out / 'commands.json').write_text(json.dumps(self.commands, indent=2) + '\n')
            raise RuntimeError(name + ' timed out') from error
        (self.out / (name + '.log')).write_text(result.stdout)
        self.commands.append({'name': name, 'command': command, 'exit': result.returncode})
        (self.out / 'commands.json').write_text(json.dumps(self.commands, indent=2) + '\n')
        if result.returncode != expected:
            raise RuntimeError('%s exited %d; inspect %s' %
                               (name, result.returncode, self.out / (name + '.log')))
        return result.stdout


def description(chip):
    iram, dram = (('0x4008_0000', '0x3ffb_0000') if chip == 'esp32'
                  else ('0x4037_8000', '0x3fca_8000'))
    core = 'xtensa-lx6' if chip == 'esp32' else 'xtensa-lx7'
    return '\n'.join([
        'compiler.device("xtensa-test-' + chip + '")',
        'compiler.core("' + core + '")', 'compiler.vectors(32)',
        'compiler.boot("vector-table")',
        'linker.region("IRAM", ' + iram + ', 128 * 1024, "rwx")',
        'linker.region("DRAM", ' + dram + ', 128 * 1024, "rw")',
        *['linker.place("' + part + '", "IRAM")' for part in ('vectors', 'text')],
        *['linker.place("' + part + '", "DRAM")' for part in ('rodata', 'data', 'bss')],
        'linker.place("stack", "DRAM", 16 * 1024)', ''])


def stage(run, inputs, chip):
    """Copy the entry module unchanged and add a separate status wrapper."""
    source = run.out / 'source'
    app = source / 'app'
    app.mkdir(parents=True)
    flags, files = [], []
    for part in inputs:
        if str(part).startswith('-'):
            flags.append(str(part))
        else:
            path = Path(part)
            files.extend(sorted(path.glob('*.ldn')) if path.is_dir() else [path])
    if not files:
        raise RuntimeError('the entry module has no source files')
    staged = []
    for path in files:
        destination = app / path.name
        if destination.exists():
            if destination.read_bytes() != path.read_bytes():
                raise RuntimeError('entry source basename has unequal contents: ' + path.name)
        else:
            shutil.copy2(path, destination)
            staged.append(destination)
    module = 'xtensa_lane_' + chip
    desc = source / 'descriptions' / module
    desc.mkdir(parents=True)
    (desc / 'core.ldn').write_text(description(chip))
    wrapper = (
        'import descriptions/' + module + '\n'
        'link(symbol: "_landin_xtensa_fixture_status")\n'
        'mut landin_xtensa_fixture_status: i32 = -999\n'
        'landin_xtensa_fixture_start: () -> none =\n'
        '    landin_xtensa_fixture_status = main()\n'
        # A returning firmware entry invokes a selected unreachable panic
        # handler. Stop at the source wrapper's own completion boundary,
        # after the result is stored, so a recovering handler is not called
        # a second time merely because its test has completed.
        '    landin_xtensa_fixture_stopped()\n'
        'end landin_xtensa_fixture_start\n'
        'link(symbol: "_landin_xtensa_fixture_stopped")\n'
        'landin_xtensa_fixture_stopped: () -> noreturn =\n'
        '    loop do\n'
        '    end loop\n'
        'end landin_xtensa_fixture_stopped\n')
    oracle = app / 'xtensa-oracle.ldn'
    if oracle.exists() and oracle.read_bytes() != wrapper.encode():
        raise RuntimeError('entry source basename has unequal contents: ' + oracle.name)
    oracle.write_text(wrapper)
    if oracle not in staged:
        staged.append(oracle)
    # Metadata's ordered program/with operands form the same entry module,
    # even when a with file lives in another directory. Existing import
    # roots retain their order, followed by the staged description root.
    return [*flags, '--root=' + str(source), *map(str, staged)]


def symbols(run, tool, elf):
    listing = run.command('symbols', [tool + 'nm', '-n', elf])
    return {name: int(address, 16) for address, _, name in
            re.findall(r'^([0-9a-fA-F]+)\s+(\S)\s+(\S+)$', listing, re.M)}


def build(run, refine, inputs, chip, optimize='none', specialize='off'):
    tool = 'xtensa-' + chip + '-elf-'
    staged = stage(run, inputs, chip)
    base = [refine, *staged, '--target=xtensa', '--level=xtensa-' + chip,
            '--firmware-layout=ram', '--firmware-entry=landin_xtensa_fixture_start',
            '--optimize=' + optimize, '--specialize=' + specialize]
    assembly = run.out / 'program.s'
    run.command('compile', [*base, '--emit=asm', '-o', assembly,
                           '--build-report=' + str(run.out / 'build.json')])
    script = run.out / 'program.ld'
    run.command('derive', [*base, '--emit=linker-script', '-o', script])
    obj, elf = run.out / 'program.o', run.out / 'program.elf'
    run.command('assemble', [tool + 'as', '--abi-windowed', '--auto-litpools',
                            '--longcalls', '-o', obj, assembly])
    run.command('link', [tool + 'gcc', '-mabi=windowed', '-nostdlib',
                        '-Wl,-T,' + str(script) + ',--gc-sections,-Map,program.map',
                        '-o', elf, obj, '-lgcc'])
    run.command('disassembly', [tool + 'objdump', '-dr', elf])
    library = Path(run.command('libgcc', [tool + 'gcc', '-mabi=windowed',
                                        '-print-libgcc-file-name']).strip())
    (run.out / 'helpers.json').write_text(json.dumps({
        'library': str(library), 'sha256': sha(library),
        'requested': sorted(set(re.findall(r'\bcall8 (__\w+)', assembly.read_text())))
    }, indent=2) + '\n')
    return elf, symbols(run, tool, elf)


def verify(result, expected=0, traps=False):
    values = result['values']
    count = values['_landin_firmware_trap_count']
    if traps:
        if count != 1 or values['_landin_firmware_trap_cause'] != 0:
            raise RuntimeError('the expected illegal-instruction trap was not observed')
        if values.get('trap_instruction') != '000000':
            raise RuntimeError('the trapped instruction is not the emitted ILL')
    elif count or values['_landin_xtensa_fixture_status'] != expected & 0xffffffff:
        raise RuntimeError('wrong native result: ' + repr(values))


def execute(run, refine, qemu, inputs, chip, expected=0, traps=False,
            optimize='none', specialize='off'):
    elf, named = build(run, refine, inputs, chip, optimize, specialize)
    result = observe(qemu, chip, elf, named, run.out)
    (run.out / 'observation.json').write_text(json.dumps(result, indent=2) + '\n')
    verify(result, expected, traps)
    result.update(status='passed', chip=chip, optimize=optimize, specialize=specialize,
                  compiler_sha256=sha(refine), image_sha256=sha(elf))
    (run.out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', required=True, type=Path)
    parser.add_argument('--qemu', type=Path)
    parser.add_argument('--tools', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--chip', choices=('esp32', 'esp32s3'), required=True)
    parser.add_argument('--control', action='append', default=[])
    args = parser.parse_args()
    known = {p.stem: p for p in CONTROLS.glob('*.ldn')}
    if not args.control or set(args.control) - known.keys():
        parser.error('select exact --control names: ' + ', '.join(sorted(known)))
    # Import after the shared backend module has loaded its Cortex metadata.
    from tools import Tools
    tools = Tools(args.tools, args.qemu)
    args.output.mkdir(parents=True, exist_ok=False)
    results = []
    for name in args.control:
        run = Run(args.output / name)
        if name == 'early-stop-control':
            elf, named = build(run, args.refine.resolve(), [known[name]], args.chip)
            try:
                observe(tools.qemu, args.chip, elf, named, run.out,
                        extra_breakpoint=named['_landin_xtensa_fixture_unexpected'])
            except RuntimeError as error:
                if 'unexpected guest stop PC' not in str(error):
                    raise
                record = json.loads((run.out / 'unexpected-stop.json').read_text())
                if record['values']['_landin_xtensa_fixture_status'] != 0 or record[
                        'values']['_landin_firmware_trap_count']:
                    raise RuntimeError('early-stop control did not isolate the stop-PC oracle')
                results.append({'status': 'passed', 'negative_oracle': str(error),
                                'observation': record})
            else:
                raise RuntimeError('a breakpoint before completion was accepted')
            print('FILTERED Xtensa control ' + args.chip + ' ' + name + ' rejected', flush=True)
            continue
        if name in ('break-control', 'premature-stop-control'):
            elf, named = build(run, args.refine.resolve(), [known[name]], args.chip)
            assembly = (run.out / 'program.s').read_text()
            operation = ('break 0, 0' if name == 'break-control' else
                         'movi a8, _landin_xtensa_fixture_status\n'
                         'movi a9, 0\ns32i a9, a8, 0\nj _landin_firmware_stopped')
            changed, count = re.subn(r'(?m)^nop$', operation, assembly)
            if count != 1:
                raise RuntimeError(name + ' requires exactly one source NOP')
            stem = 'break-program' if name == 'break-control' else 'premature-program'
            negative = run.out / (stem + '.s')
            negative.write_text(changed)
            prefix = 'xtensa-' + args.chip + '-elf-'
            obj, elf = run.out / (stem + '.o'), run.out / (stem + '.elf')
            run.command(stem + '-assemble', [prefix + 'as', '--abi-windowed',
                        '--auto-litpools', '--longcalls', '-o', obj, negative])
            run.command(stem + '-link', [prefix + 'gcc', '-mabi=windowed', '-nostdlib',
                        '-Wl,-T,' + str(run.out / 'program.ld') + ',--gc-sections',
                        '-o', elf, obj, '-lgcc'])
            run.command(stem + '-disassembly', [prefix + 'objdump', '-dr', elf])
            named = symbols(run, prefix, elf)
            try:
                record = observe(tools.qemu, args.chip, elf, named, run.out)
            except RuntimeError as error:
                if name != 'premature-stop-control' or str(error) != (
                        'firmware stopped before fixture completion without a trap'):
                    raise
                record = json.loads((run.out / 'unexpected-stop.json').read_text())
                if record['values']['_landin_xtensa_fixture_status'] != 0 or record[
                        'values']['_landin_firmware_trap_count']:
                    raise RuntimeError('premature stop did not isolate the completion oracle')
                reason = str(error)
            else:
                if name == 'premature-stop-control':
                    raise RuntimeError('firmware stop before completion was accepted')
                (run.out / 'observation.json').write_text(json.dumps(record, indent=2) + '\n')
                try:
                    verify(record)
                except RuntimeError as error:
                    if record['values']['_landin_xtensa_fixture_status'] != 0 or record[
                            'values']['_landin_firmware_trap_count'] != 1:
                        raise RuntimeError('BREAK did not reach the independent trap oracle')
                    reason = str(error)
                else:
                    raise RuntimeError('BREAK before completion was accepted')
            results.append({'status': 'passed', 'negative_oracle': reason,
                            'observation': record})
            print('FILTERED Xtensa control ' + args.chip + ' ' + name + ' rejected', flush=True)
            continue
        results.append(execute(run, args.refine.resolve(), tools.qemu,
                               [known[name]], args.chip,
                               expected=(37 if name == 'status-control' else
                                         (7 if args.chip == 'esp32s3' else 6)
                                         if name == 'feature-level' else 0),
                               traps=name == 'trap-control'))
        if name in ('status-control', 'trap-control'):
            try:
                verify(results[-1])
            except RuntimeError:
                results[-1]['negative_oracle'] = 'rejected when a normal zero result was required'
            else:
                raise RuntimeError('negative oracle accepted the control as an ordinary success')
        print('FILTERED Xtensa control ' + args.chip + ' ' + name + ' passed', flush=True)
    tools.finish(args.output)
    (args.output / 'result.json').write_text(json.dumps({
        'scope': 'FILTERED', 'status': 'passed', 'results': results}, indent=2) + '\n')


if __name__ == '__main__':
    main()
