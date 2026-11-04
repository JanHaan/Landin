"""Audit actual reachable instructions in every helper the emitter can request."""
import json
from pathlib import Path
import re
import subprocess

from environments.xtensa.backend import Run, ROOT, sha


def audit(output, generated, chip):
    """Resolve helper relocations, then walk exact instruction boundaries.

    Linear objdump decodes literal pools and alignment padding as optional
    F64, boolean or PIE instructions. Start at each helper entry and follow
    actual branch targets and fallthrough PCs instead. Calls are followed;
    an unresolved indirect edge or an unknown instruction fails the audit.
    """
    run = Run(output)
    source = ROOT / 'compiler/ada/src/stages/landin-targets-firmware.adb'
    expression = source.read_text().split('function Is_RV32_Helper')[1].split(';')[0]
    roots = sorted(set(re.findall(r'"(__\w+)"', expression)))
    if not roots:
        raise RuntimeError('the emitter helper root inventory is empty')
    prefix = 'xtensa-' + chip + '-elf-'
    elf = run.out / 'helpers.elf'
    run.command('link', [prefix + 'gcc', '-mabi=windowed', '-nostdlib',
        '-Wl,-T,' + str(generated / 'program.ld') + ',--gc-sections,-Map,helpers.map',
        *['-Wl,--undefined=' + name for name in roots], '-o', elf,
        generated / 'program.o', '-lgcc'])
    library = Path(run.command('library', [prefix + 'gcc', '-mabi=windowed',
                                          '-print-libgcc-file-name']).strip())
    names = run.command('symbols', [prefix + 'nm', '-n', elf])
    symbols = {name: int(address, 16) for address, _, name in
               re.findall(r'^([0-9a-f]+)\s+(\w)\s+(\S+)$', names, re.M)}
    if set(roots) - symbols.keys():
        raise RuntimeError('not every requested helper was resolved')
    run.command('linear-disassembly', [prefix + 'objdump', '-dr', elf])
    allowed = set("""
        abs add add.n addexp.s addexpm.s addi addi.n addmi and ball bbci
        beq beqi beqz beqz.n bge bgeu bgeui bgez blt bltu bltui bltz bnall
        bne bnez bnez.n bnone const.s div0.s divn.s entry extui j l32r loop
        maddn.s mkdadj.s mov.n mov.s moveqz movi movi.n movltz movnez mull
        muluh neg neg.s nexp01.s nsau or quou remu retw.n rfr saltu sll slli
        src srl srli ssai ssl ssr sub wfr xor
    """.split())
    if chip == 'esp32':
        allowed.remove('saltu')
    pending, seen = [symbols[name] for name in roots], {}
    while pending:
        pc = pending.pop()
        if pc in seen:
            continue
        arguments = [prefix + 'objdump', '-d', '--start-address=' + str(pc),
                     '--stop-address=' + str(pc + 4), str(elf)]
        result = subprocess.run(arguments, text=True, capture_output=True, timeout=30)
        if result.returncode:
            raise RuntimeError('helper instruction decoder failed: ' + result.stderr)
        match = next((m for line in result.stdout.splitlines() if
            (m := re.match(r'^([0-9a-f]+):\s+([0-9a-f]+)\s+([^\s]+)\s*(.*)', line))
            and int(m[1], 16) == pc), None)
        if match is None:
            raise RuntimeError('no decoded helper instruction at ' + hex(pc))
        word, op, operands = match.groups()[1:]
        instruction = {'pc': pc, 'bytes': word, 'mnemonic': op, 'operands': operands}
        seen[pc] = instruction
        if op not in allowed:
            raise RuntimeError('unknown or trapping helper instruction: ' + repr(instruction))
        # Source operands never use optional state. Helpers may use the
        # single precision bank/FCR/FSR, SAR and loops, which the firmware
        # interrupt wrapper preserves. Any other state needs a new audit.
        if (op.startswith(('rur', 'wur', 'rsr', 'wsr', 'f64', 'ee.', 'mula.', 'muls.'))
                or re.search(r'\bb\d+\b|\bm\d+\b', operands)):
            raise RuntimeError('helper uses unaccounted processor state: ' + repr(instruction))
        if op.startswith('ret'):
            continue
        if op in ('jx', 'callx8', 'callx0', 'callx4', 'callx12'):
            raise RuntimeError('unresolved indirect helper edge: ' + repr(instruction))
        destination = re.search(r'(?:^|,\s*)([0-9a-f]+)\s+<', operands)
        branches = op == 'j' or op.startswith(('b', 'call', 'loop'))
        if branches:
            if destination is None:
                raise RuntimeError('unresolved direct helper edge: ' + repr(instruction))
            pending.append(int(destination[1], 16))
        if op != 'j':
            pending.append(pc + len(word) // 2)
    record = {'status': 'passed', 'chip': chip, 'roots': roots,
              'root_source_sha256': sha(source),
              'input_object_sha256': sha(generated / 'program.o'),
              'library': str(library), 'library_sha256': sha(library),
              'linked_image_sha256': sha(elf),
              'decoder_argv_template': [prefix + 'objdump', '-d', '--start-address=PC',
                                        '--stop-address=PC+4', str(elf)],
              'unresolved_edges': [], 'unaccounted_processor_state': [],
              'allowed_mnemonics': sorted(allowed),
              'saved_state_used': ['AR', 'SAR', 'LCOUNT/LBEG/LEND', 'F0..F8/FCR/FSR'],
              'instructions': [seen[pc] for pc in sorted(seen)]}
    (run.out / 'reachable.json').write_text(json.dumps(record, indent=2) + '\n')
    return {'chip': chip, 'roots': roots, 'reachable_instructions': len(seen),
            'evidence': str(run.out / 'reachable.json'),
            'library_sha256': sha(library), 'linked_image_sha256': sha(elf)}
