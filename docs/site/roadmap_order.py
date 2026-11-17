"""Expand the roadmap's declared execution order without changing identities."""
import re


def continuous_items(text, identities):
    """The items the `Continuous:` line puts in the continuous lane.

    `Continuous: ITEM onward` names ITEM and every later item of its
    phase; a roadmap without the line has no continuous lane.
    """
    lines = [line for line in text.splitlines()
             if line.startswith("Continuous:")]
    if not lines:
        return []
    if len(lines) != 1:
        raise ValueError("expected at most one Continuous line, found %d"
                         % len(lines))
    match = re.fullmatch(r"Continuous: (R(\d+)\.([1-9]\d*)) onward", lines[0])
    if not match:
        raise ValueError("malformed Continuous line")
    if match.group(1) not in identities:
        raise ValueError("the continuous lane starts at unknown "
                         + match.group(1))
    phase, first = match.group(2), int(match.group(3))
    return [identity for identity in identities
            if identity.split(".")[0] == "R" + phase
            and int(identity.split(".")[1]) >= first]


def execution_order(text, identities):
    """Require each work item exactly once, through a phase or an item selector.

    The serial lane is the `Execution order:` line; the items of the
    continuous lane follow it, in identity order, and may not be selected
    by it as well.
    """
    identities = list(identities)
    continuous = continuous_items(text, identities)
    lines = [line for line in text.splitlines()
             if line.startswith("Execution order:")]
    if len(lines) != 1:
        raise ValueError("expected one Execution order line, found %d" % len(lines))
    match = re.fullmatch(
        r"Execution order: (R\d+(?:\.[1-9]\d*)?"
        r"(?:, R\d+(?:\.[1-9]\d*)?)*)", lines[0])
    if not match:
        raise ValueError("malformed Execution order line")
    ordered = []
    seen = set()
    for selector in match.group(1).split(", "):
        selected = ([selector] if selector in identities else
                    [identity for identity in identities
                     if identity.startswith(selector + ".")])
        if not selected:
            raise ValueError("execution order selects unknown " + selector)
        for identity in selected:
            if identity in seen:
                raise ValueError("execution order repeats " + identity)
            if identity in continuous:
                raise ValueError("execution order selects %s, which the"
                                 " continuous lane holds" % identity)
            seen.add(identity)
            ordered.append(identity)
    missing = [identity for identity in identities
               if identity not in seen and identity not in continuous]
    if missing:
        raise ValueError("execution order omits " + ", ".join(missing))
    return ordered + continuous


def dependency_items(name, identities):
    """The items a dependency NAME stands for: itself, or a whole phase's."""
    if "." in name:
        return [name]
    return [identity for identity in identities
            if identity.startswith(name + ".")]


ITEM_HEADING = re.compile(r"^### (R\d+\.[1-9]\d*) — (\S.*)$")
ITEM_STATUS = re.compile(r"^Status: (planned|active|blocked|complete)$")


def roadmap_items(text):
    """{identity: item} of every work item, in the order the file has them.

    An item is its heading's title and line, and from the lines under it
    up to the next heading: its status, its dependencies, the reason a
    blocked item gives, and whether it returns promotion to the
    maintainer.  The lines are read wherever they stand under the heading,
    so a `Blocked because:` line between the status and the dependencies
    hides neither.
    """
    items = {}
    current = None
    for n, line in enumerate(text.splitlines(), 1):
        heading = ITEM_HEADING.match(line)
        if heading:
            current = dict(key=heading.group(1), title=heading.group(2),
                           line=n, status=None, depends=[], blocked=None,
                           promotion=None)
            if heading.group(1) in items:
                raise ValueError("roadmap repeats " + heading.group(1))
            items[heading.group(1)] = current
        elif line.startswith(("## ", "### ")):
            current = None
        elif current is None:
            continue
        elif ITEM_STATUS.match(line):
            current["status"] = ITEM_STATUS.match(line).group(1)
        elif line.startswith("Depends on:"):
            current["depends"] = [
                name.strip() for name in line[len("Depends on:"):].split(",")
                if name.strip() and name.strip() != "none"]
        elif line.startswith("Blocked because:"):
            current["blocked"] = line[len("Blocked because:"):].strip()
        elif line.startswith("Promotion:"):
            current["promotion"] = line[len("Promotion:"):].strip()
    return items


def waiting_on(item, items):
    """The dependencies of ITEM that are not complete, in its own order."""
    return [one for name in item["depends"]
            for one in dependency_items(name, items)
            if items.get(one, {}).get("status") != "complete"]


def lane_state(text, items=None):
    """Where the serial lane stands, and what runs beside it.

    The lanes run in execution order: the serial lane's items, then the
    continuous lane's.  The serial lane's item is the first in that order
    that is active, or planned with every dependency complete; a blocked
    item, and one still waiting, are passed over.  It is `current` when
    active and `next` when planned.  Every other active item runs beside
    it: a continuous item, or an item of a serial phase whose dependencies
    were complete and that started early.  With nothing planned, active or
    blocked left, the roadmap is at its `endpoint`, its last item.  With
    work left and none of it able to start, the kind is None and the
    caller refuses it: a stalled roadmap is not an endpoint.

    Returns (kind, identity or None, [identities beside it], order).
    """
    if items is None:
        items = roadmap_items(text)
    order = execution_order(text, items)
    live = [key for key in order
            if items[key]["status"] in ("planned", "active", "blocked")]
    if order and not live:
        return "endpoint", order[-1], [], order
    pointer = next((key for key in order
                    if items[key]["status"] == "active"
                    or items[key]["status"] == "planned"
                    and not waiting_on(items[key], items)), None)
    beside = [key for key in order
              if items[key]["status"] == "active" and key != pointer]
    if pointer is None:
        return None, None, beside, order
    kind = "current" if items[pointer]["status"] == "active" else "next"
    return kind, pointer, beside, order
