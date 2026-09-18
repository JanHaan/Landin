"""Tiny malformed controls for the roadmap-owned debt records."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from roadmap_debt import validate


class DebtTests(unittest.TestCase):
    def setUp(self):
        self.text = (ROOT / 'ROADMAP.md').read_text()

    def test_complete_intake(self):
        self.assertEqual(len(validate(self.text)), 36)

    def test_malformed_records(self):
        line = next(l for l in self.text.splitlines() if l.startswith('| R551-01 | defect |'))
        for replacement in (line.replace('R551-01', 'R551-02'),
                            line.replace(' | implemented |', ' | maybe |'), line.replace(' | R5.51 |', ' | R9.90 |'),
                            line.replace('Before the R5.51 closure candidate', ''),
                            line.rsplit('|', 2)[0] + ' | |',
                            line.replace('R551-01', 'R551-99'), line + '\n' + line, ''):
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                validate(self.text.replace(line, replacement))
        with self.assertRaises(ValueError):
            validate(self.text + '\nR551-99\n')
        with self.assertRaises(ValueError):
            validate(self.text.replace('| normative | scheduled |', '| normative | successor |'))

    def test_normative_completion_requires_completed_owner(self):
        line = next(l for l in self.text.splitlines()
                    if l.startswith('| R551-29 | normative |'))
        completed = line.replace('| scheduled | R7.20 |', '| implemented | R5.51 |')
        self.assertEqual(len(validate(self.text.replace(line, completed))), 36)
        with self.assertRaisesRegex(ValueError, 'complete owner'):
            validate(self.text.replace(line, line.replace('| scheduled |', '| implemented |')))


if __name__ == '__main__':
    unittest.main()
