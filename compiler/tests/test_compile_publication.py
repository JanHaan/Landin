#!/usr/bin/env python3
"""Native compiler publication controls; every input is in an owned root."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--refine', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--case', action='append', default=[],
                        help='select an exact control; repeat for a union')
    args = parser.parse_args()
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
        ('missing-parent-budget', [str(budget_source), '--link=libc',
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
    if case_folding:
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
        cases.append(('early-' + label + '-as-stage-report',
                      [str(malformed), '--toolchain=' + tool_name,
                       '--stage-report=' + str(report)], malformed, False))
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
    if args.case:
        unknown = set(args.case) - {case[0] for case in cases}
        if unknown:
            parser.error('unknown controls: ' + ', '.join(sorted(unknown)))
        cases = [case for case in cases if case[0] in args.case]
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
        result = subprocess.run([str(refine), 'compile', *operands], cwd=root,
                                env=case_env, capture_output=True, timeout=45)
        after = protected.stat()
        expected_failure = (result.returncode == 2 and b'L0002' in result.stderr)
        report_after = (entry_snapshot(refused_report)
                        if refused_report is not None else None)
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
        row = dict(case=name, command=result.args, exit_status=result.returncode,
                   passed=passed, protected=str(protected),
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
    scope = ' FILTERED' if args.case else ''
    print('compile publication%s: %d controls passed; evidence %s' %
          (scope, len(results), root))


if __name__ == '__main__':
    main()
