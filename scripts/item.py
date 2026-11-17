#!/usr/bin/env python3
"""Run a roadmap item from start to finish: every step that needs no agent.

    python3 scripts/item.py start ITEM          # worktree, branch, brief, identities
    python3 scripts/item.py resume [ITEM]       # where a reopened session stands
    python3 scripts/item.py note ITEM TEXT      # one line in the item's journal
    python3 scripts/item.py run ITEM NAME --limit S -- COMMAND ...
    python3 scripts/item.py gate ITEM [--watch] # the gate runs of the branch head
    python3 scripts/item.py boards ITEM [--watch]  # dispatch scope=boards
    python3 scripts/item.py promote ITEM        # check the evidence, push to main
    python3 scripts/item.py finish ITEM         # remove worktree and branches
    python3 scripts/item.py status              # every item this clone runs
    python3 scripts/item.py stalled             # active items nothing moves
    python3 scripts/item.py report ITEM         # the report, with what is known

An item's state lives on disk, not in a session: a directory per item under
the clone's common Git directory, `landin-items/ITEM/`, which every worktree
of the clone shares and no worktree removal deletes.  It holds `state.json`
(branch, worktree, base, reserved identities, runs and gate runs),
`journal.md` (one dated line per `note`), `brief.md` (what `start` wrote for
the agent) and `runs/`, the retained directories of the item's detached
`scripts/run_logged.py` runs.  A session that is reopened, by a restart, a
resume or a change of account, runs `resume` and continues from what it
prints; nothing it needs is only in the conversation.

`start` reads the item from ROADMAP.md at the base, refuses one that is
complete or whose dependencies are not, makes the worktree and branch from
the base, reserves identities no other running item of this clone holds
(decisions, register rows and questions, each a block of numbers that
`scripts/register_next.py` then gives out first), marks the item active,
moves the README.md and handoff.md pointer from the next form to the
current one when it names the item, commits that, and writes the brief.

`promote` pushes the branch head to main only when the head is the branch's
pushed head, main is its ancestor, a push gate on the head passed with every
job of its listing passed or skipped, and a boards dispatch passed on the
same tree, or on an earlier commit from which every later commit says
`Gate: explanatory`.  It does not follow main's gate: `gate --main --watch`
does, and `finish` refuses until main's gate on the promoted commit passed.
Releases and versions are never this script's.
"""
import argparse
import datetime
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
#  The clone the item runs in; --repo names another, as the tests do.
REPOSITORY = [ROOT]
STATE_DIRECTORY = "landin-items"
DONE_DIRECTORY = "done"
#  How many of each identity an item reserves when it starts.
BLOCKS = {"D": 20, "SR": 10, "Q": 5}
DECISION = re.compile(r"\bD(\d{2,})\b")
ITEM = re.compile(r"R(\d+)\.(\d+)")
PHASE_OR_ITEM = re.compile(r"R\d+(?:\.[1-9]\d*)?")
CURRENT = "**Current roadmap work: %s — %s.**"
NEXT = "**Next roadmap item: %s — %s (planned).**"
POINTER_FILES = ("README.md", "handoff.md")
EXPLANATORY = "Gate: explanatory"
#  An item nothing has moved for this long is reported as stalled.
STALL_MINUTES = 60
PHASES = ("started", "pushed", "gate-passed", "boards-passed", "promoted",
          "main-passed", "finished")


class Refused(Exception):
    """A step that must not be taken, with what to do instead."""


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def stamp():
    return now().isoformat().replace("+00:00", "Z")


def repository(cwd=None):
    return cwd if cwd is not None else REPOSITORY[0]


def git(*arguments, cwd=None, check=True):
    result = subprocess.run(["git", *arguments], cwd=repository(cwd), text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise Refused("git %s failed: %s" % (" ".join(arguments),
                                             result.stderr.strip()))
    return result.stdout.strip() if result.returncode == 0 else None


def gh(*arguments):
    result = subprocess.run(["gh", *arguments], cwd=repository(), text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise Refused("gh %s failed: %s" % (" ".join(arguments),
                                            result.stderr.strip()))
    return json.loads(result.stdout) if result.stdout.strip() else None


def main_checkout(cwd=None):
    """The clone's main worktree, which outlives every item's."""
    listing = git("worktree", "list", "--porcelain", cwd=cwd)
    return Path(listing.splitlines()[0].split(" ", 1)[1])


def place(state):
    """Where to ask Git about STATE's item: its worktree while it exists,
    the clone's main checkout once it is gone."""
    worktree = Path(state["worktree"])
    return worktree if worktree.is_dir() else main_checkout()


def slug(item):
    return item.lower().replace(".", "-")


# ---------------------------------------------------------------- the roadmap

def roadmap_items(text):
    """Every item: its title, status, dependencies, promotion line and the
    line its heading is on."""
    items, order = {}, []
    lines = text.splitlines()
    for n, line in enumerate(lines):
        found = re.match(r"^### (R\d+\.\d+) — (\S.*)$", line)
        if not found:
            continue
        identity = found.group(1)
        entry = {"title": found.group(2), "line": n + 1, "status": None,
                 "depends": [], "maintainer": False}
        for following in lines[n + 1:]:
            if following.startswith("#"):
                break
            if following.startswith("Status: "):
                entry["status"] = following.split(": ", 1)[1].strip()
            elif following.startswith("Depends on: "):
                value = following.split(": ", 1)[1].strip()
                entry["depends"] = ([] if value == "none"
                                    else PHASE_OR_ITEM.findall(value))
            elif following.strip() == "Promotion: maintainer":
                entry["maintainer"] = True
        items[identity] = entry
        order.append(identity)
    return items, order


def unmet(items, item):
    """The dependencies of ITEM that are not complete."""
    missing = []
    for needed in items[item]["depends"]:
        if "." in needed:
            if items.get(needed, {}).get("status") != "complete":
                missing.append(needed)
        else:
            missing.extend(other for other, entry in items.items()
                           if other.split(".")[0] == needed
                           and entry["status"] != "complete")
    return missing


def roadmap_at(revision, cwd=None):
    return git("show", "%s:ROADMAP.md" % revision, cwd=cwd)


# -------------------------------------------------------------------- state

def common_directory(cwd=None):
    path = Path(git("rev-parse", "--git-common-dir", cwd=cwd))
    return path if path.is_absolute() else (Path(repository(cwd)) / path).resolve()


def state_root(cwd=None):
    return common_directory(cwd) / STATE_DIRECTORY


def item_directory(item, cwd=None):
    return state_root(cwd) / item


def load(item, cwd=None):
    path = item_directory(item, cwd) / "state.json"
    if not path.exists():
        done = state_root(cwd) / DONE_DIRECTORY / item / "state.json"
        if done.exists():
            raise Refused("%s is finished; its state is in %s"
                          % (item, done.parent))
        raise Refused("this clone runs no item %s: `item.py start %s` starts"
                      " it, `item.py status` lists those it runs"
                      % (item, item))
    return json.loads(path.read_text(encoding="utf-8"))


def save(state, cwd=None):
    directory = item_directory(state["item"], cwd)
    directory.mkdir(parents=True, exist_ok=True)
    state["updated"] = stamp()
    temporary = directory / "state.json.tmp"
    temporary.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, directory / "state.json")


def journal(item, text, cwd=None):
    directory = item_directory(item, cwd)
    directory.mkdir(parents=True, exist_ok=True)
    with (directory / "journal.md").open("a", encoding="utf-8") as stream:
        stream.write("- %s %s\n" % (stamp(), " ".join(text.split())))


def running_states(cwd=None):
    root = state_root(cwd)
    if not root.is_dir():
        return []
    states = []
    for path in sorted(root.glob("*/state.json")):
        states.append(json.loads(path.read_text(encoding="utf-8")))
    return states


def reserved(cwd=None, exclude=None):
    """The identity blocks running items hold: {kind: [(low, high, item)]}."""
    blocks = {kind: [] for kind in BLOCKS}
    for state in running_states(cwd):
        if state["item"] == exclude:
            continue
        for kind, (low, high) in state.get("reserved", {}).items():
            blocks.setdefault(kind, []).append((low, high, state["item"]))
    return blocks


def item_of_branch(cwd):
    """The running item whose branch CWD has checked out, or None."""
    branch = git("rev-parse", "--abbrev-ref", "HEAD", cwd=cwd, check=False)
    for state in running_states(cwd):
        if state["branch"] == branch:
            return state["item"]
    return None


def next_free(used, blocks, size):
    """The low end of SIZE free numbers past USED and every block."""
    start = max(used | {0}) + 1
    for low, high, _ in sorted(blocks):
        if high >= start:
            start = max(start, high + 1)
    return start, start + size - 1


def decisions_used(revision, cwd):
    spec = git("show", "%s:spec.md" % revision, cwd=cwd, check=False) or ""
    return {int(n) for n in DECISION.findall(spec)}


def reserve(item, revision, cwd):
    sys.path.insert(0, str(ROOT / "scripts"))
    import register_next
    others = reserved(cwd, exclude=item)
    used = {"D": decisions_used(revision, cwd),
            "SR": register_next.taken(str(repository(cwd))),
            "Q": register_next.taken(str(repository(cwd)), question=True)}
    return {kind: list(next_free(used[kind], others.get(kind, []), size))
            for kind, size in BLOCKS.items()}


# -------------------------------------------------------------------- start

BRIEF = """\
# {item} — {title}

You carry out roadmap item {item} of Landin. Its text is in ROADMAP.md
under "### {item}" (line {line} at the base); read it, the Mechanics
section and the rows and questions it names, not the file whole. Follow
AGENTS.md, docs/process.md's current loop and its closing checklist, and
the skill landin-change, which takes the item through this script's steps.

Where things are:
- Worktree {worktree}, branch {branch}, made from {base}. Work only there;
  the clone's other checkouts are not yours.
- State on disk: {state}. After any reopen, or when unsure, run
  `python3 scripts/item.py resume {item}` first and continue from it.
- Reserved identities, no other running item of this clone holds them:
  decisions D{D[0]}-D{D[1]}, register rows SR-{SR[0]}-{SR[1]} and questions
  Q-{Q[0]}-{Q[1]}. `scripts/register_next.py` gives these out first.

Running beside it:
{beside}

What you may do without asking: {authority} Releases and versions never.
A decision only the maintainer can take is a question file
(`python3 scripts/register_next.py --question --file --asked-by {item}`);
carry on with its default and with everything its answer cannot change.

Your reply: exactly one message in the form of
.agents/skills/landin-change/report.md (`python3 scripts/item.py report
{item}` drafts it), sent when everything you started has finished.
"""

AUTHORITY = ("push the candidate, promote it to main once its gate and"
             " boards dispatch pass (`item.py promote`), and remove its"
             " worktree and branches (`item.py finish`), as ROADMAP.md's"
             " Authority paragraph says.")
MAINTAINER = ("push the candidate and follow its gate. The item says"
              " `Promotion: maintainer`: promotion to main is the"
              " maintainer's; report the passed candidate and stop there.")


def beside_text(item, items, cwd):
    lines = []
    for state in running_states(cwd):
        if state["item"] != item:
            lines.append("- %s on branch %s in %s (state %s)"
                         % (state["item"], state["branch"], state["worktree"],
                            state.get("phase")))
    for other, entry in items.items():
        if other != item and entry["status"] == "active" and not any(
                other in line for line in lines):
            lines.append("- %s is active in ROADMAP.md, not run from this"
                         " clone" % other)
    return "\n".join(lines) or "- nothing"


def mark_active(worktree, item, entry):
    """Set ITEM's status active and move a pointer naming it as next."""
    changed = []
    roadmap = worktree / "ROADMAP.md"
    text = roadmap.read_text(encoding="utf-8")
    heading = "### %s — %s\n\nStatus: " % (item, entry["title"])
    if heading + "planned\n" in text:
        roadmap.write_text(text.replace(heading + "planned\n",
                                        heading + "active\n", 1),
                           encoding="utf-8")
        changed.append("ROADMAP.md")
    for name in POINTER_FILES:
        path = worktree / name
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        old = NEXT % (item, entry["title"])
        if old in text:
            path.write_text(text.replace(old, CURRENT % (item, entry["title"])),
                            encoding="utf-8")
            changed.append(name)
    return changed


def start(arguments):
    item = arguments.item
    cwd = REPOSITORY[0]
    if (item_directory(item, cwd) / "state.json").exists():
        raise Refused("%s is already running from this clone: `item.py resume"
                      " %s` says where" % (item, item))
    if not arguments.no_fetch and not arguments.adopt:
        git("fetch", "-q", "origin", cwd=cwd)
    if arguments.adopt:
        worktree = Path(arguments.adopt).resolve()
        branch = git("rev-parse", "--abbrev-ref", "HEAD", cwd=worktree)
        base = arguments.base or git("merge-base", "HEAD", "origin/main",
                                     cwd=worktree)
    else:
        base = git("rev-parse", arguments.base or "origin/main", cwd=cwd)
        branch = arguments.branch or slug(item)
        main_checkout = Path(git("rev-parse", "--show-toplevel", cwd=cwd))
        worktree = Path(arguments.worktree or main_checkout.parent
                        / ("Landin-" + slug(item))).resolve()
    items, _ = roadmap_items(roadmap_at(base, cwd))
    if item not in items:
        raise Refused("ROADMAP.md at %s has no item %s" % (base[:12], item))
    entry = items[item]
    if entry["status"] == "complete":
        raise Refused("%s is complete at %s" % (item, base[:12]))
    if entry["status"] == "blocked":
        raise Refused("%s is blocked at %s; its Blocked because: line says"
                      " what it waits for" % (item, base[:12]))
    missing = unmet(items, item)
    if missing and not arguments.force:
        raise Refused("%s depends on %s, not complete at %s; --force starts"
                      " it regardless" % (item, ", ".join(missing), base[:12]))
    if not arguments.adopt:
        if worktree.exists():
            raise Refused("%s exists; name another with --worktree, or"
                          " --adopt it" % worktree)
        git("worktree", "add", "-q", "-b", branch, str(worktree), base,
            cwd=cwd)
    reservation = reserve(item, base, cwd)
    changed = [] if arguments.no_commit else mark_active(worktree, item, entry)
    if changed:
        git("add", *changed, cwd=worktree)
        git("commit", "-q", "-m", "Start %s\n\n%s, made active by"
            " scripts/item.py start.\n\n%s" % (item, entry["title"],
                                               EXPLANATORY), cwd=worktree)
    state = {"item": item, "title": entry["title"], "branch": branch,
             "worktree": str(worktree), "base": base, "started": stamp(),
             "phase": "started", "maintainer": entry["maintainer"],
             "reserved": reservation, "runs": [], "gates": []}
    save(state, cwd)
    brief = BRIEF.format(
        item=item, title=entry["title"], line=entry["line"],
        worktree=worktree, branch=branch, base=base[:12],
        state=item_directory(item, cwd), D=reservation["D"],
        SR=reservation["SR"], Q=reservation["Q"],
        beside=beside_text(item, items, cwd),
        authority=MAINTAINER if entry["maintainer"] else AUTHORITY)
    (item_directory(item, cwd) / "brief.md").write_text(brief,
                                                         encoding="utf-8")
    journal(item, "started from %s in %s on %s%s" % (
        base[:12], worktree, branch,
        "; committed %s" % ", ".join(changed) if changed else ""), cwd)
    print("started %s in %s on branch %s from %s" % (item, worktree, branch,
                                                     base[:12]))
    print("brief: %s" % (item_directory(item, cwd) / "brief.md"))
    print("reserved: D%d-D%d, SR-%d-%d, Q-%d-%d" % (
        *reservation["D"], *reservation["SR"], *reservation["Q"]))
    return 0


# ----------------------------------------------------------- runs and gates

def run_state(directory):
    """finished (with its status), running, or lost, for a run directory."""
    directory = Path(directory)
    result = directory / "result.json"
    if result.exists():
        data = json.loads(result.read_text(encoding="utf-8"))
        return "finished, exit %s" % data.get("exit_status", "?")
    running = directory / "running.json"
    if running.exists():
        pid = json.loads(running.read_text(encoding="utf-8")).get("pid")
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return "lost: its wrapper ended without a result"
        except (PermissionError, TypeError):
            pass
        return "running"
    return "not started"


def run(arguments):
    item = arguments.item
    state = load(item)
    command = arguments.command
    if not command:
        raise Refused("name the command after --")
    directory = item_directory(item) / "runs" / arguments.name
    if directory.exists():
        raise Refused("%s exists: name the run anew, or `run_logged.py --wait"
                      " %s` for the one it holds" % (directory, directory))
    directory.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(ROOT / "scripts/run_logged.py"),
                    "--output", str(directory), "--detach", "--limit",
                    str(arguments.limit), "--", *command],
                   cwd=state["worktree"], check=True)
    state["runs"].append({"name": arguments.name, "directory": str(directory),
                          "command": shlex.join(command), "started": stamp()})
    save(state)
    journal(item, "run %s started: %s" % (arguments.name, shlex.join(command)))
    print("wait: python3 scripts/run_logged.py --wait %s" % directory)
    return 0


def runs_of(commit):
    return gh("run", "list", "--workflow=gate.yml", "--commit", commit,
              "--limit", "20", "--json",
              "databaseId,event,headBranch,status,conclusion,displayTitle,"
              "createdAt") or []


def kind_of(run_entry):
    if run_entry["event"] == "workflow_dispatch" and "boards" in \
            run_entry.get("displayTitle", ""):
        return "boards"
    if run_entry["event"] == "push" and run_entry["headBranch"] == "main":
        return "main"
    return "software" if run_entry["event"] == "push" else run_entry["event"]


def record_gates(state, commit):
    """Add COMMIT's gate runs to STATE, refreshing those it holds."""
    tree = git("rev-parse", commit + "^{tree}", cwd=place(state))
    known = {entry["run"]: entry for entry in state["gates"]}
    for found in runs_of(commit):
        entry = known.get(found["databaseId"])
        if entry is None:
            entry = {"run": found["databaseId"], "commit": commit,
                     "tree": tree, "kind": kind_of(found)}
            state["gates"].append(entry)
        entry["status"] = found["status"]
        entry["conclusion"] = found.get("conclusion") or ""
    return state


def complete_listing(run_number):
    """None when RUN's every job passed or was skipped, else what did not."""
    sys.path.insert(0, str(ROOT / "scripts"))
    import gate_watch
    jobs, _ = gate_watch.jobs_of(run_number)
    bad = [job["name"] for job in jobs
           if job["conclusion"] not in ("success", "skipped")]
    if not any(job["name"] == "gate" and job["conclusion"] == "success"
               for job in jobs):
        bad.append("gate (the aggregate) not passed")
    return ", ".join(bad) or None


def gate(arguments):
    item = arguments.item
    state = load(item)
    worktree = state["worktree"]
    git("fetch", "-q", "origin", cwd=worktree)
    if arguments.main:
        commit = state.get("promoted")
        if not commit:
            raise Refused("%s has not been promoted" % item)
    else:
        commit = git("rev-parse", "HEAD", cwd=worktree)
        pushed = git("rev-parse", "origin/" + state["branch"], cwd=worktree,
                     check=False)
        if pushed != commit:
            raise Refused("HEAD %s is not the pushed head of %s (%s): push"
                          " it, `git push -u origin %s`" % (
                              commit[:12], state["branch"],
                              (pushed or "absent")[:12], state["branch"]))
        if state["phase"] == "started":
            state["phase"] = "pushed"
    record_gates(state, commit)
    advance(state, commit, arguments.main)
    save(state)
    shown = [entry for entry in state["gates"] if entry["commit"] == commit]
    for entry in shown:
        print("run %s  %-8s %s %s" % (entry["run"], entry["kind"],
                                      entry["status"], entry["conclusion"]))
    if not shown:
        print("no gate run for %s yet" % commit[:12])
    if arguments.watch:
        event, branch = (("push", "main") if arguments.main
                         else ("push", state["branch"]))
        name = "gate-%s-%s" % ("main" if arguments.main else "branch",
                               commit[:12])
        directory = item_directory(item) / "runs" / name
        if directory.exists():
            print("already watched: python3 scripts/run_logged.py --wait %s"
                  % directory)
            return 0
        arguments.name, arguments.limit = name, 7200
        arguments.command = ["python3", str(ROOT / "scripts/gate_watch.py"),
                             "--all", "--commit", commit, "--event", event,
                             "--branch", branch]
        return run(arguments)
    return 0


def advance(state, commit, main=False):
    """Move the phase on as far as COMMIT's passed runs take it."""
    passed = {entry["kind"] for entry in state["gates"]
              if entry["commit"] == commit
              and entry.get("conclusion") == "success"}
    if main:
        if "main" in passed:
            state["phase"] = "main-passed"
        return
    if state["phase"] in ("started", "pushed", "gate-passed") and \
            "software" in passed:
        state["phase"] = "gate-passed"
    if state["phase"] == "gate-passed" and "boards" in passed:
        state["phase"] = "boards-passed"


def boards(arguments):
    item = arguments.item
    state = load(item)
    commit = git("rev-parse", "HEAD", cwd=state["worktree"])
    pushed = git("rev-parse", "origin/" + state["branch"],
                 cwd=state["worktree"], check=False)
    if pushed != commit:
        raise Refused("push the head first: the dispatch runs the branch as"
                      " GitHub holds it")
    before = {found["databaseId"] for found in runs_of(commit)}
    result = subprocess.run(["gh", "workflow", "run", "gate.yml", "--ref",
                             state["branch"], "-f", "scope=boards"],
                            cwd=repository(), text=True,
                            stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise Refused("the dispatch failed: %s" % result.stderr.strip())
    for _ in range(30):
        new = [found for found in runs_of(commit)
               if found["databaseId"] not in before
               and found["event"] == "workflow_dispatch"]
        if new:
            record_gates(state, commit)
            save(state)
            journal(item, "boards dispatched: run %s on %s"
                    % (new[0]["databaseId"], commit[:12]))
            print("boards run %s on %s" % (new[0]["databaseId"], commit[:12]))
            if arguments.watch:
                arguments.name = "boards-%s" % new[0]["databaseId"]
                arguments.limit = 7200
                arguments.command = ["python3",
                                     str(ROOT / "scripts/gate_watch.py"),
                                     "--all", "--run",
                                     str(new[0]["databaseId"])]
                return run(arguments)
            return 0
        time.sleep(4)
    raise Refused("the dispatch was accepted but GitHub lists no run yet;"
                  " `item.py gate %s` records it once it does" % item)


# ---------------------------------------------------------------- promotion

def explanatory_since(worktree, older, newer):
    """Whether every commit after OLDER up to NEWER says Gate: explanatory."""
    messages = git("log", "--format=%B%x00", "%s..%s" % (older, newer),
                   cwd=worktree)
    bodies = [body for body in messages.split("\0") if body.strip()]
    return all(EXPLANATORY in body for body in bodies)


def evidence(state, commit):
    """Problems standing between COMMIT and main; empty when none."""
    worktree = state["worktree"]
    problems = []
    tree = git("rev-parse", commit + "^{tree}", cwd=worktree)
    software = [entry for entry in state["gates"]
                if entry["commit"] == commit and entry["kind"] == "software"
                and entry["conclusion"] == "success"]
    if not software:
        problems.append("no passed push gate on %s: push it and follow it"
                        " (`item.py gate %s --watch`)" % (commit[:12],
                                                          state["item"]))
    else:
        missing = complete_listing(software[-1]["run"])
        if missing:
            problems.append("run %s's listing does not pass: %s"
                            % (software[-1]["run"], missing))
    passed_boards = [entry for entry in state["gates"]
                     if entry["kind"] == "boards"
                     and entry["conclusion"] == "success"]
    going = [entry for entry in state["gates"] if entry["kind"] == "boards"
             and entry["tree"] == tree and entry.get("status") != "completed"]
    if not any(entry["tree"] == tree or (
            git("merge-base", "--is-ancestor", entry["commit"], commit,
                cwd=worktree, check=False) is not None
            and explanatory_since(worktree, entry["commit"], commit))
               for entry in passed_boards):
        if going:
            problems.append("boards run %s on this tree has not finished:"
                            " `item.py gate %s` refreshes it"
                            % (going[-1]["run"], state["item"]))
        elif not (passed_boards == [] and explanatory_since(
                worktree, state["base"], commit)):
            problems.append("no passed boards dispatch on this tree, nor on"
                            " a commit after which every commit says `%s`:"
                            " `item.py boards %s`" % (EXPLANATORY,
                                                      state["item"]))
    return problems


def promote(arguments):
    item = arguments.item
    state = load(item)
    if state.get("maintainer"):
        raise Refused("%s says `Promotion: maintainer`; report the passed"
                      " candidate instead" % item)
    worktree = state["worktree"]
    git("fetch", "-q", "origin", cwd=worktree)
    commit = git("rev-parse", "HEAD", cwd=worktree)
    if git("status", "--porcelain", cwd=worktree):
        raise Refused("the worktree has uncommitted changes")
    if git("rev-parse", "origin/" + state["branch"], cwd=worktree,
           check=False) != commit:
        raise Refused("HEAD is not the branch's pushed head")
    if git("merge-base", "--is-ancestor", "origin/main", commit, cwd=worktree,
           check=False) is None:
        raise Refused("main has moved past the candidate's base: merge"
                      " origin/main, push, and gate the merged tree")
    record_gates(state, commit)
    for older in {entry["commit"] for entry in state["gates"]} - {commit}:
        record_gates(state, older)
    save(state)
    problems = evidence(state, commit)
    items, _ = roadmap_items(git("show", commit + ":ROADMAP.md", cwd=worktree))
    if not arguments.partial and items.get(item, {}).get("status") != \
            "complete":
        problems.append("%s is not complete in the candidate's ROADMAP.md;"
                        " --partial promotes work short of its close" % item)
    others = [found for found in gh("run", "list", "--workflow=gate.yml",
                                    "--status", "in_progress", "--json",
                                    "databaseId,headBranch") or []]
    if problems:
        raise Refused("not promoted:\n  " + "\n  ".join(problems))
    if others:
        print("note: gates running now share the runners: %s" % ", ".join(
            "%s (%s)" % (o["databaseId"], o["headBranch"]) for o in others))
    if arguments.dry_run:
        print("would push %s to main" % commit[:12])
        return 0
    git("push", "origin", "%s:refs/heads/main" % commit, cwd=worktree)
    state["promoted"] = commit
    state["phase"] = "promoted"
    save(state)
    journal(item, "promoted %s to main" % commit[:12])
    print("promoted %s; follow main's gate: python3 scripts/item.py gate %s"
          " --main --watch" % (commit[:12], item))
    return 0


def finish(arguments):
    item = arguments.item
    state = load(item)
    worktree = Path(state["worktree"])
    if not state.get("promoted") and not arguments.unpromoted:
        raise Refused("%s was not promoted; --unpromoted removes its worktree"
                      " and branches regardless" % item)
    #  Run from the item's own worktree, the script would go on asking Git
    #  in the directory it has just removed: everything after the removal
    #  runs in the clone's main checkout.
    home = main_checkout()
    if Path(home).resolve() == worktree.resolve():
        raise Refused("%s is the clone's main checkout, not an item's"
                      " worktree" % worktree)
    REPOSITORY[0] = home
    os.chdir(home)
    if state.get("promoted"):
        git("fetch", "-q", "origin")
        record_gates(state, state["promoted"])
        main = [entry for entry in state["gates"]
                if entry["commit"] == state["promoted"]
                and entry["kind"] == "main"]
        if not any(entry["conclusion"] == "success" for entry in main):
            raise Refused("main's gate on %s has not passed: %s" % (
                state["promoted"][:12], ", ".join(
                    "run %s %s" % (e["run"], e["conclusion"] or e["status"])
                    for e in main) or "no run yet"))
    if worktree.exists():
        if git("status", "--porcelain", cwd=worktree):
            raise Refused("%s has uncommitted changes" % worktree)
        git("worktree", "remove", str(worktree))
    git("branch", "-D", state["branch"], check=False)
    remote = git("ls-remote", "--heads", "origin", state["branch"],
                 check=False)
    if remote:
        git("push", "-q", "origin", "--delete", state["branch"], check=False)
    state["phase"] = "finished"
    save(state)
    journal(item, "finished: worktree and branch %s removed" % state["branch"])
    done = state_root() / DONE_DIRECTORY
    done.mkdir(parents=True, exist_ok=True)
    os.replace(item_directory(item), done / item)
    print("finished %s; its state is kept in %s" % (item, done / item))
    return 0


# --------------------------------------------------------- status and resume

def last_activity(state):
    """The newest of the item's commits, journal, runs and edits."""
    times = []
    directory = item_directory(state["item"])
    for path in [directory / "journal.md", directory / "state.json"]:
        if path.exists():
            times.append(path.stat().st_mtime)
    for entry in state["runs"]:
        log = Path(entry["directory"]) / "command.log"
        if log.exists():
            times.append(log.stat().st_mtime)
    worktree = Path(state["worktree"])
    if worktree.exists():
        committed = git("log", "-1", "--format=%ct", cwd=worktree, check=False)
        if committed:
            times.append(float(committed))
        for line in (git("status", "--porcelain", cwd=worktree,
                         check=False) or "").splitlines():
            path = worktree / line[3:].split(" -> ")[-1]
            if path.exists():
                times.append(path.stat().st_mtime)
    return max(times) if times else 0


def describe(state, full=False):
    worktree = Path(state["worktree"])
    out = ["%s — %s: %s, branch %s" % (state["item"], state["title"],
                                       state["phase"], state["branch"])]
    if not worktree.exists():
        out.append("  worktree %s is missing" % worktree)
    else:
        head = git("rev-parse", "--short=12", "HEAD", cwd=worktree)
        ahead = git("rev-list", "--count", "%s..HEAD" % state["base"],
                    cwd=worktree)
        dirty = git("status", "--porcelain", cwd=worktree)
        out.append("  worktree %s at %s, %s commits on base %s%s" % (
            worktree, head, ahead, state["base"][:12],
            ", uncommitted changes" if dirty else ""))
        if full and dirty:
            out.extend("    " + line for line in dirty.splitlines())
    minutes = (time.time() - last_activity(state)) / 60
    out.append("  last activity %d min ago" % minutes)
    for entry in state["runs"]:
        out.append("  run %s: %s (%s)" % (entry["name"],
                                          run_state(entry["directory"]),
                                          entry["directory"]))
    for entry in state["gates"]:
        out.append("  gate run %s %s on %s: %s %s" % (
            entry["run"], entry["kind"], entry["commit"][:12],
            entry.get("status", ""), entry.get("conclusion", "")))
    return out


def next_step(state):
    """What the item does next, after any run still going and any edit
    not yet committed."""
    item = state["item"]
    first = []
    running = [entry for entry in state["runs"]
               if run_state(entry["directory"]) == "running"]
    if running:
        first.append("wait for run %s: python3 scripts/run_logged.py --wait"
                     " %s, with --timeout under the calling tool's limit;"
                     " exit 124 means wait again"
                     % (running[0]["name"], running[0]["directory"]))
    worktree = Path(state["worktree"])
    if worktree.exists() and git("status", "--porcelain", cwd=worktree,
                                 check=False):
        first.append("the uncommitted changes listed above are the item's"
                     " work in progress: read them against the journal,"
                     " then finish and commit them; a push supersedes a"
                     " gate run still going")
    return "; then ".join(first + [phase_step(state)])


def phase_step(state):
    item = state["item"]
    lost = [entry for entry in state["runs"]
            if run_state(entry["directory"]).startswith("lost")]
    if lost:
        return ("run %s was lost (%s); read its log and start it anew under"
                " another name" % (lost[0]["name"], lost[0]["directory"]))
    phase = state["phase"]
    if phase == "started":
        return ("continue the work in the worktree; push once its checks pass"
                ", then `item.py gate %s --watch`" % item)
    if phase in ("pushed", "gate-passed", "boards-passed"):
        return ("`item.py gate %s` for the head's runs; when the push gate"
                " passed, `item.py boards %s`, then the closing checklist and"
                " `item.py promote %s`" % (item, item, item))
    if phase == "promoted":
        return "`item.py gate %s --main --watch`, then `item.py finish %s`" \
            % (item, item)
    if phase == "main-passed":
        return "`item.py finish %s`, then `item.py report %s`" % (item, item)
    return "`item.py report %s`" % item


def status(arguments):
    states = ([load(arguments.item)] if arguments.item
              else running_states())
    if not states:
        print("this clone runs no item")
    for state in states:
        print("\n".join(describe(state)))
    return 0


def resolve_item(arguments):
    item = arguments.item or item_of_branch(Path.cwd())
    if not item:
        raise Refused("name the item: the current branch is no running"
                      " item's")
    return item


def resume(arguments):
    item = resolve_item(arguments)
    state = load(item)
    if state["gates"] and shutil.which("gh"):
        try:
            for commit in sorted({entry["commit"] for entry in state["gates"]}):
                record_gates(state, commit)
            save(state)
        except Refused as error:
            print("gate runs not refreshed: %s" % error)
    print("\n".join(describe(state, full=True)))
    directory = item_directory(item)
    print("  brief %s" % (directory / "brief.md"))
    entries = (directory / "journal.md").read_text(encoding="utf-8") \
        .splitlines() if (directory / "journal.md").exists() else []
    if entries:
        print("journal, last %d of %d:" % (min(15, len(entries)),
                                          len(entries)))
        print("\n".join(entries[-15:]))
    print("next: " + next_step(state))
    return 0


def note(arguments):
    load(arguments.item)
    journal(arguments.item, " ".join(arguments.text))
    return 0


def stalled(arguments):
    found = 0
    for state in running_states():
        if state["phase"] == "finished":
            continue
        idle = (time.time() - last_activity(state)) / 60
        going = [entry["name"] for entry in state["runs"]
                 if run_state(entry["directory"]) == "running"]
        if idle >= arguments.minutes and not going:
            found += 1
            print("STALLED %s: nothing moved for %d min and no run is going;"
                  " %s" % (state["item"], idle, next_step(state)))
        else:
            print("moving %s: last activity %d min ago%s" % (
                state["item"], idle,
                ", running %s" % ", ".join(going) if going else ""))
    return 1 if found else 0


# ------------------------------------------------------------------- report

QUESTION_PART = re.compile(r"^\*\*(Options|Recommendation|Default until"
                           r" answered|What waits on the answer):\*\*\s*(.*)$")


def open_questions(item, worktree):
    """The questions ITEM asked that have no answer, with their parts."""
    found = []
    directory = Path(worktree) / "roadmap" / "questions"
    if not directory.is_dir():
        return found
    for path in sorted(directory.glob("Q-*.md")):
        text = path.read_text(encoding="utf-8")
        if not re.search(r"^Asked by %s on " % re.escape(item), text, re.M) \
                or "**Answer (" in text:
            continue
        heading = text.splitlines()[0].lstrip("# ").strip()
        parts, current = {}, None
        for line in text.splitlines():
            match = QUESTION_PART.match(line)
            if match:
                current = match.group(1)
                parts[current] = match.group(2)
            elif current and line.strip():
                parts[current] += " " + line.strip()
            elif current and not line.strip() and parts[current]:
                current = None
        found.append((heading, parts))
    return found


def report(arguments):
    item = resolve_item(arguments)
    state = load(item)
    worktree = state["worktree"]
    head = git("rev-parse", "--short=12", "HEAD", cwd=worktree, check=False)
    lines = ["RESULT: TODO done | partly done | stopped | failed",
             "  TODO one sentence: what now exists, and where (%s%s)." % (
                 "promoted %s, on main" % state["promoted"][:12]
                 if state.get("promoted") else "branch %s at %s"
                 % (state["branch"], head), ""),
             "", "EVIDENCE:"]
    for entry in state["gates"]:
        lines.append("  run %s, %s gate on %s: %s" % (
            entry["run"], entry["kind"], entry["commit"][:12],
            entry.get("conclusion") or entry.get("status", "")))
    for entry in state["runs"]:
        lines.append("  %s: %s, %s (log %s)" % (
            entry["name"], entry["command"], run_state(entry["directory"]),
            Path(entry["directory"]) / "command.log"))
    lines += ["  TODO what each shows; FILTERED or HOST-ONLY where it is.",
              "", "NOT DONE:", "  TODO, or nothing.", "", "STATE:",
              "  state %s; worktree %s (%s); branch %s." % (
                  item_directory(item), worktree,
                  "present" if Path(worktree).exists() else "removed",
                  state["branch"]),
              "  TODO whether the agent can be archived.", "", "FRICTION:",
              "  TODO one line each, rows filed by identity, or None.", "",
              "NEEDS JAN:"]
    questions = open_questions(item, worktree) if Path(worktree).exists() \
        else []
    for heading, parts in questions:
        lines.append("  %s Options: %s Recommendation: %s Default taken: %s"
                     " Waits: %s" % (heading, parts.get("Options", "?"),
                                     parts.get("Recommendation", "?"),
                                     parts.get("Default until answered", "?"),
                                     parts.get("What waits on the answer",
                                               "?")))
    if not questions:
        lines.append("  nothing")
    print("\n".join(lines))
    return 0


# --------------------------------------------------------------------- main

def main(argv=None):
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="\n\n".join(__doc__.split("\n\n")[1:]))
    parser.add_argument("--repo", default=str(ROOT), help=argparse.SUPPRESS)
    commands = parser.add_subparsers(dest="command_name", required=True)

    sub = commands.add_parser("start", help="make the worktree, branch,"
                              " brief and reservations; mark the item active")
    sub.add_argument("item")
    sub.add_argument("--base", help="the starting commit (origin/main)")
    sub.add_argument("--branch", help="the branch (the item, as r19-10)")
    sub.add_argument("--worktree", help="the worktree (Landin-ITEM beside"
                     " the clone's main checkout)")
    sub.add_argument("--adopt", metavar="WORKTREE", help="take on an existing"
                     " worktree and its branch instead of making them")
    sub.add_argument("--force", action="store_true",
                     help="start although a dependency is not complete")
    sub.add_argument("--no-commit", action="store_true",
                     help="leave the status and pointers as they are")
    sub.add_argument("--no-fetch", action="store_true", help=argparse.SUPPRESS)
    sub.set_defaults(handler=start)

    for name, handler, text in (
            ("resume", resume, "what a reopened session needs: state, live"
             " runs, journal and the next step"),
            ("report", report, "draft the report in the skill's form")):
        sub = commands.add_parser(name, help=text)
        sub.add_argument("item", nargs="?")
        sub.set_defaults(handler=handler)

    sub = commands.add_parser("status", help="every item this clone runs")
    sub.add_argument("item", nargs="?")
    sub.set_defaults(handler=status)

    sub = commands.add_parser("note", help="add a line to the journal")
    sub.add_argument("item")
    sub.add_argument("text", nargs="+")
    sub.set_defaults(handler=note)

    sub = commands.add_parser("run", help="a detached run_logged run kept in"
                              " the item's state")
    sub.add_argument("item")
    sub.add_argument("name")
    sub.add_argument("--limit", type=int, required=True,
                     help="seconds after which the run is ended")
    sub.set_defaults(handler=run)

    sub = commands.add_parser("gate", help="record and show the gate runs of"
                              " the pushed head, or of main after promotion")
    sub.add_argument("item")
    sub.add_argument("--main", action="store_true",
                     help="main's push gate on the promoted commit")
    sub.add_argument("--watch", action="store_true", help="follow it to its"
                     " end in a detached gate_watch.py --all run")
    sub.set_defaults(handler=gate)

    sub = commands.add_parser("boards", help="dispatch scope=boards on the"
                              " pushed head")
    sub.add_argument("item")
    sub.add_argument("--watch", action="store_true", help="follow it to its"
                     " end in a detached gate_watch.py --all run")
    sub.set_defaults(handler=boards)

    sub = commands.add_parser("promote", help="check the evidence and push"
                              " the head to main")
    sub.add_argument("item")
    sub.add_argument("--partial", action="store_true", help="promote work"
                     " short of the item's close")
    sub.add_argument("--dry-run", action="store_true")
    sub.set_defaults(handler=promote)

    sub = commands.add_parser("finish", help="after main's gate: remove the"
                              " worktree and branches, keep the state")
    sub.add_argument("item")
    sub.add_argument("--unpromoted", action="store_true",
                     help="clean up an item that was never promoted")
    sub.set_defaults(handler=finish)

    sub = commands.add_parser("stalled", help="the running items nothing has"
                              " moved; exit 1 when there is one")
    sub.add_argument("--minutes", type=int, default=STALL_MINUTES)
    sub.set_defaults(handler=stalled)

    #  A run's command follows the first `--` and is never parsed here:
    #  argparse's handling of `--` before a subcommand's positionals
    #  differs between Python versions, and 3.12 refused this form.
    argv = list(sys.argv[1:] if argv is None else argv)
    command = []
    if "--" in argv:
        command = argv[argv.index("--") + 1:]
        argv = argv[:argv.index("--")]
    arguments = parser.parse_args(argv)
    arguments.command = command
    REPOSITORY[0] = Path(arguments.repo)
    try:
        return arguments.handler(arguments)
    except Refused as error:
        print("item.py: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
