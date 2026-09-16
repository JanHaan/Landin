"""Validate ROADMAP.md's retained-debt records; this module owns no work list."""
import re


def validate(text):
    def require(ok, message):
        if not ok:
            raise ValueError('R5.51 debt ledger: ' + message)
    start, end = '<!-- r551-ledger -->', '<!-- /r551-ledger -->'
    require(text.count(start) == text.count(end) == 1, 'missing or repeated ledger')
    ledger = text.split(start)[1].split(end)[0]
    require('| Intake | Kind | Disposition | Owner | Activation | Completion evidence |' in ledger,
            'missing field headings')
    owners = set(re.findall(r'^### (R\d+\.\d+) — ', text, re.M))
    successors = text.split('## Successor roadmaps\n', 1)[1].split('\n## ', 1)[0]
    owners.update(re.findall(r'^- \*\*([^:]+):\*\*', successors, re.M))
    kinds = {'defect', 'observation', 'supported-limit', 'evidence-gap', 'normative', 'parked-watch'}
    dispositions = {'do-now', 'implemented', 'scheduled', 'successor', 'limit', 'watch', 'superseded'}
    seen = set()
    for line in ledger.splitlines():
        if not line.startswith('|') or line.startswith(('| Intake ', '|---')):
            continue
        cells = [c.strip() for c in line.strip('|').split('|')]
        require(len(cells) == 6 and all(cells), 'incomplete record')
        label, kind, disposition, owner, trigger, evidence = cells
        require(re.fullmatch(r'R551-\d{2}', label), 'malformed intake identity')
        require(label not in seen, 'duplicate intake ' + label)
        seen.add(label)
        require(kind in kinds, 'unknown kind for ' + label)
        require(disposition in dispositions, 'unknown disposition for ' + label)
        require(owner in owners, 'dangling owner for ' + label + ': ' + owner)
        require(trigger.lower() not in {'-', 'tbd', 'todo', 'pending'}
                and evidence.lower() not in {'-', 'tbd', 'todo', 'pending'},
                'missing activation or completion obligation for ' + label)
        require(disposition != 'successor' or owner in re.findall(r'^- \*\*([^:]+):\*\*', successors, re.M),
                'successor disposition requires a named successor')
        require(kind != 'normative' or disposition == 'scheduled', 'normative work cannot be transferred')
    expected = {f'R551-{i:02}' for i in range(1, 37)}
    require(seen == expected, 'intake inventory differs from the 36-record plan')
    intake = text.split('#### Do now: R5.51 implementation scope\n')[1].split('#### Source-to-disposition crosswalk')[0]
    definitions = re.findall(r'^\| (R551-\d{2})(?:[: |])', intake, re.M)
    require(len(definitions) == len(set(definitions)) and set(definitions) == seen,
            'detailed intake and ledger disagree')
    require(set(re.findall(r'R551-\d+', text)) <= seen, 'dangling intake reference')
    for reference in re.findall(r'\bR\d+\.\d+\b', ledger):
        require(reference in owners, 'dangling roadmap reference ' + reference)
    return seen
