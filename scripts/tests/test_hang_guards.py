#!/usr/bin/env python3
"""Hold every script test's subprocess timeout to the shared hang guard.

A timeout on a subprocess in `scripts/tests` is a hang guard: the command
answers in well under a second on an idle host, and the limit only stops a
test that would otherwise wait for ever.  `scripts/script_tests.py` runs
the modules beside up to fifteen other workers, though, and a host load
near 50 has stretched five-second and one-second limits past their end, so
ten tests failed in turn for no defect, each found by its own failure.

The guard is stated once, here: a subprocess timeout in a script test is at
least FLOOR seconds.  An answer ends the wait, so a wide limit costs
nothing where the command answers.  Every `subprocess.run`, `call`,
`check_call` and `check_output` in `scripts/tests`, and every
`.communicate`, whose `timeout=` is a number, or a module constant that is
one, is read, and one below the floor is refused with its file and line.
A timeout this cannot read as a number is refused too, so a limit cannot
hide in an expression.

A test whose subject is the expiry itself -- it runs a command that
sleeps and expects the timeout -- says so with a comment holding
`expires on purpose` on a line of the call, and is not held to the floor.
Waits inside one process, on a queue, a thread or a future, are not
subprocess guards and are not read.
"""
import ast
import sys
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
#  Seconds.  The lowest limit any load-sensitive failure left standing.
FLOOR = 60
EXEMPT = "expires on purpose"
GUARDED = ("run", "call", "check_call", "check_output")


def constants(tree):
    """The module's top-level names bound once to a number."""
    found, seen = {}, set()
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            if not isinstance(target, ast.Name):
                continue
            if target.id in seen:
                found.pop(target.id, None)
                continue
            seen.add(target.id)
            value = number(node.value, found)
            if value is not None:
                found[target.id] = value
    return found


def number(node, names):
    """NODE's value when it is a number, a named one, or their arithmetic."""
    if isinstance(node, ast.Constant) and type(node.value) in (int, float):
        return node.value
    if isinstance(node, ast.Name):
        return names.get(node.id)
    if isinstance(node, ast.BinOp):
        left, right = number(node.left, names), number(node.right, names)
        if left is None or right is None:
            return None
        if isinstance(node.op, ast.Mult):
            return left * right
        if isinstance(node.op, ast.Add):
            return left + right
    return None


def guards(call):
    """Whether CALL starts or waits on a subprocess with a timeout."""
    function = call.func
    if not isinstance(function, ast.Attribute):
        return False
    if function.attr == "communicate":
        return True
    return (function.attr in GUARDED and isinstance(function.value, ast.Name)
            and function.value.id == "subprocess")


def problems(source, name):
    """Each subprocess timeout in SOURCE below the floor, as a refusal."""
    tree = ast.parse(source)
    names = constants(tree)
    lines = source.splitlines()
    found = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not guards(node):
            continue
        for keyword in node.keywords:
            if keyword.arg != "timeout":
                continue
            if any(EXEMPT in line
                   for line in lines[node.lineno - 1:node.end_lineno]):
                continue
            value = number(keyword.value, names)
            where = "%s:%d" % (name, keyword.value.lineno)
            if value is None:
                found.append(
                    "%s: a subprocess timeout that is not a number or a "
                    "module constant; name a constant of at least %d "
                    "seconds, or say `%s` in a comment on the call"
                    % (where, FLOOR, EXEMPT))
            elif value < FLOOR:
                found.append(
                    "%s: a subprocess timeout of %s seconds is below the "
                    "%d-second hang guard scripts/tests/test_hang_guards.py "
                    "states; a loaded host stretches a short limit past its "
                    "end, so widen it, or say `%s` in a comment on the call "
                    "when the expiry is what the test is about"
                    % (where, value, FLOOR, EXEMPT))
    return found


class HangGuards(unittest.TestCase):
    def test_no_script_test_guards_a_subprocess_below_the_floor(self):
        found = []
        for path in sorted(TESTS.glob("*.py")):
            found += problems(path.read_text(encoding="utf-8"), path.name)
        self.assertEqual(found, [], "\n" + "\n".join(found))

    def test_a_thin_literal_and_a_thin_constant_are_refused(self):
        source = ("import subprocess\nSHORT = 5\n"
                  "subprocess.run(['true'], timeout=1)\n"
                  "subprocess.check_output(['true'],\n"
                  "                        timeout=2 * SHORT)\n"
                  "process.communicate(timeout=0.5)\n")
        found = problems(source, "test_sample.py")
        self.assertEqual([line.split(": ", 1)[0] for line in found],
                         ["test_sample.py:3", "test_sample.py:5",
                          "test_sample.py:6"])
        self.assertIn("a subprocess timeout of 10 seconds is below the "
                      "60-second hang guard", found[1])

    def test_a_timeout_that_cannot_be_read_is_refused(self):
        source = ("import subprocess\n"
                  "def run(limit):\n"
                  "    subprocess.run(['true'], timeout=limit)\n")
        found = problems(source, "test_sample.py")
        self.assertEqual(len(found), 1)
        self.assertIn("test_sample.py:3: a subprocess timeout that is not a "
                      "number or a module constant", found[0])

    def test_the_floor_and_a_wider_constant_pass(self):
        source = ("import subprocess\nHANG = 300\n"
                  "subprocess.run(['true'], timeout=60)\n"
                  "subprocess.run(['true'], timeout=HANG)\n"
                  "subprocess.run(['true'], timeout=2 * HANG)\n")
        self.assertEqual(problems(source, "test_sample.py"), [])

    def test_an_expiry_that_is_the_subject_says_so(self):
        source = ("import subprocess\n"
                  "subprocess.run(['sleep', '60'],\n"
                  "               timeout=0.1)  # expires on purpose\n")
        self.assertEqual(problems(source, "test_sample.py"), [])

    def test_waits_inside_one_process_are_not_read(self):
        source = ("notices.get(timeout=2)\nfuture.result(timeout=0.5)\n"
                  "mock.assert_called_once_with(['x'], timeout=10)\n")
        self.assertEqual(problems(source, "test_sample.py"), [])


if __name__ == "__main__":
    sys.exit(unittest.main())
