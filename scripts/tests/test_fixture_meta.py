"""The Python fixture reader means what the test program's reader means.

compiler/tests/fixture-meta.cases is the table both readers are held to:
this module holds compiler/tests/fixture_meta.py to it, and the test
program's `fixtures/the metadata readers agree` holds
`Landin.Testing.Fixtures`.  The corpus itself is read here too, so a key
the Python reader refuses and the test program accepts cannot sit in a
fixture unnoticed.
"""

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "compiler/tests"))

import fixture_meta  # noqa: E402

TABLE = ROOT / "compiler/tests/fixture-meta.cases"


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
    rendered = {
        "status": lambda: str(meta.status),
        "traps": lambda: "yes" if meta.traps else "no",
        "stream": lambda: meta.stream,
        "profile-count": lambda: str(meta.profile_count),
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


if __name__ == "__main__":
    unittest.main()
