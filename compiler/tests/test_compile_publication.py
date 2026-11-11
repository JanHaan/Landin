#!/usr/bin/env python3
"""Native compiler publication controls; every input is in an owned root."""
import argparse
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import resource
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile


def entry_snapshot(path):
    try:
        identity = path.lstat()
    except FileNotFoundError:
        return None
    result = dict(device=identity.st_dev, inode=identity.st_ino,
                  mode=identity.st_mode)
    if path.is_symlink():
        result['link_target'] = os.readlink(path)
    elif path.is_file():
        result['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def workspaces(directory):
    return sorted(str(path) for path in directory.rglob('.refine-publication-*'))


def readable(text):
    """Whether a diagnostic is text: no byte a terminal would not print."""
    return all(byte == 0x0a or 0x20 <= byte < 0x7f for byte in text)


def host_controls(refine, root, env, source, driver):
    """The native adapter's own rules, each control in a directory of its own.

    Each returns None when it holds and what it saw otherwise.  They are the
    cases the publication, signal and naming rules were found not to cover:
    the mode an output is published with, entries of other users in the
    output directory, refusals that borrowed an unrelated error's words,
    failures that left a workspace or no reason, a tool that writes beside
    itself, and limits whose signal ends the process."""
    temporary = Path(env['TMPDIR'])

    def compile_in(directory, *operands, **options):
        options.setdefault('timeout', 60)
        return subprocess.run([str(refine), 'compile', *operands],
                              cwd=directory, env=env, capture_output=True,
                              **options)

    def output_modes(work):
        # A staged file is the file that is installed: it is created as any
        # program creates an output, by the caller's umask, and a rebuild
        # that changes its bytes does not narrow it to its owner.
        made = compile_in(work, str(source), '-o', 'program', '--keep-asm',
                          '--build-report', 'build.json', '--stage-report',
                          'stage.json', '--depfile', 'program.d',
                          preexec_fn=lambda: os.umask(0o022))
        modes = {path.name: stat.S_IMODE(path.stat().st_mode)
                 for path in work.iterdir()}
        shared = work / 'shared.s'
        shared.write_text('previous\n')
        shared.chmod(0o600)
        again = compile_in(work, str(source), '--emit', 'asm', '-o', 'shared.s',
                           preexec_fn=lambda: os.umask(0o027))
        if (made.returncode == 0 and again.returncode == 0
                and modes == {'program': 0o755, 'program.s': 0o644,
                              'build.json': 0o644, 'stage.json': 0o644,
                              'program.d': 0o644}
                and stat.S_IMODE(shared.stat().st_mode) == 0o640):
            return None
        return dict(modes={name: oct(mode) for name, mode in modes.items()},
                    shared=oct(stat.S_IMODE(shared.stat().st_mode)),
                    stderr=(made.stderr + again.stderr).decode(errors='replace'))

    def unchanged_output_mode(work):
        # The same bytes keep their file, and are given the mode the build
        # made: an executable restored without its execute bit runs again.
        program = work / 'program'
        first = compile_in(work, str(source), '-o', 'program',
                           preexec_fn=lambda: os.umask(0o022))
        before = program.stat()
        program.chmod(0o644)
        second = compile_in(work, str(source), '-o', 'program',
                            preexec_fn=lambda: os.umask(0o022))
        after = program.stat()
        if (first.returncode == 0 and second.returncode == 0
                and before.st_ino == after.st_ino
                and stat.S_IMODE(after.st_mode) == 0o755):
            return None
        return dict(mode=oct(stat.S_IMODE(after.st_mode)),
                    same_file=before.st_ino == after.st_ino,
                    stderr=second.stderr.decode(errors='replace'))

    def foreign_entries(work):
        # Only a directory this user made can hold this user's earlier
        # output.  A file or a link under the reserved prefix is passed
        # over; this user's own unreadable one is refused for what it is;
        # and a lock another process holds is not waited for without end.
        plain = work / '.refine-publication-file'
        plain.write_text('not a workspace\n')
        link = work / '.refine-publication-link'
        link.symlink_to(temporary)
        passed_over = compile_in(work, str(source), '--emit', 'asm', '-o', 'a.s')
        plain.unlink()
        link.unlink()
        own = work / '.refine-publication-own'
        own.mkdir()
        own.chmod(0)
        refused = compile_in(work, str(source), '--emit', 'asm', '-o', 'b.s')
        own.chmod(0o700)
        own.rmdir()
        held = work / '.refine-publication-held'
        held.mkdir()
        lock = os.open(held, os.O_RDONLY)
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            waited = compile_in(work, str(source), '--emit', 'asm', '-o', 'c.s',
                                timeout=30)
        except subprocess.TimeoutExpired:
            waited = None
        finally:
            os.close(lock)
        released = compile_in(work, str(source), '--emit', 'asm', '-o', 'c.s')
        held.rmdir()
        unreadable = os.geteuid() == 0 or (
            refused.returncode == 1 and b'cannot be opened' in refused.stderr
            and os.strerror(errno.EACCES).encode() in refused.stderr
            and b'recover the previous' not in refused.stderr
            and not (work / 'b.s').exists())
        if (passed_over.returncode == 0 and (work / 'a.s').is_file()
                and unreadable and waited is not None
                and waited.returncode == 1 and b'holds its lock' in waited.stderr
                and released.returncode == 0 and (work / 'c.s').is_file()):
            return None
        return dict(passed_over=passed_over.stderr.decode(errors='replace'),
                    refused=refused.stderr.decode(errors='replace'),
                    waited=None if waited is None
                    else waited.stderr.decode(errors='replace'),
                    released=released.stderr.decode(errors='replace'))

    def refusal_reasons(work):
        # A destination refused by the adapter's own rule is refused in the
        # rule's words, not in those of an error that did not happen.
        (work / 'target.txt').write_text('target\n')
        (work / 'link.s').symlink_to('target.txt')
        os.mkfifo(work / 'fifo.s')
        (work / 'unreadable.s').write_text('previous\n')
        (work / 'unreadable.s').chmod(0o200)
        (work / 'real').mkdir()
        (work / 'via').symlink_to('real')
        expected = [('link.s', b'it is a symbolic link'),
                    ('fifo.s', b'it is a FIFO'),
                    ('via/x.s', b'is a symbolic link, and an output is not'
                                b' written through one')]
        if os.geteuid() != 0:
            expected.append(('unreadable.s', b'cannot be read'))
        borrowed = [os.strerror(number).encode() for number in
                    (errno.ELOOP, errno.EAGAIN, errno.ENOTDIR)]
        seen = {}
        for name, words in expected:
            result = compile_in(work, str(source), '--emit', 'asm', '-o', name)
            seen[name] = result.stderr.decode(errors='replace')
            if (result.returncode != 1 or b'L0005' not in result.stderr
                    or words not in result.stderr
                    or any(text in result.stderr for text in borrowed)):
                return seen
        if ((work / 'target.txt').read_text() == 'target\n'
                and not list((work / 'real').iterdir())):
            return None
        return seen

    def descriptor_limit(work):
        # Whatever a descriptor limit stops, the refusal is text and says a
        # reason, and a workspace is left only where the refusal names it.
        seen = []
        for count in range(4, 13):
            def limit():
                resource.setrlimit(resource.RLIMIT_NOFILE, (count, count))
            result = compile_in(work, str(source), '--emit', 'asm', '-o',
                                'limited-%d.s' % count, preexec_fn=limit)
            left = workspaces(work)
            seen.append(dict(limit=count, exit_status=result.returncode,
                             stderr=result.stderr.decode(errors='replace'),
                             left=left))
            if (not readable(result.stderr)
                    or (result.returncode != 0
                        and b': \n' in result.stderr)
                    or (left and b'publication' not in result.stderr)):
                return seen
            for path in left:
                shutil.rmtree(path)
        refused = [row for row in seen if row['exit_status'] != 0]
        if refused and all(os.strerror(errno.EMFILE) in row['stderr']
                           for row in refused):
            return None
        return seen

    def descriptor_limit_link(work):
        # A link under a descriptor limit runs tools, each with a capture
        # directory of its own in TMPDIR.  Whether the limit stops the
        # build or not, removing a capture takes no descriptor the process
        # did not already hold, so none is left, nor a cleanup slot beside
        # it, and no refusal is of a capture that could not be released.
        scratch = work / 'scratch'
        scratch.mkdir()
        seen = []
        for count in range(4, 24):
            def limit():
                resource.setrlimit(resource.RLIMIT_NOFILE, (count, count))
            result = subprocess.run(
                [str(refine), 'compile', str(source), '--toolchain=' + driver,
                 '-o', 'linked-%d' % count],
                cwd=work, env=dict(env, TMPDIR=str(scratch)),
                capture_output=True, preexec_fn=limit, timeout=60)
            left = sorted(path.name for path in scratch.iterdir())
            seen.append(dict(limit=count, exit_status=result.returncode,
                             stderr=result.stderr.decode(errors='replace'),
                             left=left, workspaces=workspaces(work)))
            if (left or not readable(result.stderr)
                    or b'could not release temporary tool output'
                    in result.stderr
                    or (workspaces(work)
                        and b'publication' not in result.stderr)):
                return seen
            for path in workspaces(work):
                shutil.rmtree(path)
        # The sweep reached both sides: a limit that stopped the link and
        # one under which it was written.
        if (any(row['exit_status'] != 0 for row in seen)
                and seen[-1]['exit_status'] == 0
                and (work / ('linked-%d' % (count))).exists()):
            return None
        return seen

    def closed_pipe_run(work):
        # refine writing its own trace into a pipe nobody reads, while its
        # run directory exists, still removes that directory.
        reader, writer = os.pipe()
        os.close(reader)
        try:
            result = subprocess.run([str(refine), 'run', '-v', str(source)],
                                    cwd=work, env=env, stdout=subprocess.PIPE,
                                    stderr=writer, timeout=60)
        finally:
            os.close(writer)
        left = sorted(path.name for path in temporary.iterdir())
        if result.returncode == 128 + signal.SIGPIPE and not left:
            return None
        return dict(exit_status=result.returncode, left=left)

    def nul_in_path(work):
        # A response file can carry a NUL; the name it is in names no file,
        # and is never cut down to the file its first part names.
        response = work / 'arguments.rsp'
        response.write_bytes(str(source).encode() + b'\0.other\n--emit\nasm\n-o\n'
                             + str(work / 'out.s').encode() + b'\n')
        result = compile_in(work, '@' + str(response))
        if (result.returncode != 0 and b'not found' in result.stderr
                and not (work / 'out.s').exists()):
            return None
        return dict(exit_status=result.returncode,
                    stderr=result.stderr.decode(errors='replace'))

    def tool_litter(work):
        # What a tool leaves beside itself is in the directory it was
        # started in, which is not the stage: the build is published and
        # the output directory takes the next build.
        wrapper = work / 'littering-cc'
        wrapper.write_text('#!/bin/sh\n: > core\nmkdir -p profile\n'
                           ': > profile/default.profraw\nexec '
                           + shlex.quote(driver) + ' "$@"\n')
        wrapper.chmod(0o700)
        out = work / 'out'
        out.mkdir()
        first = compile_in(work, '--toolchain=' + str(wrapper), str(source),
                           '-o', str(out / 'program'))
        entries = sorted(path.name for path in out.iterdir())
        second = compile_in(work, str(source), '--emit', 'asm', '-o',
                            str(out / 'other.s'))
        if (first.returncode == 0 and entries == ['program']
                and second.returncode == 0 and not (work / 'core').exists()):
            return None
        return dict(entries=entries, first=first.stderr.decode(errors='replace'),
                    second=second.stderr.decode(errors='replace'))

    def directory_for_a_file(work):
        # A report or depfile option that names a directory is refused when
        # it is prepared, as that option's output.  The FIFO in it is what reading the tree would
        # have met, and refused in the words of a symbolic-link loop.
        target = work / 'target'
        target.mkdir()
        (target / 'kept.txt').write_text('kept\n')
        os.mkfifo(target / 'never-read')
        seen = {}
        for option in ('--build-report', '--stage-report', '--depfile'):
            result = compile_in(work, str(source), '--emit', 'asm', '-o',
                                'program.s', option, str(target))
            seen[option] = result.stderr.decode(errors='replace')
            named = ('cannot prepare %s output %s: ' % (option, target)).encode()
            if (result.returncode == 0 or named not in result.stderr
                    or b'is a directory, but the generated artifact is a'
                       b' regular file' not in result.stderr
                    or (work / 'program.s').exists()):
                return seen
        if sorted(path.name for path in target.iterdir()) == ['kept.txt',
                                                                'never-read']:
            return None
        return seen

    def removed_working_directory(work):
        # A process whose directory was removed still names its outputs
        # absolutely; a relative one is refused for that reason, and
        # neither is a defect of the compiler.
        def leave():
            gone = work / 'gone'
            gone.mkdir()
            os.chdir(gone)
            gone.rmdir()
        absolute = subprocess.run(
            [str(refine), 'compile', str(source), '-o', str(work / 'program')],
            env=env, capture_output=True, timeout=60, preexec_fn=leave)
        relative = subprocess.run(
            [str(refine), 'compile', str(source), '--emit', 'asm', '-o',
             'relative.s'], env=env, capture_output=True, timeout=60,
            preexec_fn=leave)
        if (absolute.returncode == 0 and (work / 'program').is_file()
                and relative.returncode not in (0, 70)
                and b'internal compiler defect' not in relative.stderr):
            return None
        return dict(absolute=absolute.stderr.decode(errors='replace'),
                    relative=relative.stderr.decode(errors='replace'),
                    relative_exit=relative.returncode)

    def file_size_signal(work):
        # A file-size limit as ulimit -f sets it, with the signal at its
        # default: the refusal written for the error is reached, where the
        # signal's default action would have ended the process in the write
        # and left the workspace.
        def limit():
            signal.signal(signal.SIGXFSZ, signal.SIG_DFL)
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            hard = resource.getrlimit(resource.RLIMIT_FSIZE)[1]
            resource.setrlimit(resource.RLIMIT_FSIZE, (0, hard))
        result = compile_in(work, str(source), '--emit', 'asm', '-o',
                            'limited.s', preexec_fn=limit)
        if (result.returncode == 1 and b'L0005' in result.stderr
                and os.strerror(errno.EFBIG).encode() in result.stderr
                and not workspaces(work) and not (work / 'limited.s').exists()):
            return None
        return dict(exit_status=result.returncode, left=workspaces(work),
                    stderr=result.stderr.decode(errors='replace'))

    return [('host-' + control.__name__.replace('_', '-'), control)
            for control in (output_modes, unchanged_output_mode,
                            foreign_entries, refusal_reasons, descriptor_limit,
                            descriptor_limit_link,
                            closed_pipe_run, nul_in_path, tool_litter,
                            directory_for_a_file, removed_working_directory,
                            file_size_signal)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--case', action='append', default=[],
                        help='select an exact control; repeat for a union')
    args = parser.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
    import refine_revision
    refine_revision.warn(args.refine)  # is it this checkout's?
    refine = args.refine.resolve(strict=True)
    root = (args.output.absolute() if args.output else
            Path(tempfile.mkdtemp(prefix='landin-compile-publication-')))
    if args.output:
        root.mkdir(parents=True)
    temporary = root / 'temporary'
    temporary.mkdir()
    env = dict(os.environ, TMPDIR=str(temporary))
    source = root / 'main.ldn'
    source.write_text('public main: () -> (code: i32) =\n    code = 0\nend main\n')
    driver = shutil.which('clang' if sys.platform == 'darwin' else 'gcc')
    if not driver:
        parser.error('the native C driver is required')
    wrapper = root / 'owned-cc'
    wrapper.write_text('#!/bin/sh\nexec ' + shlex.quote(driver) + ' "$@"\n')
    wrapper.chmod(0o700)
    response = root / 'arguments.rsp'
    response.write_text(str(source) + '\n-o\n' + str(root / 'response-product') + '\n')
    library = root / 'lib'
    library.mkdir()
    peer = root / 'peer.c'
    peer.write_text('int landin_publication_peer(void) { return 42; }\n')
    subprocess.run([driver, '-c', str(peer), '-o', str(root / 'peer.o')], check=True,
                   capture_output=True, env=env)
    archive = library / 'libpublication.a'
    subprocess.run(['ar', 'rcs', str(archive), str(root / 'peer.o')], check=True,
                   capture_output=True, env=env)
    with_library = root / 'library.ldn'
    with_library.write_text('linker.library("publication")\n' + source.read_text())
    source_alias = root / 'source-alias'
    os.link(source, source_alias)
    cases = [
        ('plain', [str(source), '-o', str(root / 'plain')], source, True),
        ('tool-control', ['--toolchain=' + str(wrapper), str(source), '-o',
                          str(root / 'tool-product')], wrapper, True),
        ('response-control', ['@' + str(response)], response, True),
        ('library-control', ['--link=libc', '-L', str(library), str(with_library),
                             '-o', str(root / 'library-product')], archive, True),
        ('tool-as-report', ['--toolchain=' + str(wrapper), str(source), '-o',
                            str(root / 'tool-refused'), '--build-report=' + str(wrapper)], wrapper, False),
        ('response-as-report', ['@' + str(response), '--build-report=' + str(response)], response, False),
        ('library-as-report', ['--link=libc', '-L', str(library), str(with_library), '-o',
                               str(root / 'library-refused'), '--build-report=' + str(archive)], archive, False),
        ('source-hardlink-output', [str(source), '-o', str(source_alias)], source, False),
    ]
    # A conservative identity refusal must not claim an actual collision.
    # Apply the offered route (make the parent) and repeat each same command.
    missing_outputs = {}
    for kind, option in [('artifact', '-o'),
                         ('stage', '--stage-report'),
                         ('build', '--build-report'),
                         ('stack', '--stack-report'),
                         ('dependency', '--depfile')]:
        name = 'output-parent-' + kind
        destination = root / name / ('app' if kind == 'artifact' else 'report')
        operands = [str(source), '--link=libc']
        if kind != 'artifact':
            operands += ['-o', str(root / (name + '-program'))]
        operands += [option, str(destination)]
        cases.append((name, operands, source, False))
        missing_outputs[name] = destination
    unavailable_report = source / 'report.json'
    cases.append(('output-parent-unavailable',
                  [str(source), '--link=libc', '-o',
                   str(root / 'unavailable-parent-program'),
                   '--stage-report=' + str(unavailable_report)], source, False))
    if sys.platform == 'linux':
        # GNU ld accepts a selected .so as a textual library script. Its
        # INPUT payload is an input even though it was not named by refine.
        (library / 'libscriptpeer.so').write_text('INPUT ( ' + str(archive) + ' )\n')
        script_source = root / 'script-library.ldn'
        script_source.write_text('linker.library("scriptpeer")\n' + source.read_text())
        operands = ['--link=libc', '-L', str(library), str(script_source)]
        cases.extend([
            ('library-script-control', [*operands, '-o', str(root / 'script-product')], archive, True),
            ('library-script-payload-as-report', [*operands, '-o', str(root / 'script-refused'),
                                                  '--build-report=' + str(archive)], archive, False),
        ])
    malformed = root / 'malformed.ldn'
    malformed.write_text('@\n')
    selected_tools = root / 'selected-tools'
    selected_tools.mkdir()
    execution = root / 'unexpected-tool-execution'
    early_tool = selected_tools / 'early-cc'
    early_tool.write_text('#!/bin/sh\nprintf executed > ' +
                          shlex.quote(str(execution)) + '\nexit 97\n')
    early_tool.chmod(0o751)
    hard_alias = root / 'early-hardlink'
    symbolic_alias = root / 'early-symlink'
    os.link(early_tool, hard_alias)
    symbolic_alias.symlink_to(early_tool)
    linker = selected_tools / 'ld.peer'
    os.link(early_tool, linker)
    default_linker = selected_tools / 'ld'
    os.link(early_tool, default_linker)
    early_operands = [str(malformed), '--toolchain=' + str(early_tool)]
    for name, operands, report in [
        ('early-tool-as-stage-report', early_operands, early_tool),
        ('early-tool-hardlink-as-stage-report', early_operands, hard_alias),
        ('early-tool-symlink-as-stage-report', early_operands, symbolic_alias),
        ('early-resolved-tool-as-stage-report',
         [str(malformed), '--toolchain=early-cc'], early_tool),
        ('early-linker-as-stage-report',
         [*early_operands, '--linker=' + str(linker)], linker),
        ('early-resolved-linker-as-stage-report',
         [*early_operands, '--linker=peer'], linker),
        ('early-default-linker-as-stage-report', early_operands, default_linker),
        ('early-option-failure-as-stage-report',
         [*early_operands, '--option=invalid'], early_tool),
        ('early-safe-stage-report', early_operands, root / 'early-stages.json'),
        ('early-safe-absolute-linker-stage-report',
         [*early_operands, '--linker=' + str(linker)],
         root / 'early-absolute-linker-stages.json'),
    ]:
        cases.append((name, [*operands, '--stage-report=' + str(report)],
                      early_tool, False))
    if sys.platform == 'linux':
        default_driver = selected_tools / 'x86_64-pc-linux-gnu-gcc'
        os.link(early_tool, default_driver)
        cases.append(('early-default-driver-as-stage-report',
                      [str(malformed), '--stage-report=' + str(default_driver)],
                      early_tool, False))
    missing_tool = root / 'missing-tools' / 'driver'
    budget_source = root / 'past-budget.ldn'
    budget_source.write_text('mut image: [2147483649]u8 = [of 1]\n' +
                             'public main: () -> (code: i32) =\n'
                             '    code = i32(image[1])\nend main\n')
    for suffix in ('', '.s'):
        (root / ('budget-product' + suffix)).write_bytes(b'prior-budget-artifact\x00\xff')
    cases.extend([
        # Pin the budget being exceeded: Linux arm64 can hold this image.
        # This refusal must precede any tool launch on every compiler host.
        ('missing-parent-budget', [str(budget_source),
                                  '--target=linux-x86-64', '--link=libc',
                                  '--toolchain=' + str(missing_tool), '-o',
                                  str(root / 'budget-product')], budget_source, False),
        ('missing-parent-tool', [str(source), '--link=libc',
                                '--toolchain=' + str(missing_tool), '-o',
                                str(root / 'missing-product')], source, False),
        ('early-safe-missing-parent', [str(malformed),
                                      '--toolchain=' + str(missing_tool),
                                      '--stage-report=' + str(root / 'missing-stages.json')], malformed, False),
    ])
    # Keep missing-parent spelling refusal separate from the name-policy
    # control in an existing directory. Public output parents are not created.
    case_probe = root / 'case-probe'
    case_probe.write_bytes(b'case probe')
    case_folding = (root / 'CASE-PROBE').exists()
    case_probe.unlink()
    missing_parent_tool_reports = set()
    if case_folding:
        missing_parent_tool_reports.add('early-missing-parent-case-as-stage-report')
        cases.append(('early-missing-parent-case-as-stage-report',
                      [str(malformed), '--toolchain=' + str(missing_tool),
                       '--stage-report=' + str(missing_tool.with_name('DRIVER'))],
                      malformed, False))
        cases.append(('early-missing-leaf-case-as-stage-report',
                      [str(malformed),
                       '--toolchain=' + str(selected_tools / 'missing-cc'),
                       '--stage-report=' + str(selected_tools / 'MISSING-CC')],
                      malformed, False))
    for label, tool_name, report in [
        ('missing-parent', str(missing_tool), missing_tool),
        ('missing-parent-relative', 'missing-tools/driver', missing_tool),
        ('missing-parent-absolute', str(missing_tool), Path('missing-tools/driver')),
        ('missing-leaf', str(selected_tools / 'missing-cc'), selected_tools / 'missing-cc'),
        ('missing-leaf-relative', 'selected-tools/missing-cc', selected_tools / 'missing-cc'),
        ('missing-leaf-absolute', str(selected_tools / 'missing-cc'), Path('selected-tools/missing-cc')),
    ]:
        name = 'early-' + label + '-as-stage-report'
        if label.startswith('missing-parent'):
            missing_parent_tool_reports.add(name)
        cases.append((name,
                      [str(malformed), '--toolchain=' + tool_name,
                       '--stage-report=' + str(report)], malformed, False))
    # -o naming an existing directory is refused before compiling, with a
    # file under it as the example; the directory's contents stay as they were.
    output_directory = root / 'output-directory'
    output_directory.mkdir()
    directory_sentinel = output_directory / 'keep'
    directory_sentinel.write_bytes(b'directory sentinel')
    cases.append(('output-directory', [str(source), '--link=libc', '-o',
                                       str(output_directory)],
                  directory_sentinel, False))
    # A file-size limit refuses the publication record: the workspace that
    # captured nothing is removed, and the path and the route are said once.
    file_size_product = root / 'file-size-product'
    cases.append(('file-size-limit', [str(source), '--link=libc', '-o',
                                      str(file_size_product)], source, False))
    dsym_parent = root / 'ordinary.dSYM'
    dsym_parent.mkdir()
    assembly = root / 'owned-main.s'
    emitted = subprocess.run(
        [str(refine), 'compile', str(source), '--emit=asm', '--debug=full',
         '-o', str(assembly)],
        cwd=root, env=env, capture_output=True, timeout=45)
    if emitted.returncode:
        raise AssertionError(emitted.stderr.decode())
    assembly_object = assembly.with_suffix('.o')
    assembly_object.write_bytes(b'preserved input-side object\x00\xff')
    assembly_object_before = entry_snapshot(assembly_object)
    if sys.platform == 'darwin':
        object_input = root / 'uses-object.s'
        object_input.write_text('.incbin "' + str(assembly_object) + '"\n')
        cases.append(('assembly-object-input-as-product-object',
                      [str(object_input), '--link=libc', '--debug=full',
                       '-o', str(assembly.with_suffix(''))], assembly_object, False))
    for suffix in ('app', 'app.dSYM'):
        for operand in ('source', 'assembly'):
            product = dsym_parent / (suffix + '-' + operand)
            if suffix.endswith('.dSYM'):
                product = product.with_name(product.name + '.dSYM')
            input_path = assembly if operand == 'assembly' else source
            cases.append(('dsym-parent-' + operand + '-' + suffix,
                          [str(input_path), '--link=libc', '--debug=full',
                           '-o', str(product)], input_path, True))
    host = host_controls(refine, root, env, source, driver)
    if args.case:
        unknown = (set(args.case) - {case[0] for case in cases}
                   - {name for name, _ in host})
        if unknown:
            parser.error('unknown controls: ' + ', '.join(sorted(unknown)))
        cases = [case for case in cases if case[0] in args.case]
        host = [control for control in host if control[0] in args.case]
    results = []
    for name, operands, protected, succeeds in cases:
        budget_artifacts = [root / 'budget-product', root / 'budget-product.s']
        budget_before = [entry_snapshot(path) for path in budget_artifacts]
        before = protected.read_bytes()
        identity = protected.stat()
        refused_report = None
        report_before = None
        if name.startswith('early-') and not name.startswith('early-safe-'):
            refused_report = Path(next(value.split('=', 1)[1]
                                       for value in operands
                                       if value.startswith('--stage-report=')))
            if not refused_report.is_absolute():
                refused_report = root / refused_report
            report_before = entry_snapshot(refused_report)
        case_env = dict(env)
        if name.startswith('early-'):
            case_env['PATH'] = str(selected_tools) + os.pathsep + env['PATH']
        limit = None
        if name == 'file-size-limit':
            def limit():
                signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
                hard = resource.getrlimit(resource.RLIMIT_FSIZE)[1]
                resource.setrlimit(resource.RLIMIT_FSIZE, (0, hard))
        result = subprocess.run([str(refine), 'compile', *operands], cwd=root,
                                env=case_env, capture_output=True, timeout=45,
                                preexec_fn=limit)
        after = protected.stat()
        expected_failure = (result.returncode == 2 and b'L0002' in result.stderr)
        if name in missing_parent_tool_reports:
            # The selected absent tool and report share a spelling, but the
            # unavailable output parent now refuses before tool protection.
            expected_failure = (result.returncode == 2 and b'L0005' in result.stderr
                                and b'stage report parent is missing:' in result.stderr
                                and b'create the parent directory' in result.stderr
                                and b'path under an existing directory' in result.stderr
                                and b'collid' not in result.stderr
                                and not refused_report.parent.exists())
        elif name in missing_outputs:
            destination = missing_outputs[name]
            expected_failure = (result.returncode != 0
                                and b'parent is missing:' in result.stderr
                                and b'create the parent directory' in result.stderr
                                and b'collid' not in result.stderr
                                and not destination.parent.exists())
        elif name == 'output-parent-unavailable':
            expected_failure = (result.returncode != 0
                                and b'cannot establish stage report identity' in result.stderr
                                and b'parent access' in result.stderr
                                and b'collid' not in result.stderr)
        report_after = (entry_snapshot(refused_report)
                        if refused_report is not None else None)
        if name == 'output-directory':
            expected_failure = (result.returncode == 2 and b'L0005' in result.stderr
                                and b'-o names the file to write' in result.stderr
                                and (b'for example -o ' + str(output_directory / 'main').encode())
                                in result.stderr
                                and sorted(output_directory.iterdir()) == [directory_sentinel])
        elif name == 'file-size-limit':
            named = str(file_size_product).encode()
            expected_failure = (result.returncode == 1 and b'L0005' in result.stderr
                                and os.strerror(errno.EFBIG).encode() in result.stderr
                                and b'no publication workspace remains' in result.stderr
                                and result.stderr.count(b'cannot prepare') == 1
                                and result.stderr.count(named) == 1
                                and b'choose another output path' not in result.stderr
                                and not file_size_product.exists())
        if name == 'missing-parent-budget':
            expected_failure = result.returncode == 1 and b'L0505' in result.stderr
        elif name == 'missing-parent-tool':
            expected_failure = result.returncode == 1 and b'L0500' in result.stderr
        if name.startswith('early-safe-'):
            safe_report = Path(next(value.split('=', 1)[1] for value in operands
                                    if value.startswith('--stage-report=')))
            expected_failure = (result.returncode == 1 and b'L0012' in result.stderr
                                and safe_report.is_file()
                                and json.loads(safe_report.read_text())['format']
                                == 'landin-stage-report-1')
        product_ok = True
        if succeeds and '-o' in operands:
            product = Path(operands[operands.index('-o') + 1])
            product_ok = (product.is_file() and product.stat().st_size > 0
                          and os.access(product, os.X_OK))
            if sys.platform == 'darwin' and '--debug=full' in operands:
                debug_object = product.with_name(product.name + '.o')
                debug_bundle = product.with_name(product.name + '.dSYM')
                dwarf = debug_bundle / 'Contents/Resources/DWARF' / product.name
                product_ok = (product_ok and debug_object.is_file()
                              and debug_object.stat().st_size > 0
                              and dwarf.is_file() and dwarf.stat().st_size > 0)
        passed = ((result.returncode == 0 if succeeds else expected_failure)
                  and product_ok
                  and budget_before == [entry_snapshot(path) for path in budget_artifacts]
                  and protected.read_bytes() == before
                  and (identity.st_dev, identity.st_ino, identity.st_mode)
                  == (after.st_dev, after.st_ino, after.st_mode)
                  and report_before == report_after
                  and entry_snapshot(assembly_object) == assembly_object_before
                  and not execution.exists()
                  and not list(temporary.iterdir())
                  and not list(root.rglob('.refine-publication-*')))
        route_control = None
        if name in missing_outputs:
            destination.parent.mkdir()
            route_control = subprocess.run(result.args, cwd=root, env=case_env,
                                           capture_output=True, timeout=45)
            passed = (passed and route_control.returncode == 0
                      and destination.is_file()
                      and protected.read_bytes() == before
                      and not list(root.rglob('.refine-publication-*')))
        elif name == 'output-parent-unavailable':
            repaired = [value.replace(str(unavailable_report),
                                      str(root / 'available-stage.json'))
                        for value in result.args]
            route_control = subprocess.run(repaired, cwd=root, env=case_env,
                                           capture_output=True, timeout=45)
            passed = (passed and route_control.returncode == 0
                      and (root / 'available-stage.json').is_file()
                      and protected.read_bytes() == before
                      and not list(root.rglob('.refine-publication-*')))
        row = dict(case=name, command=result.args, exit_status=result.returncode,
                   passed=passed, protected=str(protected),
                   route_control=(None if route_control is None else
                                  dict(command=route_control.args,
                                       exit_status=route_control.returncode,
                                       stdout=route_control.stdout.decode(errors='replace'),
                                       stderr=route_control.stderr.decode(errors='replace'))),
                   before_sha256=hashlib.sha256(before).hexdigest(),
                   after_sha256=hashlib.sha256(protected.read_bytes()).hexdigest(),
                   before_identity=[identity.st_dev, identity.st_ino, identity.st_mode],
                   after_identity=[after.st_dev, after.st_ino, after.st_mode],
                   tool_executed=execution.exists(),
                   assembly_object_before=assembly_object_before,
                   assembly_object_after=entry_snapshot(assembly_object),
                   refused_report=str(refused_report) if refused_report else None,
                   report_entry_before=report_before,
                   report_entry_after=report_after,
                   stdout=result.stdout.decode(errors='replace'),
                   stderr=result.stderr.decode(errors='replace'))
        results.append(row)
        (root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(('PASS ' if passed else 'FAIL ') + name, flush=True)
        if not passed:
            raise AssertionError(row)
    for name, control in host:
        work = root / name
        work.mkdir()
        seen = control(work)
        passed = (seen is None and not workspaces(work)
                  and not list(temporary.iterdir()))
        row = dict(case=name, passed=passed, seen=seen, left=workspaces(work),
                   temporary=sorted(path.name for path in temporary.iterdir()))
        results.append(row)
        (root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(('PASS ' if passed else 'FAIL ') + name, flush=True)
        if not passed:
            raise AssertionError(row)
    scope = ' FILTERED' if args.case else ''
    print('compile publication%s: %d controls passed; evidence %s' %
          (scope, len(results), root))


if __name__ == '__main__':
    main()
