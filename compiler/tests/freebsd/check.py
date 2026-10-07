#!/usr/bin/env python3
"""Emit on Linux, execute and source-debug in a fresh FreeBSD VM per lane."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'environments/freebsd'))
from vm import boot, prepare, require, sha

PROFILES = [('none', 'off'), ('size', 'off'), ('size', 'auto'), ('speed', 'auto')]
SPECIALIZED = [('none', 'all'), ('speed', 'all')]
ABI_REQUIRED = {'r440-native-scalars', 'r440-native-aggregates', 'r440-native-callbacks',
                'r440-varargs-pointer-callback', 'r450-review-backend-c-entry'}


def metadata(path):
    return dict(line.split(': ', 1) for line in path.read_text().splitlines()
                if ': ' in line and not line.startswith('#'))


def select(arch, kind):
    target = 'freebsd-x86-64' if arch == 'amd64' else 'freebsd-arm64'
    fixtures = [(p.parent, metadata(p)) for p in
                sorted((ROOT / 'compiler/tests/fixtures' / kind).glob('*/fixture.meta'))]
    selected = [(p, m) for p, m in fixtures if target in m['targets'].split(', ')]
    # BSD guests lack the two Linux fault paths used by these I/O fixtures.
    # The shared C endpoint adapter preserves all source/status/output oracles.
    if kind == 'runtime':
        for path, meta in selected:
            if path.name in ('core-io-erased-system', 'r440-errno-detail'):
                meta['c-sources'] = '../../../freebsd/io_endpoints.c'
    require(selected, f'{target} {kind}: empty fixture selection')
    names = {p.name for p, _ in selected}
    if kind == 'abi':
        require(all(m.get('c-sources', '').strip() for _, m in selected),
                'ABI fixture lacks an independently compiled C peer')
        require(ABI_REQUIRED <= names, 'ABI coverage missing: ' + str(ABI_REQUIRED - names))
        require(('r440-native-varargs' if arch == 'amd64' else 'aapcs64-varargs-both-banks')
                in names, 'ABI lane lacks bank-exhausting variadic peer')
    else:
        require('assembly-operands' in names, 'runtime lane lacks integer assembly operands')
    return selected


def fixture_code(symbols, listing, names):
    """Select ELF function extents, retaining instructions after local labels."""
    extents = []
    for line in symbols.splitlines():
        fields = line.split()
        if len(fields) >= 6 and 'F' in fields and fields[-1] in names:
            kind = fields.index('F')
            if fields[kind + 1] == '.text':
                start, size = int(fields[0], 16), int(fields[kind + 2], 16)
                require(size > 0, 'fixture routine has no ELF extent: ' + fields[-1])
                extents.append((start, start + size))
    require(extents, 'fixture routines missing from linked ELF')
    lines = []
    for line in listing.splitlines():
        match = re.match(r'\s*([0-9a-f]+):\s', line)
        if match and any(start <= int(match[1], 16) < end for start, end in extents):
            lines.append(line)
    require(lines, 'fixture routines have no disassembled instructions')
    return '\n'.join(lines)


class Lane:
    def __init__(self, args, sysroot):
        self.args = args
        self.output = args.output.resolve()
        self.bundle = self.output / 'bundle'
        self.bundle.mkdir()
        self.remote_prefix = '/tmp/landin-' + sha(args.refine)[:12] + '-' + self.output.name
        self.target = 'freebsd-x86-64' if args.arch == 'amd64' else 'freebsd-arm64'
        self.triplet = ('x86_64' if args.arch == 'amd64' else 'aarch64') + '-unknown-freebsd14.4'
        self.clang = str(Path(shutil.which(args.clang) or args.clang).resolve())
        self.lld = str(Path(shutil.which(args.lld) or args.lld).resolve())
        self.cc = [self.clang, '--target=' + self.triplet, '--sysroot=' + str(sysroot),
                   '-fuse-ld=' + self.lld, '-Wa,-L', *shlex.split(os.environ.get('LANDIN_FREEBSD_CC_ARGS', ''))]
        # Clang's integrated x86 assembler does not constrain instructions by
        # -march. Use GNU as for Landin assembly, with the compiler's feature
        # whitelist; independent C peers keep Clang's own assembler.
        tools = self.output / 'driver-tools'
        tools.mkdir()
        if args.arch == 'amd64':
            assembler = shutil.which(args.assembler)
            require(assembler is not None, 'GNU x86 assembler missing')
            (tools / 'as').symlink_to(Path(assembler).resolve())
            (tools / (self.triplet + '-as')).symlink_to(Path(assembler).resolve())
        self.driver = self.output / 'freebsd-clang'
        self.driver.write_text('#!/bin/sh\nexec ' + shlex.join(self.cc + ['-B' + str(tools)]) + ' "$@"\n')
        self.driver.chmod(0o755)

    def command(self, argv, label, *, expected=0):
        result = subprocess.run(list(map(str, argv)), cwd=ROOT / 'compiler/ada',
                                capture_output=True, timeout=900)
        (self.output / (label + '.log')).write_bytes(result.stdout + result.stderr)
        require(result.returncode == expected, f'{label}: status {result.returncode}\n'
                + (result.stdout + result.stderr).decode(errors='replace')[-5000:])
        return result.stdout

    def sources(self):
        results = []
        for kind in ('positive', 'negative'):
            for meta_path in sorted((ROOT / 'compiler/tests/fixtures' / kind).glob('*/fixture.meta')):
                meta = metadata(meta_path)
                if self.target not in meta['targets'].split(', '):
                    continue
                base = meta_path.parent
                if 'args' in meta:
                    argv = [a for a in shlex.split(meta['args']) if not a.startswith('--target=')]
                elif 'root' in meta:
                    argv = ['--root=' + str((base / meta['root']).resolve()), str(base)]
                else:
                    argv = [str(base / meta['program'])]
                argv += [str(base / p.strip()) for p in meta.get('with', '').split(',') if p.strip()]
                label = 'source-' + kind + '-' + base.name
                status = int(meta.get('status', '1' if kind == 'negative' else '0'))
                # Source verdicts run on the compiler host, selecting the guest
                # target; execution and debugger verdicts are always guest-side.
                completed = subprocess.run([str(self.args.refine.resolve()), '--target=' + self.target,
                                            *argv], cwd=ROOT / 'compiler/ada', capture_output=True, timeout=180)
                actual = completed.stdout + completed.stderr
                (self.output / (label + '.log')).write_bytes(actual)
                require(completed.returncode == status, label + ': wrong source verdict')
                codes = re.findall(rb'(?m)^(?:error|warning)\[(L[0-9]{4})\]', actual)
                expected = [c.strip().encode() for c in meta.get('codes', '').split(',') if c.strip()]
                require(codes == expected, label + ': ordered diagnostic codes differ: ' + str(codes))
                results.append({'case': kind + '/' + base.name, 'status': 'passed'})
        require(results, 'empty source verdict selection')
        (self.output / 'source-verdicts.json').write_text(json.dumps(results, indent=2) + '\n')
        print(self.target + ': ' + str(len(results)) + ' source verdicts passed', flush=True)

    def build(self, base, meta, optimize, specialize, level=None):
        label = '-'.join((base.parent.name, base.name, optimize, specialize, level or 'default'))
        executable = self.bundle / label
        source = base / meta['program']
        sources = (["--root=" + str((base / meta['root']).resolve()), str(source.parent)]
                   if 'root' in meta else [str(source)])
        sources += [str(base / p.strip()) for p in meta.get('with', '').split(',') if p.strip()]
        argv = [self.args.refine.resolve(), '--target=' + self.target,
                '--optimize=' + optimize, '--specialize=' + specialize,
                *(['--level=' + level] if level else []),
                *shlex.split(meta.get('args', '')), *sources]
        peers = []
        if not meta.get('c-sources'):
            self.command([*argv, '--toolchain=' + str(self.driver), '--emit=exe', '-o', executable],
                         label + '-build')
        else:
            assembly = Path(str(executable) + '.s')
            self.command([*argv, '--emit=asm', '-o', assembly], label + '-emit')
            objects = []
            cargs = shlex.split(meta.get('c-args', ''))
            compile_args = [a for a in cargs if not a.startswith('-Wl,') and not a.startswith('-l')]
            for index, name in enumerate(meta['c-sources'].split(',')):
                obj = Path(str(executable) + f'-peer-{index}.o')
                self.command([*[a for a in self.cc if not a.startswith('-fuse-ld=')],
                              '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                              *compile_args, '-c', base / name.strip(), '-o', obj],
                             label + f'-peer-{index}')
                objects.append(obj)
                peers.append({'source': name.strip(), 'source_sha256': sha(base / name.strip()),
                              'object_sha256': sha(obj)})
            assembler = ['-fno-integrated-as', '-Wa,-march=generic64'] if self.args.arch == 'amd64' else ['-march=' + (level or 'armv8-a')]
            self.command([self.driver, *assembler, assembly, *objects, *cargs, '-o', executable], label + '-link')
        return {'case': str(base.relative_to(ROOT / 'compiler/tests/fixtures')),
                'label': label, 'optimize': optimize, 'specialize': specialize, 'level': level,
                'executable_sha256': sha(executable), 'c_peers': peers,
                'meta': meta, 'base': str(base)}

    def transfer(self, guest):
        archive = self.output / 'payload.tar.gz'
        with tarfile.open(archive, 'w:gz') as tar:
            for relative in ('compiler/tests', 'core', 'examples'):
                tar.add(ROOT / relative, arcname=str(ROOT / relative).lstrip('/'),
                        filter=lambda info: None if '__pycache__' in info.name else info)
            tar.add(self.bundle, arcname=str(self.bundle).lstrip('/'))
        remote = self.remote_prefix + '-payload.tar.gz'
        guest.put(archive, remote)
        guest.checked('tar -xzf ' + shlex.quote(remote) + ' -C /; mkdir -p '
                      + shlex.quote(str(ROOT / 'compiler/ada/build')))

    def processor(self, guest):
        probe = self.bundle / 'processor'
        self.command([*self.cc, HERE / 'processor.c', '-O2', '-o', probe], 'processor-build')
        remote = self.remote_prefix + '-processor'
        guest.put(probe, remote)
        guest.checked('chmod +x ' + shlex.quote(remote))
        result = guest.run(shlex.quote(remote))
        (self.output / 'processor.log').write_bytes(result.stdout + result.stderr)
        require(result.returncode == 0, 'guest did not confirm the selected higher level: '
                + result.stdout.decode(errors='replace'))
        print(result.stdout.decode().strip(), flush=True)

    def assembler_control(self):
        text = '.text\n' + ('shlx %rax, %rdx, %rcx\n' if self.args.arch == 'amd64'
                            else 'ldaddal x0, x1, [x2]\n')
        assembly = self.output / 'level-control.s'
        assembly.write_text(text)
        baseline = ['-fno-integrated-as', '-Wa,-march=generic64'] if self.args.arch == 'amd64' else ['-march=armv8-a']
        higher = ['-fno-integrated-as', '-Wa,-march=generic64+bmi2'] if self.args.arch == 'amd64' else ['-march=armv8.1-a']
        self.command([self.driver, *baseline, '-c', assembly, '-o', self.output / 'control.o'],
                     'baseline-assembler-refusal', expected=1)
        self.command([self.driver, *higher, '-c', assembly, '-o', self.output / 'control.o'],
                     'higher-assembler-acceptance')

    def instructions(self, results):
        fixture = 'variable-shifts-at-every-width' if self.args.arch == 'amd64' else 'r630-memory-scalars'
        present = r'\b(?:shlx|shrx|sarx)[ql]?\b' if self.args.arch == 'amd64' else r'\b(?:ldadd|swp|cas)al[bh]?\b'
        exclusive = r'\b(?:ldxr|stxr)[bh]?\b'
        for result in results:
            if result['case'] != 'runtime/' + fixture:
                continue
            listing = self.command([self.args.objdump, '-d', self.bundle / result['label']],
                                   result['label'] + '-disassembly').decode()
            symbols = self.command([self.args.objdump, '-t', self.bundle / result['label']],
                                   result['label'] + '-symbols').decode()
            source = Path(result['base']) / result['meta']['program']
            names = set(re.findall(r'(?m)^(?:public )?([a-zA-Z_][a-zA-Z_0-9]*):\s*\(',
                                   source.read_text()))
            listing = fixture_code(symbols, listing, names)
            higher = result['level'] in ('x86-64-v3', 'armv8.1-a')
            require(bool(re.search(present, listing)) == higher,
                    result['label'] + ': incorrect feature instruction selection')
            if self.args.arch == 'arm64':
                require(bool(re.search(exclusive, listing)) != higher,
                        result['label'] + ': incorrect exclusive-loop selection')

    def execute(self, guest, results):
        script = ['#!/bin/sh', 'ulimit -c 0', 'ulimit -d unlimited',
                  'cd ' + shlex.quote(str(ROOT / 'compiler/ada'))]
        for result in results:
            label, meta = result['label'], result['meta']
            path = self.bundle / label
            command = shlex.join([str(path), *shlex.split(meta.get('run_args', ''))])
            out, err, status = (str(path) + suffix for suffix in ('.stdout', '.stderr', '.status'))
            redirection = '2>&1' if meta.get('stream', 'merged') == 'merged' else '2>' + shlex.quote(err)
            script += [f'timeout 60 {command} >{shlex.quote(out)} {redirection}',
                       f'echo $? >{shlex.quote(status)}']
        remote_results = self.remote_prefix + '-results.tar.gz'
        remote_script = self.remote_prefix + '-execute.sh'
        script += ['tar -czf ' + shlex.quote(remote_results) + ' -C ' + shlex.quote(str(self.bundle))
                   + ' ' + shlex.join([r['label'] + ext for r in results for ext in
                                     (('.stdout', '.status') if r['meta'].get('stream', 'merged') == 'merged'
                                      else ('.stdout', '.stderr', '.status'))])]
        guest.checked('cat > ' + shlex.quote(remote_script), input=('\n'.join(script) + '\n').encode())
        transcript = guest.checked('sh ' + shlex.quote(remote_script), timeout=max(900, 90 * len(results)))
        (self.output / 'guest-execute.log').write_bytes(transcript)
        archive = self.output / 'results.tar.gz'
        archive.write_bytes(guest.checked('cat ' + shlex.quote(remote_results)))
        with tarfile.open(archive) as tar:
            tar.extractall(self.bundle, filter='data')
        for result in results:
            label, meta = result['label'], result['meta']
            path = self.bundle / label
            status = int(Path(str(path) + '.status').read_text())
            expected_status = (132 if self.args.arch == 'amd64' else 133) if meta.get('traps') == 'yes' else int(meta['status'])
            require(status == expected_status, f'{label}: guest status {status}, expected {expected_status}')
            stdout = Path(str(path) + '.stdout').read_bytes()
            expected = (Path(result['base']) / meta['run_expect']).read_bytes() if meta.get('run_expect') else meta.get('stdout', '').encode()
            require(stdout == expected, f'{label}: output mismatch {stdout[:400]!r}, expected {expected[:400]!r}')
            if meta.get('stream', 'merged') != 'merged':
                require(not Path(str(path) + '.stderr').read_bytes(), label + ': unexpected stderr')
            result['status'] = 'passed'
            del result['meta'], result['base']

    def debugger(self, guest):
        source = HERE / 'debug.ldn'
        lines = {needle: next(i for i, line in enumerate(source.read_text().splitlines(), 1)
                              if needle in line) for needle in ('result = local + 1', 'result = inner(local)', 'result = ready')}
        results = []
        for optimize, specialize in PROFILES:
            label = 'debug-' + optimize + '-' + specialize
            executable = self.bundle / label
            self.command([self.args.refine.resolve(), '--target=' + self.target,
                          '--toolchain=' + str(self.driver), '--debug=full', '--emit=exe',
                          '--optimize=' + optimize, '--specialize=' + specialize,
                          source, '-o', executable], label + '-build')
            commands = ['settings set target.disable-aslr false',
                        f'breakpoint set --file debug.ldn --line {lines["result = local + 1"]}',
                        'run', 'frame info', 'frame variable argument local', 'thread backtrace',
                        'frame select 1', 'frame variable argument local',
                        'frame select 2', 'frame info', 'frame select 0',
                        'thread step-out', 'frame info',
                        f'breakpoint set --file debug.ldn --line {lines["result = ready"]}',
                        'continue', 'frame info', 'frame variable result',
                        'breakpoint delete --force', 'continue']
            (self.bundle / (label + '.lldb')).write_text('\n'.join(commands) + '\n')
            results.append((label, lines))
        self.transfer(guest)
        for label, lines in results:
            completed = guest.run('cd ' + shlex.quote(str(ROOT)) + '; lldb --batch -s '
                                  + shlex.quote(str(self.bundle / (label + '.lldb'))) + ' '
                                  + shlex.quote(str(self.bundle / label)), timeout=300)
            text = (completed.stdout + completed.stderr).decode(errors='replace')
            (self.output / (label + '-session.log')).write_text(text)
            require(completed.returncode == 0, label + ': LLDB failed\n' + text[-4000:])
            require(re.search(r'debug.ldn:' + str(lines['result = local + 1']) + r'[:\s]', text),
                    label + ': no source-line stop')
            for frame, name in ((0, 'inner'), (1, 'outer'), (2, 'main')):
                require(re.search(r'frame #' + str(frame) + r':.*\b' + name + r'\b', text),
                        label + ': stack frame missing: ' + name)
            for name, value in (('argument', 40), ('local', 41), ('argument', 30), ('local', 40), ('result', 42)):
                require(re.search(r'\b' + name + r' = ' + str(value) + r'\b', text),
                        label + ': local/caller/return value missing: ' + str((name, value)))
            unwound = text.split('(lldb) thread step-out', 1)[-1].split('(lldb) breakpoint set', 1)[0]
            require('stop reason = step out' in unwound, label + ': no completed step-out stop')
            require(re.search(r'frame #0:.*\bouter\b', unwound),
                    label + ': step-out failed to unwind to caller')
            require(re.search(r'exited with status = 42', text), label + ': final execution status missing')
            print(self.target + ': ' + label + ' source stops, frames, locals and unwinding passed', flush=True)
        return [{'profile': label, 'status': 'passed'} for label, _ in results]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=['amd64', 'arm64'], required=True)
    parser.add_argument('--kind', choices=['runtime', 'debugger', 'abi'], required=True)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cache', type=Path, default=Path.home() / '.cache/landin/freebsd')
    parser.add_argument('--clang', default='clang-19')
    parser.add_argument('--lld', default='ld.lld-19')
    parser.add_argument('--assembler', default='as')
    parser.add_argument('--objdump', default='llvm-objdump-19')
    parser.add_argument('--ssh-port', type=int, help='development VM already running')
    parser.add_argument('--case', action='append', help='exact fixture name, development only')
    args = parser.parse_args()
    require(sys.platform.startswith('linux'), 'FreeBSD emission lane must run on Linux')
    args.output.mkdir(parents=True, exist_ok=False)
    summary = {'target': args.arch, 'kind': args.kind, 'scope': 'filtered' if args.case else 'complete',
               'refine_sha256': sha(args.refine), 'status': 'failed', 'results': []}
    try:
        image, sysroot = prepare(args.arch, args.cache)
        lane = Lane(args, sysroot)
        with boot(args.arch, image, args.output.resolve(), port=args.ssh_port) as guest:
            identity = guest.checked('uname -srm; freebsd-version; lldb --version').decode()
            require('FreeBSD' in identity and ('amd64' if args.arch == 'amd64' else 'arm64') in identity,
                    'wrong guest identity: ' + identity)
            (args.output / 'guest-identity.log').write_text(identity)
            summary['guest'] = identity
            # The displacement-limit regression has a 2 GiB BSS object. FreeBSD
            # arm64 defaults to a 1 GiB data limit; the test VM must admit it.
            limits = guest.checked('sysctl kern.maxdsiz=4294967296; sysctl kern.maxdsiz')
            require(b'kern.maxdsiz: 4294967296' in limits, 'guest data limit is below corpus needs')
            (args.output / 'guest-limits.log').write_bytes(limits)
            if args.kind == 'debugger':
                summary['results'] = lane.debugger(guest)
            else:
                lane.processor(guest)
                lane.assembler_control()
                if args.kind == 'runtime' and not args.case:
                    lane.sources()
                candidates = select(args.arch, args.kind)
                if args.case:
                    require(set(args.case) <= {p.name for p, _ in candidates}, 'unknown exact case')
                    candidates = [(p, m) for p, m in candidates if p.name in args.case]
                work = []
                for base, meta in candidates:
                    levels = [None]
                    if args.kind == 'runtime':
                        default = 'x86-64-v1' if args.arch == 'amd64' else 'armv8-a'
                        higher = 'x86-64-v3' if args.arch == 'amd64' else 'armv8.1-a'
                        if higher in meta.get('levels', '').split(', '):
                            levels += [default, higher]
                    for level in levels:
                        for optimize, specialize in PROFILES + (SPECIALIZED if meta.get('profiles') == 'specialization' else []):
                            work.append((base, meta, optimize, specialize, level))
                def build(item):
                    result = lane.build(*item)
                    print(lane.target + ': built ' + result['label'], flush=True)
                    return result
                with ThreadPoolExecutor(max_workers=int(os.environ.get('LANDIN_FREEBSD_JOBS', '4'))) as pool:
                    results = list(pool.map(build, work))
                summary['results'] = results
                if args.kind == 'runtime':
                    lane.instructions(results)
                lane.transfer(guest)
                lane.execute(guest, results)
                summary['results'] = results
            summary['status'] = 'passed'
    finally:
        (args.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f"FreeBSD {args.arch} {args.kind}: {len(summary['results'])} {summary['scope']} outcomes passed")


if __name__ == '__main__':
    main()
