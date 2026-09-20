"""Tiny malformed controls for the roadmap-owned debt records."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from roadmap_debt import validate, validate_discoveries


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
            validate(self.text.replace('| normative | implemented | R7.20 |',
                                       '| normative | successor | Language evolution |'))

    def test_normative_completion_requires_completed_owner(self):
        line = next(l for l in self.text.splitlines()
                    if l.startswith('| R551-29 | normative |'))
        self.assertIn('| implemented | R7.20 |', line)
        scheduled = line.replace('| implemented | R7.20 |', '| scheduled | R7.60 |')
        self.assertEqual(len(validate(self.text.replace(line, scheduled))), 36)
        with self.assertRaisesRegex(ValueError, 'complete owner'):
            validate(self.text.replace(line, line.replace('| R7.20 |', '| R7.60 |')))

    def test_scheduled_work_needs_a_live_owner(self):
        #  R551-35 was scheduled on R7.30 until R7.30 transferred it, and
        #  R551-17 and R551-30 on R7.40 until R7.40 implemented them.  No
        #  record is scheduled now, so the control builds one: the rule is
        #  about the ledger's vocabulary and not about today's contents.
        self.assertNotIn('| scheduled |', self.ledger())
        line = next(l for l in self.text.splitlines() if l.startswith('| R551-17 |'))
        self.assertIn('| implemented | R7.40 |', line)
        live = line.replace('| implemented | R7.40 |', '| scheduled | R7.60 |')
        self.assertEqual(len(validate(self.text.replace(line, live))), 36)
        finished = line.replace('| implemented | R7.40 |', '| scheduled | R7.40 |')
        with self.assertRaisesRegex(ValueError, 'live owner: R551-17'):
            validate(self.text.replace(line, finished))
        heading = ('### R7.60 — Run complete derived prototype'
                   ' coverage\n\nStatus: planned')
        self.assertIn(heading, self.text)
        with self.assertRaisesRegex(ValueError, 'live owner'):
            validate(self.text.replace(line, live)
                     .replace(heading, heading.replace('planned', 'complete')))
        self.assertIn('| R551-35 | parked-watch | successor | Language evolution |', self.text)

    def ledger(self):
        return self.text.split('<!-- r551-ledger -->')[1].split('<!-- /r551-ledger -->')[0]


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.text = (ROOT / 'ROADMAP.md').read_text()

    def line(self, label):
        return next(l for l in self.text.splitlines() if l.startswith('| %s |' % label))

    def refused(self, old, new, fragment):
        self.assertIn(old, self.text)
        with self.assertRaisesRegex(ValueError, fragment):
            validate_discoveries(self.text.replace(old, new, 1))

    def test_complete_ledger(self):
        self.assertEqual(len(validate_discoveries(self.text)), 24)

    def test_identities_are_unique_and_contiguous(self):
        line = self.line('R730-02')
        self.refused(line, line.replace('R730-02', 'R730-01'), 'duplicate discovery')
        self.refused(line + '\n', '', 'not contiguous')
        self.refused(line, line.replace('R730-02', 'R730-2'), 'malformed discovery identity')
        self.refused('<!-- /r730-ledger -->', '<!-- /r730-ledger -->\nR730-99',
                     'dangling discovery reference')

    def test_closed_vocabularies_and_obligations(self):
        line = self.line('R730-03')
        self.refused(line, line.replace('| evidence-gap |', '| worry |'), 'unknown kind')
        self.refused(line, line.replace('| successor |', '| deferred |'), 'unknown disposition')
        self.refused(line, line.rsplit(' | ', 1)[0] + ' | TBD |', 'missing activation')
        self.refused(line, line.replace('| R730-03 | R6.30:', '| R730-03 | R5.51:'),
                     'no item after R5.51')
        self.refused(line, line.replace('| R730-03 | R6.30:', '| R730-03 | R6.35:'),
                     'dangling source')

    def test_owner_fits_the_disposition(self):
        self.refused(self.line('R730-01'), self.line('R730-01').replace(
            '| Release readiness |', '| Somebody |'), 'requires a named successor')
        #  R730-16 was scheduled on R7.40 until R7.40 implemented it, so the
        #  scheduled control now makes one out of it and moves its owner.
        scheduled = self.line('R730-16').replace(
            '| implemented | R7.40 |', '| scheduled | R7.60 |')
        self.refused(self.line('R730-16'), scheduled.replace(
            '| R7.60 |', '| R7.20 |'), 'scheduled work needs a live owner')
        self.refused(self.line('R730-14'), self.line('R730-14').replace(
            '| R6.40 |', '| R7.60 |'), 'closed disposition needs a finished owner')
        self.refused(self.line('R730-02'), self.line('R730-02').replace(
            '| R551-34 |', '| R551-99 |'), 'merged into a missing record')
        self.refused(self.line('R730-10'), self.line('R730-10').replace(
            '| C1 |', '| C9 |'), 'merged into a missing record')

    def test_normative_work_cannot_be_transferred(self):
        line = self.line('R730-17')
        self.refused(line, line.replace('| observation |', '| normative |'),
                     'normative work cannot be transferred')


if __name__ == '__main__':
    unittest.main()
