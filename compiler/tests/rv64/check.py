#!/usr/bin/env python3
"""Cross-emit checked LP64D payloads, then execute on physical RISE RV64."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import resource
import shlex
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location('freebsd_checks', ROOT / 'compiler/tests/freebsd/check.py')
SHARED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHARED)
metadata, fixture_code = SHARED.metadata, SHARED.fixture_code
PROFILES, SPECIALIZED = SHARED.PROFILES, SHARED.SPECIALIZED
ABI_REQUIRED = SHARED.ABI_REQUIRED | {'lp64d-varargs', 'lp64d-integer-extension',
                                   'lp64d-main-return'}
TARGET = 'linux-rv64'
LEVELS = ('rv64gc', 'rv64gc_xtheadba')
ISA_REQUIRED = {'rv64-feature-fact', 'rv64-indexed-address', 'rv64-assembly-level'}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes():
    return {str(p.relative_to(ROOT)): sha(p) for directory in ('compiler/tests', 'core', 'hosted', 'platform', 'examples')
            for p in sorted((ROOT / directory).rglob('*'))
            if p.is_file() and '__pycache__' not in p.parts}


def select(kind):
    directory = 'runtime' if kind == 'isa' else kind
    selected = [(p.parent, metadata(p)) for p in
                sorted((ROOT / 'compiler/tests/fixtures' / directory).glob('*/fixture.meta'))
                if TARGET in metadata(p)['targets'].split(', ')]
    if kind == 'isa':
        selected = [(p, m) for p, m in selected if p.name in ISA_REQUIRED]
    require(selected, kind + ': empty fixture selection')
    names = {p.name for p, _ in selected}
    if kind == 'abi':
        require(all(m.get('c-sources', '').strip() for _, m in selected),
                'ABI fixture lacks an independently compiled C peer')
        require(ABI_REQUIRED <= names, 'ABI coverage missing: ' + str(ABI_REQUIRED - names))
    elif kind == 'isa':
        require(ISA_REQUIRED <= names, 'ISA coverage missing: ' + str(ISA_REQUIRED - names))
    else:
        require('assembly-operands' in names, 'runtime lane lacks integer assembly operands')
    return selected


def work_items(args):
    selected = select(args.kind)
    if args.case:
        require(set(args.case) <= {p.name for p, _ in selected}, 'unknown exact case')
        selected = [(p, m) for p, m in selected if p.name in args.case]
    return [(p, m, o, s, level) for p, m in selected
            for level in (LEVELS if args.kind == 'isa' else (None,))
            for o, s in PROFILES + (SPECIALIZED if m.get('profiles') == 'specialization' else [])]


class Lane(SHARED.Lane):
    def __init__(self, args):
        self.args, self.output = args, args.output.resolve()
        self.bundle = self.output / 'bundle'
        self.bundle.mkdir()
        self.target = TARGET
        self.cc = [args.cc, '-mabi=lp64d', '-march=rv64gc', '-no-pie', '-Wa,-L']
        self.driver = self.output / 'rv64-gcc'
        self.driver.write_text('#!/bin/sh\nexec ' + shlex.join(self.cc) + ' "$@"\n')
        self.driver.chmod(0o755)

    def build(self, base, meta, optimize, specialize, level=None):
        label = '-'.join((base.parent.name, base.name, optimize, specialize, level or 'default'))
        executable = self.bundle / label
        source = base / meta['program']
        sources = (['--root=' + str((base / meta['root']).resolve()), str(source.parent)]
                   if 'root' in meta else [str(source)])
        sources += [str(base / p.strip()) for p in meta.get('with', '').split(',') if p.strip()]
        argv = [self.args.refine.resolve(), '--target=' + TARGET,
                '--optimize=' + optimize, '--specialize=' + specialize,
                *(['--level=' + level] if level else []), *shlex.split(meta.get('args', '')), *sources]
        assembly = Path(str(executable) + '.s')
        self.command([*argv, '--emit=asm', '-o', assembly], label + '-emit')
        objects, peers = [], []
        cargs = shlex.split(meta.get('c-args', ''))
        compile_args = [a for a in cargs if not a.startswith('-Wl,') and not a.startswith('-l')]
        for index, name in enumerate(meta.get('c-sources', '').split(',')):
            if not name.strip():
                continue
            obj = Path(str(executable) + f'-peer-{index}.o')
            self.command([*self.cc, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                          *compile_args, '-c', base / name.strip(), '-o', obj], label + f'-peer-{index}')
            objects.append(obj)
            peers.append({'source': name.strip(), 'source_sha256': sha(base / name.strip()), 'object_sha256': sha(obj)})
        if meta.get('c-sources'):
            self.command([*self.cc, '-march=' + (level or LEVELS[0]), assembly, *objects, *cargs,
                          '-o', executable], label + '-link')
        else:
            # The compiler's toolchain adapter owns linker.library discovery,
            # level arguments and startup policy; reuse that boundary here.
            self.command([*argv, '--toolchain=' + str(self.driver), '--emit=exe', '-o', executable],
                         label + '-link')
        return {'case': str(base.relative_to(ROOT / 'compiler/tests/fixtures')),
                'label': label, 'optimize': optimize, 'specialize': specialize, 'level': level,
                'executable_sha256': sha(executable), 'c_peers': peers, 'meta': meta}

    def build_debugger(self):
        source = HERE / 'debug.ldn'
        lines = {needle: next(i for i, line in enumerate(source.read_text().splitlines(), 1)
                              if needle in line) for needle in ('result = local + 1', 'result = inner(local)', 'result = ready')}
        results = []
        for optimize, specialize in PROFILES:
            label = 'debug-' + optimize + '-' + specialize
            executable = self.bundle / label
            self.command([self.args.refine.resolve(), '--target=' + TARGET,
                          '--toolchain=' + str(self.driver), '--debug=full', '--emit=exe',
                          '--optimize=' + optimize, '--specialize=' + specialize,
                          source, '-o', executable], label + '-build')
            results.append({'label': label, 'lines': lines, 'executable_sha256': sha(executable)})
        return results

    def instructions(self, results):
        for result in results:
            if result['case'] != 'runtime/rv64-indexed-address':
                continue
            executable = self.bundle / result['label']
            listing = self.command([self.args.objdump, '-d', executable], result['label'] + '-disassembly').decode()
            symbols = self.command([self.args.objdump, '-t', executable], result['label'] + '-symbols').decode()
            code = fixture_code(symbols, listing, {'indexed'})
            extended = result['level'] == LEVELS[1]
            require(bool(re.search(r'\bth\.addsl\b', code)) == extended,
                    result['label'] + ': wrong indexed-address instruction selection')
            if not extended:
                require(re.search(r'\bsll(?:i)?\b', code) and re.search(r'\badd\b', code),
                        result['label'] + ': baseline lacks shift/add sequence')

    def assembler_control(self):
        fixture = HERE / 'level-block.ldn'
        assembly = self.output / 'assembly-level.s'
        for level in LEVELS:
            self.command([self.args.refine.resolve(), '--target=' + TARGET, '--level=' + level,
                          '--emit=asm', fixture, '-o', assembly], level + '-assembly-emit')
            self.command([*self.cc, '-march=' + level, '-c', assembly, '-o', self.output / 'assembly-level.o'],
                         level + '-assembly-control', expected=1 if level == LEVELS[0] else 0)
            if level == LEVELS[0]:
                refusal = (self.output / (level + '-assembly-control.log')).read_text()
                require('xtheadba' in refusal.lower() and 'th.addsl' in refusal.lower(),
                        'baseline assembler refusal did not identify the extension instruction')

    def prepare(self):
        self.command([self.args.cc, '--version'], 'cross-toolchain-version')
        self.command([self.args.objdump, '--version'], 'cross-objdump-version')
        if self.args.kind == 'debugger':
            return self.build_debugger()
        if self.args.kind == 'runtime' and not self.args.case:
            self.sources()
        if self.args.kind == 'isa':
            self.assembler_control()
            self.command([*self.cc, '-march=' + LEVELS[1], HERE / 'processor.c', '-O2',
                          '-o', self.bundle / 'processor'], 'processor-build')
        with ThreadPoolExecutor(max_workers=int(os.environ.get('LANDIN_RV64_JOBS', '4'))) as pool:
            results = list(pool.map(lambda item: self.build(*item), work_items(self.args)))
        if self.args.kind == 'isa':
            self.instructions(results)
        return results


def expected_results(args):
    if args.kind == 'debugger':
        return {'debug-' + o + '-' + s for o, s in PROFILES}
    return {(str(p.relative_to(ROOT / 'compiler/tests/fixtures')), o, s, level)
            for p, _, o, s, level in work_items(args)}


def load_prepared(args):
    prepared = args.prepared.resolve()
    manifest = json.loads((prepared / 'prepared.json').read_text())
    require(manifest['target'] == TARGET and manifest['kind'] == args.kind, 'prepared payload belongs to another lane')
    require(manifest['scope'] == 'complete' or not os.environ.get('GITHUB_ACTIONS'),
            'filtered payload cannot supply a recurring verdict')
    require(manifest['results'], 'empty prepared fixture selection')
    require(manifest['status'] == 'emitted', 'payload has not completed emission')
    if os.environ.get('GITHUB_SHA'):
        require(manifest['revision'] == os.environ['GITHUB_SHA'], 'prepared payload belongs to another revision')
    require(manifest['sources_sha256'] == source_hashes(), 'source checkout differs from emitted payload')
    if manifest['scope'] == 'complete':
        actual = ({r['label'] for r in manifest['results']} if args.kind == 'debugger' else
                  {(r['case'], r['optimize'], r['specialize'], r['level']) for r in manifest['results']})
        require(actual == expected_results(args) and len(actual) == len(manifest['results']),
                'prepared corpus incomplete')
    actual = {p.name: sha(p) for p in (prepared / 'bundle').iterdir() if p.is_file()}
    require(actual == manifest['bundle_sha256'], 'prepared bundle checksum')
    for result in manifest['results']:
        require(actual[result['label']] == result['executable_sha256'], 'prepared executable checksum')
        if args.kind != 'debugger':
            require(result['meta'] == metadata(ROOT / 'compiler/tests/fixtures' / result['case'] / 'fixture.meta'),
                    'prepared fixture oracle differs from source checkout')
    shutil.copytree(prepared / 'bundle', args.output / 'bundle')
    for path in prepared.glob('*.log'):
        shutil.copyfile(path, args.output / path.name)
    if (prepared / 'source-verdicts.json').exists():
        shutil.copyfile(prepared / 'source-verdicts.json', args.output / 'source-verdicts.json')
    return manifest


def native_identity(output):
    require(platform.system() == 'Linux' and platform.machine() == 'riscv64',
            'physical RV64 Linux execution required')
    cpu = Path('/proc/cpuinfo').read_text()
    (output / 'cpuinfo.log').write_text(cpu)
    # This lane is dispatched only to the RISE physical-machine label. Refuse
    # positively identified emulation even in manually requested execution.
    require(not re.search(r'qemu|virtio|riscv-virtio', cpu, re.I), 'emulated CPU is not physical evidence')
    return {'system': platform.system(), 'machine': platform.machine(), 'cpuinfo': cpu}


def execute(args, manifest):
    bundle = args.output / 'bundle'
    if args.kind == 'isa':
        probe = subprocess.run([str(bundle / 'processor')], capture_output=True, timeout=30)
        (args.output / 'processor.log').write_bytes(probe.stdout + probe.stderr)
        require(probe.returncode == 0, 'hardware does not execute xtheadba; no extended fixture may run')
    # Shared hosted fixtures write temporary outputs relative to compiler/ada.
    # Unlike the compiler hosts, this native checkout has no Ada build tree.
    (ROOT / 'compiler/ada/build').mkdir(parents=True, exist_ok=True)
    for result in manifest['results']:
        meta, label = result['meta'], result['label']
        merged = meta.get('stream', 'merged') == 'merged'
        completed = subprocess.run([str(bundle / label), *shlex.split(meta.get('run_args', ''))],
                                   cwd=ROOT / 'compiler/ada', stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT if merged else subprocess.PIPE, timeout=90)
        (args.output / (label + '.stdout')).write_bytes(completed.stdout)
        (args.output / (label + '.stderr')).write_bytes(completed.stderr or b'')
        (args.output / (label + '.status')).write_text(str(completed.returncode))
        status = -4 if meta.get('traps') == 'yes' else int(meta['status'])
        if result['case'] == 'runtime/rv64-feature-fact':
            status = 43 if result['level'] == LEVELS[1] else 42
        require(completed.returncode == status, f'{label}: status {completed.returncode}, expected {status}')
        base = ROOT / 'compiler/tests/fixtures' / result['case']
        expected = (base / meta['run_expect']).read_bytes() if meta.get('run_expect') else meta.get('stdout', '').encode()
        actual = completed.stdout
        require(actual == expected, label + ': output mismatch ' + repr(actual[:500]))
        if meta.get('stream', 'merged') != 'merged':
            require(not completed.stderr, label + ': unexpected stderr')
        result['status'] = 'passed'
        print(TARGET + ': ' + label + ' passed', flush=True)


def debugger(args, manifest):
    for result in manifest['results']:
        label, lines = result['label'], result['lines']
        commands = ['set pagination off', 'set confirm off', 'set disable-randomization off',
                    'set substitute-path ' + shlex.quote(manifest['source_root']) + ' ' + shlex.quote(str(ROOT)),
                    'break debug.ldn:' + str(lines['result = local + 1']), 'run',
                    'frame', 'info args', 'info locals', 'bt', 'frame 1', 'info args', 'info locals',
                    'frame 2', 'frame', 'frame 0', 'echo BEGIN_UNWIND\\n', 'finish', 'frame', 'echo END_UNWIND\\n',
                    'break debug.ldn:' + str(lines['result = ready']), 'continue', 'info locals',
                    'delete breakpoints', 'continue', 'quit']
        script = args.output / (label + '.gdb')
        script.write_text('\n'.join(commands) + '\n')
        completed = subprocess.run([args.gdb, '-q', '-batch', '-x', str(script),
                                    str(args.output / 'bundle' / label)], capture_output=True, timeout=180)
        text = (completed.stdout + completed.stderr).decode(errors='replace')
        (args.output / (label + '-session.log')).write_text(text)
        require(completed.returncode == 0, label + ': native GDB failed\n' + text[-4000:])
        require(re.search(r'debug.ldn:' + str(lines['result = local + 1']) + r'\b', text), label + ': source-line stop missing')
        for index, name in ((0, 'inner'), (1, 'outer'), (2, 'main')):
            require(re.search(r'#' + str(index) + r'\s+.*\b' + name + r'\b', text), label + ': missing frame ' + name)
        for name, value in (('argument', 40), ('local', 41), ('argument', 30), ('local', 40), ('result', 42)):
            require(re.search(r'\b' + name + r'\s*=\s*' + str(value) + r'\b', text), label + ': missing value ' + name)
        markers = list(re.finditer(r'^(BEGIN_UNWIND|END_UNWIND)\r?$', text, re.M))
        require([m.group(1) for m in markers] == ['BEGIN_UNWIND', 'END_UNWIND'],
                label + ': GDB unwind markers missing or out of order')
        unwound = text[markers[0].end():markers[1].start()]
        require(re.search(r'^#0[ \t]+[^\r\n]*\bouter\b[^\r\n]*debug\.ldn:' +
                          str(lines['result = inner(local)']) + r'\b', unwound, re.M),
                label + ': GDB finish did not unwind to caller source line')
        returned = text[markers[1].end():]
        require(re.search(r'\bouter\b[^\r\n]*debug\.ldn:' +
                          str(lines['result = ready']) + r'\b', returned),
                label + ': post-finish caller source stop missing')
        for name in ('ready', 'result'):
            require(re.search(r'\b' + name + r'\s*=\s*42\b', returned),
                    label + ': post-finish caller value missing ' + name)
        require(re.search(r'exited with code 0*52', text), label + ': missing final exit status')
        result['status'] = 'passed'
        print(TARGET + ': ' + label + ' source stops, frames, locals and unwinding passed', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kind', choices=['runtime', 'debugger', 'abi', 'isa'], required=True)
    parser.add_argument('--refine', type=Path)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--prepared', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cc', default='riscv64-linux-gnu-gcc')
    parser.add_argument('--objdump', default='riscv64-linux-gnu-objdump')
    parser.add_argument('--gdb', default='gdb')
    parser.add_argument('--case', action='append', help='exact case, development only')
    args = parser.parse_args()
    require(bool(args.prepare_only) != bool(args.prepared), 'select exactly one prepare or native execution stage')
    require(not args.prepare_only or args.refine, 'emission requires checked refine')
    args.output.mkdir(parents=True, exist_ok=False)
    summary = {'target': TARGET, 'kind': args.kind, 'scope': 'filtered' if args.case else 'complete', 'status': 'failed', 'results': []}
    try:
        if args.prepare_only:
            lane = Lane(args)
            results = lane.prepare()
            summary.update(status='emitted', results=results, source_root=str(ROOT),
                           sources_sha256=source_hashes(), refine_sha256=sha(args.refine),
                           revision=os.environ.get('GITHUB_SHA'),
                           bundle_sha256={p.name: sha(p) for p in lane.bundle.iterdir() if p.is_file()})
            (args.output / 'prepared.json').write_text(json.dumps(summary, indent=2) + '\n')
            print(TARGET + ' ' + args.kind + ': emitted; physical execution pending')
        else:
            manifest = load_prepared(args)
            summary.update({k: manifest[k] for k in ('scope', 'revision', 'refine_sha256', 'results')})
            summary['hardware'] = native_identity(args.output)
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            if args.kind == 'debugger':
                debugger(args, manifest)
            else:
                execute(args, manifest)
            summary['status'] = 'passed'
            print(TARGET + ' ' + args.kind + ': ' + str(len(summary['results'])) + ' outcomes passed')
    finally:
        (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')


if __name__ == '__main__':
    main()
