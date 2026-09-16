"""Frozen schema-3/4 derivative stop oracle, transcribed from accepted R5.50.

Marker positions come from the archived source. Changes to live debugger
helpers cannot reinterpret historical bundles. A new oracle needs a new
acceptance schema; preserve this contract and its historical verification.
"""
from pathlib import Path
from common import require



CONTAINER_DONE_VALUES = (
    "signed_order", "unsigned_order_ok", "numbers_ok", "arrays_ok", "raw_ok",
    "vector_ok", "small_ok", "map_ok", "reference_entries_ok",
    "map_first_failure_ok", "map_second_failure_ok", "map_third_failure_ok",
    "tree_ok", "drawables_ok",
)


def source_line(path: Path, needle: str, occurrence: int = 0) -> int:
    matches = [number for number, line in enumerate(
               path.read_text().splitlines(), 1) if needle in line]
    require(len(matches) > occurrence,
            f"source marker {needle!r} is absent from {path.name}")
    return matches[occurrence]


def parser_lines(root) -> dict[str, int]:
    return {
        "digits": source_line((root / 'examples/config_parser/parser/parser.ldn'),
                              "if text.ordinal(cursor) == text.ordinal(ends)"),
        "recovery": source_line((root / 'examples/config_parser/parser/parser.ldn'),
                                "return when parser.look.what == lexer.newline"),
        "nested": source_line((root / 'examples/config_parser/parser/parser.ldn'),
                              "if parser.look.what == lexer.end_of_input"),
        "done": source_line((root / 'compiler/tests/fixtures/runtime/derived-parser') / "main.ldn", "code = 42"),
    }

def container_lines(root) -> dict[str, int]:
    source = (root / 'examples/derived_containers/workload/workload.ldn').read_text().splitlines()
    result = {}
    for name, marker in (("evidence", "R470_DEBUG_EVIDENCE_ENTRY"),
                         ("sorted", "R470_DEBUG_SORTED_LIST"),
                         ("done", "R470_DEBUG_CONTAINERS_DONE")):
        matches = [index for index, line in enumerate(source) if marker in line]
        require(len(matches) == 1, f"container marker {marker} is not unique")
        index = matches[0] + 1
        require(index < len(source) and source[index].strip()
                and not source[index].lstrip().startswith("--"),
                f"container marker {marker} does not precede executable source")
        result[name] = index + 1
    for occurrence, instance in enumerate(("signed", "unsigned")):
        result[instance + "-provider"] = source_line(
            (root / 'examples/derived_containers/workload/workload.ldn'), "yes = left < right", occurrence)
    result["signed-call"] = source_line((root / 'examples/derived_containers/workload/workload.ldn'), "signed_order: bool =")
    result["unsigned-call"] = source_line((root / 'examples/derived_containers/workload/workload.ldn'), "unsigned_order_ok: bool =")
    result["signed-ready"] = result["unsigned-call"]
    result["unsigned-ready"] = source_line((root / 'examples/derived_containers/workload/workload.ldn'), "numbers_ok: bool =")
    return result

def hosted_lines(root) -> dict[str, int]:
    result = {}
    for name, filename, marker in (
            ("sample", "filter.ldn", "R480_DEBUG_SAMPLE"),
            ("text", "dest.ldn", "R480_DEBUG_TEXT")):
        source = ((root / 'examples/derived_hosted/app/app.ldn').parent / filename).read_text().splitlines()
        matches = [index for index, line in enumerate(source) if marker in line]
        require(len(matches) == 1, f"hosted marker {marker} is not unique")
        index = matches[0] + 1
        require(index < len(source) and source[index].strip()
                and not source[index].lstrip().startswith("--"),
                f"hosted marker {marker} does not precede executable source")
        result[name] = index + 1
    result["sample-updated"] = source_line(
        (root / 'examples/derived_hosted/app/app.ldn').parent / "filter.ldn", "yes = self.val.seen")
    return result

def stops_for(workload, root):
    def stop(name, source, line, stack, values, **extra):
        return dict(name=name, source=str(source), line=line, stack=stack, values=values, **extra)
    if workload == 'parser':
        lines = parser_lines(root)
        source = (root / 'examples/config_parser/parser/parser.ldn')
        return [
            stop('digits', source, lines['digits'],
                 ['parse_digits', 'parse_digits', 'parse_entry', 'parse_sequence'],
                 {'accumulated': 4, 'cursor.offset': 27, 'ends.offset': 28},
                 when={'accumulated': 4}, complete_parser=True,
                 caller_values={'accumulated': 0, 'cursor.offset': 26}),
            stop('recovery', source, lines['recovery'],
                 ['recover_to_boundary', 'parse_entry', 'parse_sequence'],
                 {'parser.depth': 0, 'parser.look.what': 1,
                  'parser.look.begins.offset': 36, 'parser.look.ends.offset': 38},
                 when={'parser.look.begins.offset': 36}, complete_parser=True),
            stop('nested', source, lines['nested'],
                 ['parse_sequence', 'parse_entry', 'parse_sequence'],
                 {'parser.depth': 1, 'parser.look.what': 6,
                  'parser.look.begins.offset': 48, 'source.1': 92},
                 when={'parser.depth': 1}, complete_parser=True),
            stop('done', (root / 'compiler/tests/fixtures/runtime/derived-parser') / 'main.ldn', lines['done'], ['main'],
                 {'valid': 1, 'source_length': 92, 'saw_out_of_memory': 1, 'saw_io_failure': 1})]
    if workload == 'containers':
        lines = container_lines(root)
        source = (root / 'examples/derived_containers/workload/workload.ldn')
        return [
            stop('sorted', source, lines['sorted'], ['numbers_path', 'containers_run', 'main'],
                 {'count': 20, 'first': 1, 'last': 20}),
            stop('done', source, lines['done'], ['containers_run', 'main'],
                 dict.fromkeys(CONTAINER_DONE_VALUES, 1)),
            *[stop(instance, source, lines['evidence'],
                   ['evidence_less', 'containers_run', 'main'],
                   {'left': left, 'right': 1}, when={'left': left}, steps=[
                       dict(action='in', function=provider, line=lines[instance + '-provider'],
                            stack=[provider, 'evidence_less', 'containers_run', 'main'],
                            values={'left': left, 'right': 1}),
                       dict(action='out', function='evidence_less', line=lines['evidence']),
                       dict(action='out', function='containers_run', line=lines[instance + '-call']),
                       dict(action='over', function='containers_run', line=lines[instance + '-ready'],
                            values={('signed_order' if instance == 'signed' else 'unsigned_order_ok'): 1})])
              for instance, provider, left in (('signed', 'less_i32', -1),
                                               ('unsigned', 'less_u32', 4294967295))]]
    assert workload == 'hosted'
    lines = hosted_lines(root)
    source = (root / 'examples/derived_hosted/app/app.ldn').parent
    return [stop(name, source / filename, lines[name], stack, values)
            for name, filename, stack, values in (
                ('sample', 'filter.ldn', ['sample_keep', 'process', 'run_logged', 'run', 'main'],
                 {'self.*.seen': 0, 'self.*.every': 2}),
                ('sample-updated', 'filter.ldn', ['sample_keep', 'process', 'run_logged', 'run', 'main'],
                 {'self.*.seen': 1}),
                ('text', 'dest.ldn', ['text_emit', 'emit_retry', 'process', 'run_logged', 'run', 'main'],
                 {'line.delivered': 0}))]
