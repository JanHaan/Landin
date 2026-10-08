"""Expand the roadmap's declared execution order without changing identities."""
import re


def execution_order(text, identities):
    """Require each work item exactly once, through a phase or an item selector."""
    identities = list(identities)
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
            seen.add(identity)
            ordered.append(identity)
    missing = [identity for identity in identities if identity not in seen]
    if missing:
        raise ValueError("execution order omits " + ", ".join(missing))
    return ordered
