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
