"""Validate ROADMAP.md's retained-debt records; this module owns no work list."""
import re

KINDS = {'defect', 'observation', 'supported-limit', 'evidence-gap', 'normative', 'parked-watch'}
LIVE = {'planned', 'active', 'blocked'}
PLACEHOLDERS = {'-', 'tbd', 'todo', 'pending'}


def statuses(text):
    return dict(re.findall(r'^### (R\d+\.\d+) — [^\n]+\n\nStatus: (\w+)$', text, re.M))


def successor_names(text):
    successors = text.split('## Successor roadmaps\n', 1)[1].split('\n## ', 1)[0]
    return re.findall(r'^- \*\*([^:]+):\*\*', successors, re.M)


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
    status = statuses(text)
    named = successor_names(text)
    owners.update(named)
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
        require(kind in KINDS, 'unknown kind for ' + label)
        require(disposition in dispositions, 'unknown disposition for ' + label)
        require(owner in owners, 'dangling owner for ' + label + ': ' + owner)
        require(trigger.lower() not in PLACEHOLDERS and evidence.lower() not in PLACEHOLDERS,
                'missing activation or completion obligation for ' + label)
        require(disposition != 'successor' or owner in named,
                'successor disposition requires a named successor')
        #  R7.30: scheduled work is a promise, and a finished item keeps none.
        require(disposition != 'scheduled' or status.get(owner) in LIVE,
                'scheduled work needs a live owner: ' + label)
        require(kind != 'normative' or disposition in {'scheduled', 'implemented'},
                'normative work cannot be transferred')
        if kind == 'normative' and disposition == 'implemented':
            require(re.search(r'^### ' + re.escape(owner) + r' — [^\n]+\n\nStatus: complete$',
                              text, re.M),
                    'implemented normative work needs a complete owner: ' + label)
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


def validate_discoveries(text):
    """R7.30: every limit, watch or observation recorded after R5.51's intake.

    Each record names where it was found, what it is and one disposition. A
    closed one cites a finished owner, a scheduled one a live item, a merged
    one an existing R5.51 record or inherited row, and a transfer one named
    successor; the last three carry the activation and completion evidence a
    later owner inherits rather than a heading.
    """
    def require(ok, message):
        if not ok:
            raise ValueError('R7.30 discovery ledger: ' + message)
    start, end = '<!-- r730-ledger -->', '<!-- /r730-ledger -->'
    require(text.count(start) == text.count(end) == 1, 'missing or repeated ledger')
    ledger = text.split(start)[1].split(end)[0]
    require('| Discovery | Source and limit | Kind | Disposition | Owner | Activation | '
            'Completion evidence |' in ledger, 'missing field headings')
    status = statuses(text)
    named = set(successor_names(text))
    records = set(re.findall(r'^\| (R551-\d{2}) \|',
                             text.split('<!-- r551-ledger -->', 1)[-1].split('<!-- /r551-ledger -->')[0],
                             re.M))
    appendix = text.split('\n## Inherited review register and migration parity\n', 1)
    if len(appendix) == 2:
        records.update(re.findall(r'^\| ([A-F]\d) — ', appendix[1].split('\n## ', 1)[0], re.M))
    closed = {'implemented', 'rejected', 'superseded'}
    transferred = {'successor', 'limit', 'watch'}
    seen = []
    for line in ledger.splitlines():
        if not line.startswith('|') or line.startswith(('| Discovery ', '|---')):
            continue
        cells = [c.strip() for c in line.strip('|').split('|')]
        require(len(cells) == 7 and all(cells), 'incomplete record')
        label, source, kind, disposition, owner, trigger, evidence = cells
        require(re.fullmatch(r'R730-\d{2}', label), 'malformed discovery identity')
        require(label not in seen, 'duplicate discovery ' + label)
        seen.append(label)
        found = re.findall(r'\bR\d+\.\d+\b', source)
        require(all(item in status for item in found), 'dangling source for ' + label)
        require(any(item.split('.')[0] in {'R6', 'R7'} for item in found),
                'no item after R5.51 records ' + label)
        require(kind in KINDS, 'unknown kind for ' + label)
        require(disposition in closed | transferred | {'scheduled', 'merged'},
                'unknown disposition for ' + label)
        require(trigger.lower() not in PLACEHOLDERS and evidence.lower() not in PLACEHOLDERS,
                'missing activation or completion obligation for ' + label)
        if disposition in closed:
            require(status.get(owner) == 'complete', 'closed disposition needs a finished owner: ' + label)
        elif disposition == 'scheduled':
            require(status.get(owner) in LIVE, 'scheduled work needs a live owner: ' + label)
        elif disposition == 'merged':
            require(owner in records, 'merged into a missing record: ' + label)
        else:
            require(owner in named, 'successor disposition requires a named successor: ' + label)
        require(kind != 'normative' or disposition in {'implemented', 'scheduled', 'rejected'},
                'normative work cannot be transferred')
    require(seen == [f'R730-{i:02}' for i in range(1, len(seen) + 1)] and seen,
            'discovery labels are not contiguous from R730-01')
    require(set(re.findall(r'R730-\d+', text)) <= set(seen), 'dangling discovery reference')
    return set(seen)


TRANSFERRING = {'successor', 'limit', 'watch', 'transferred'}
ENDPOINT_OPEN, ENDPOINT_CLOSE = '<!-- roadmap-endpoint -->', '<!-- /roadmap-endpoint -->'


def durable_records(text):
    """(label, disposition, owner cell) for every durable record there is.

    The R5.51 ledger, the R7.30 ledger and the inherited review register each
    own their own rules elsewhere; the endpoint is the one claim that spans
    all three, so they are read together here. A ledger owner is a cell and an
    appendix owner is a sentence, which is why the caller matches by name.
    """
    out = []
    for start, end, disposition_at, owner_at in (
            ('<!-- r551-ledger -->', '<!-- /r551-ledger -->', 2, 3),
            ('<!-- r730-ledger -->', '<!-- /r730-ledger -->', 3, 4)):
        if text.count(start) != 1 or text.count(end) != 1:
            continue
        for line in text.split(start)[1].split(end)[0].splitlines():
            cells = [c.strip() for c in line.strip('|').split('|')]
            if len(cells) > owner_at and re.fullmatch(r'R\d{3}-\d{2}', cells[0]):
                out.append((cells[0], cells[disposition_at], cells[owner_at]))
    appendix = text.split('\n## Inherited review register and migration parity\n', 1)
    if len(appendix) == 2:
        for line in appendix[1].split('\n## ', 1)[0].splitlines():
            cells = [c.strip() for c in line.strip('|').split('|')]
            found = re.match(r'([A-F]\d) — ', cells[0]) if cells else None
            if found and len(cells) == 5:
                out.append((found.group(1), cells[3], cells[2]))
    return out


def validate_endpoint(text):
    """R7.70: the roadmap declares an endpoint exactly when it has reached one.

    Both directions, because only one of them is the interesting failure. A
    declaration beside a live item is a false claim; a roadmap whose last item
    is complete and whose prose still points forward is the drift that arrives
    the first time somebody adds a successor item here instead of to the
    roadmap that owns it. Neither state can be reached without this failing.

    The transfers are held the same way. At the endpoint no durable record may
    still be owed by a roadmap item, because every item is finished; and a
    successor family that owns no record at all is documentation of a
    direction rather than an owner, which is a different thing and should not
    be able to pass as one.
    """
    def require(ok, message):
        if not ok:
            raise ValueError('roadmap endpoint: ' + message)
    require(text.count(ENDPOINT_OPEN) == text.count(ENDPOINT_CLOSE) <= 1,
            'missing or repeated endpoint declaration')
    status = statuses(text)
    require(bool(status), 'no work items to reach an endpoint with')
    live = sorted(one for one, state in status.items() if state in LIVE)
    if text.count(ENDPOINT_OPEN) != 1:
        require(live, 'every work item is complete and nothing declares the endpoint')
        return None
    require(not live, 'the endpoint is declared and these items are live: '
            + ', '.join(live))
    block = text.split(ENDPOINT_OPEN)[1].split(ENDPOINT_CLOSE)[0]
    require(block.strip(), 'the endpoint declaration says nothing')
    last = re.findall(r'^### (R\d+\.\d+) — ', text, re.M)[-1]
    require(re.search(r'\b%s\b' % re.escape(last), block),
            'the endpoint declaration does not name the last work item ' + last)
    named = successor_names(text)
    require(named, 'the endpoint names no successor roadmap')
    owed, owning = [], set()
    for label, disposition, owner in durable_records(text):
        if disposition not in TRANSFERRING:
            #  A closed record cites a finished item, and its own rule already
            #  says so. Only a transfer makes a successor an owner, so only a
            #  transfer counts towards one below.
            continue
        found = [name for name in named if name in owner]
        if not found:
            owed.append(label)
        owning.update(found)
    require(not owed, 'transferred with no named successor: ' + ', '.join(owed))
    idle = [name for name in named if name not in owning]
    require(not idle, 'named successor owns no durable record: ' + ', '.join(idle))
    return last
