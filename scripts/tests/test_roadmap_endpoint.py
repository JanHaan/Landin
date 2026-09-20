#!/usr/bin/env python3
"""Tiny malformed controls for R7.70's endpoint declaration.

Each control alters one thing the declaration is held to -- the anchors, the
block, an item's status, a ledger owner, an appendix owner or the list of
successor roadmaps -- and requires `validate_endpoint` to refuse the result.
The unaltered roadmap must produce the endpoint item and nothing else.
"""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from roadmap_debt import ENDPOINT_CLOSE, ENDPOINT_OPEN, validate_endpoint


class Endpoint(unittest.TestCase):
    def setUp(self):
        self.text = (ROOT / 'ROADMAP.md').read_text(encoding='utf-8')

    def block(self):
        return self.text.split(ENDPOINT_OPEN)[1].split(ENDPOINT_CLOSE)[0]

    def row(self, label):
        return next(line for line in self.text.splitlines()
                    if line.startswith('| %s ' % label))

    def refused(self, old, new, fragment):
        self.assertIn(old, self.text)
        with self.assertRaisesRegex(ValueError, fragment):
            validate_endpoint(self.text.replace(old, new, 1))

    def test_the_repository_declares_the_endpoint_it_has_reached(self):
        self.assertEqual(validate_endpoint(self.text), 'R7.70')

    def test_a_reached_endpoint_must_be_declared(self):
        undeclared = (self.text.replace(ENDPOINT_OPEN + '\n', '', 1)
                      .replace(ENDPOINT_CLOSE + '\n', '', 1))
        self.assertNotIn(ENDPOINT_OPEN, undeclared)
        with self.assertRaisesRegex(ValueError, 'nothing declares the endpoint'):
            validate_endpoint(undeclared)

    def test_a_declared_endpoint_must_have_been_reached(self):
        heading = '### R7.70 — Declare the roadmap endpoint\n\nStatus: complete'
        self.refused(heading, heading.replace('complete', 'planned'),
                     'these items are live: R7.70')
        self.refused(heading, heading.replace('complete', 'blocked'),
                     'these items are live: R7.70')
        #  An item somewhere else in the roadmap counts the same way: the
        #  declaration is about the whole list, not about its last entry.
        other = '### R7.10 — Audit every normative construct\n\nStatus: complete'
        self.refused(other, other.replace('complete', 'planned'),
                     'these items are live: R7.10')

    def test_the_declaration_is_one_block_and_says_something(self):
        self.refused(ENDPOINT_OPEN, ENDPOINT_OPEN + '\n' + ENDPOINT_OPEN,
                     'missing or repeated endpoint declaration')
        self.refused(ENDPOINT_CLOSE, '', 'missing or repeated endpoint declaration')
        self.refused(self.block(), '\n', 'says nothing')

    def test_the_declaration_names_the_last_work_item(self):
        self.refused('R7.70 is the last work item here.',
                     'This is the last work item here.',
                     'does not name the last work item R7.70')

    def test_every_transferred_record_names_a_successor(self):
        #  One control per register, because the three were checked in three
        #  places and only the endpoint reads them as one statement.
        for label, disposition, owner in (
                ('R551-06', 'successor', 'Scale and self-hosting'),
                ('R551-25', 'limit', 'Language evolution'),
                ('R551-28', 'watch', 'Language evolution'),
                ('R730-01', 'successor', 'Release readiness')):
            cells = '| %s | %s |' % (disposition, owner)
            line = self.row(label)
            self.assertIn(cells, line)
            with self.subTest(label=label):
                self.refused(line, line.replace(cells, '| %s | R7.10 |' % disposition),
                             'transferred with no named successor: ' + label)

    def test_a_transferred_appendix_row_names_a_successor(self):
        line = self.row('C3 —')
        self.assertIn('transfer to Language evolution', line)
        self.refused(line, line.replace('transfer to Language evolution',
                                        'transfer to R7.10', 1),
                     'transferred with no named successor: C3')

    def test_a_successor_nobody_transferred_to_is_not_an_owner(self):
        self.refused('\n## The endpoint\n',
                     '- **Nothing in particular:** a destination no record'
                     ' names.\n\n## The endpoint\n',
                     'named successor owns no durable record: Nothing in particular')


if __name__ == '__main__':
    unittest.main()
