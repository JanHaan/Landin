"""The Python fixture reader means what the test program's reader means.

compiler/tests/fixture-meta.cases is the table both readers are held to:
this module holds compiler/tests/fixture_meta.py to it, and the test
program's `fixtures/the metadata readers agree` holds
`Landin.Testing.Fixtures`.  The corpus itself is read here too, so a key
the Python reader refuses and the test program accepts cannot sit in a
fixture unnoticed.
"""

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "compiler/tests"))

import fixture_meta  # noqa: E402

TABLE = ROOT / "compiler/tests/fixture-meta.cases"
LEVELS = ROOT / "compiler/ada/src/stages/landin-targets-levels"


def cases(text):
    """Each case of the table: (title, class, name, text, problems, fields)."""
    found, current = [], None
    for line in text.split("\n"):
        if not line or line.startswith("#"):
            continue
        if line.startswith("case "):
            current = {"title": line[5:], "label": "", "lines": [],
                       "problems": [], "fields": []}
        elif line.startswith("fixture "):
            current["label"] = line[8:]
        elif line == "|":
            current["lines"].append("")
        elif line.startswith("| "):
            current["lines"].append(line[2:])
        elif line.startswith("problem "):
            current["problems"].append(line[8:])
        elif line.startswith("field "):
            key, equals, value = line[6:].partition(" =")
            if not equals:
                raise ValueError("no ` = ` in " + line)
            current["fields"].append((key, value.lstrip(" ")))
        elif line == "end":
            found.append(current)
        else:
            raise ValueError("a line no case reads: " + line)
    return found


def field(meta, key):
    """A field as fixture-meta.cases renders it."""
    base = "F/" + meta.label
    head, at, tail = key.partition("@")
    if at and head == "levels":
        return " ".join(meta.levels_for(tail))
    if at and head == "status":
        return str(meta.status_at(tail))
    if at and head == "c-args":
        return " ".join(meta.c_args_for(tail))
    rendered = {
        "status": lambda: str(meta.status),
        "traps": lambda: "yes" if meta.traps else "no",
        "stream": lambda: meta.stream,
        "profile-count": lambda: str(meta.profile_count),
        "layout-evidence": lambda: "yes" if meta.layout_evidence else "no",
        "codes-normalized": lambda: ", ".join(meta.codes),
        "module-arguments": lambda: " ".join(meta.module_arguments(base)),
        "source-arguments": lambda: " ".join(meta.source_arguments(base)),
        "program-arguments": lambda: " ".join(meta.program_arguments(base)),
    }
    if key in rendered:
        return rendered[key]()
    if key in fixture_meta.KEYS:
        return meta.get(key, "")
    return "<no field %s>" % key


class FixtureMetaTest(unittest.TestCase):
    def test_the_table_is_read_as_the_test_program_reads_it(self):
        table = cases(TABLE.read_text(encoding="utf-8"))
        self.assertGreaterEqual(len(table), 20)
        for case in table:
            cls, _, name = case["label"].partition("/")
            with self.subTest(case["title"]):
                meta, problems = fixture_meta.parse(
                    "\n".join(case["lines"]) + "\n", cls, name)
                self.assertEqual(problems, case["problems"])
                if not problems:
                    for key, value in case["fields"]:
                        self.assertEqual(field(meta, key), value, key)

    def test_every_fixture_is_accepted(self):
        count = sum(1 for _ in fixture_meta.discover())
        self.assertGreater(count, 2000)

    def test_a_fault_names_the_fixture(self):
        with self.assertRaises(fixture_meta.FixtureError) as raised:
            meta, problems = fixture_meta.parse("class: runtime\n", "runtime")
            raise fixture_meta.FixtureError("runtime/x/fixture.meta", problems)
        self.assertIn("runtime/x/fixture.meta: missing required key: summary",
                      str(raised.exception))

    def test_levels_cover_every_target(self):
        self.assertEqual(set(fixture_meta.FAMILY_OF), set(fixture_meta.TARGETS))
        #  Each target's family is held to the test program's by a
        #  `levels@TARGET` field both readers render.
        rendered = {key[len("levels@"):]
                    for case in cases(TABLE.read_text())
                    for key, _ in case["fields"]
                    if key.startswith("levels@")}
        self.assertEqual(rendered, set(fixture_meta.TARGETS))

    def test_the_targets_are_the_compilers(self):
        #  The selection package's own table, which `refine --target=`
        #  reads; a name added there is a name a fixture may hold.
        self.assertEqual(fixture_meta.TARGETS[:3],
                         ("linux-x86-64", "linux-arm64", "darwin-arm64"))
        self.assertIn("rv32", fixture_meta.TARGETS)
        self.assertEqual(len(set(fixture_meta.TARGETS)),
                         len(fixture_meta.TARGETS))
        self.assertEqual(fixture_meta.described_targets(
            'function Described_Name (Index : Positive) return String is\n'
            '  (case Index is when 1 => "a-b", when 2 => "c",\n'
            '   when others => raise Compiler_Defect);\n'
            'function Described_At (Index : Positive) return Target_Facts is\n'
            '  (case Index is when 1 => "not-a-name");\n'), ("a-b", "c"))

    def test_the_families_are_the_compilers(self):
        #  Landin.Targets.Levels' families, each its subtype's range of
        #  Level_Id in order, the first its default, as the compiler
        #  spells them; which family a target has is fixture-meta.cases'.
        spec = (LEVELS.with_suffix(".ads")).read_text()
        body = (LEVELS.with_suffix(".adb")).read_text()
        ids = [one.strip() for one in re.search(
            r"type Level_Id is\s*\((.*?)\);", spec, re.S).group(1).split(",")]
        spelled = dict(re.findall(
            r'when (\w+)\s*=>\s*"([^"]+)"', re.search(
                r"function Spelled \(Id : Level_Id\).*?;", body,
                re.S).group(0)))
        ranges = dict((name, (first, last)) for name, first, last in
                      re.findall(r"subtype (\w+) is Level_Id range"
                                 r" (\w+) \.\. (\w+);", body))
        def function(name):
            #  A function's text, to the blank line after it.
            return body.split("function %s " % name, 1)[1].split("\n\n", 1)[0]
        in_family, defaults = function("In_Family"), function("Default_Level")
        families = []
        for subtype in re.findall(r"Id in (\w+)", in_family):
            first, last = ranges[subtype]
            members = ids[ids.index(first):ids.index(last) + 1]
            self.assertIn("=> %s," % first, defaults, subtype)
            families.append(tuple(spelled[one] for one in members))
        self.assertGreaterEqual(len(families), 5)
        self.assertEqual(sorted(families),
                         sorted(levels for levels
                                in fixture_meta.FAMILIES.values() if levels))


if __name__ == "__main__":
    unittest.main()
