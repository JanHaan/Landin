#!/usr/bin/env python3
"""Run a roadmap item from start to finish: every step that needs no agent.

    python3 scripts/item.py start ITEM          # worktree, branch, brief, identities
    python3 scripts/item.py resume [ITEM]       # where a reopened session stands
    python3 scripts/item.py note ITEM TEXT      # one line in the item's journal
    python3 scripts/item.py run ITEM NAME --limit S [--cwd DIR] -- COMMAND ...
    python3 scripts/item.py push ITEM [--watch] # check the citations, push, gate
    python3 scripts/item.py gate ITEM [--watch] # the gate runs of the branch head
    python3 scripts/item.py boards ITEM [--watch] [--rerun-failed]
                                                # dispatch scope=boards
    python3 scripts/item.py merge-main ITEM     # take the queue, merge main once
    python3 scripts/item.py queue [--wait ITEM | --release ITEM]
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

Promotions queue, so that an item merges main once rather than once for
every item that lands before it.  The clone holds one promotion token,
`landin-items/queue.json`.  `merge-main` takes it before the item's final
merge and `promote` takes it before pushing; the holder keeps it until
main's gate on its promoted commit has ended, which `gate --main` and
`finish` see, or until `queue --release` gives it up.  An item that finds
it held is put in line and told the wait command; `queue --wait ITEM`
returns once the token is the item's, taking it.  A holder whose state is
gone, or whose main gate has ended, holds nothing.

`merge-main` merges `origin/main`.  When every commit it brings says
`Gate: explanatory` and the merged tree has the candidate's gate key
(`scripts/gate_inputs.py key`), the merge says `Gate: explanatory` too, and
the gate reuses the candidate's pass and the boards dispatch still counts,
as the reuse rule already allows; otherwise it says which commits or paths
make the merged tree new.  `boards` refuses to dispatch on a head main is
not an ancestor of, since promotion would refuse that tree; `--unmerged`
dispatches anyway, for board feedback before the final merge.  After a
boards run whose board legs passed and whose only failures were timing
jobs, `boards --rerun-failed` re-runs only the failed jobs of that run.
`push` refuses a stale `citations.txt` before pushing.

Releases and versions are never this script's.
"""
import argparse
import contextlib
import datetime
import fcntl
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
QUEUE = "queue.json"
#  Seconds between looks while `queue --wait` waits, and between asking
#  GitHub whether the holder's main gate has ended.
QUEUE_POLL = 15
QUEUE_ASK = 60
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

How to work: exact `dev-test.sh` selectors for what the item changes, all
in one invocation, leaving the complete suite to the gate; the build's
worker count and CPU placement at their defaults, no `-j` or `taskset`;
the pinned environment by `. "$(./scripts/agent_env.sh)"` or `nix develop`;
a long run through `item.py run`, waited on by the harness's completion
notification, `run_logged.py --wait DIR` where there is none
(docs/process.md, "Local agent feedback"). A brief you write for a
subagent or a stream carries these rules itself.

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
        #  Beside the clone's main checkout, whichever of its worktrees
        #  runs this, so a checkout under /tmp does not put it there.
        worktree = Path(arguments.worktree or main_checkout(cwd).parent
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
    where = Path(getattr(arguments, "cwd", None) or state["worktree"])
    if not where.is_dir():
        raise Refused("--cwd %s is not a directory" % where)
    where = where.resolve()
    directory = item_directory(item) / "runs" / arguments.name
    if directory.exists():
        raise Refused("%s exists: name the run anew, or `run_logged.py --wait"
                      " %s` for the one it holds" % (directory, directory))
    directory.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([sys.executable, str(ROOT / "scripts/run_logged.py"),
                    "--output", str(directory), "--detach", "--limit",
                    str(arguments.limit), "--", *command],
                   cwd=where, check=True)
    state["runs"].append({"name": arguments.name, "directory": str(directory),
                          "command": shlex.join(command), "cwd": str(where),
                          "started": stamp()})
    save(state)
    journal(item, "run %s started in %s: %s" % (arguments.name, where,
                                                 shlex.join(command)))
    print("wait: python3 scripts/run_logged.py --wait %s" % directory)
    return 0


def runs_of(commit):
    return gh("run", "list", "--workflow=gate.yml", "--commit", commit,
              "--limit", "20", "--json",
              "databaseId,event,headBranch,status,conclusion,displayTitle,"
              "createdAt,attempt") or []


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
        attempt = found.get("attempt") or 1
        if (entry.get("attempt"), entry.get("conclusion")) != (
                attempt, found.get("conclusion") or ""):
            entry.pop("failed", None)
        entry["status"] = found["status"]
        entry["conclusion"] = found.get("conclusion") or ""
        entry["attempt"] = attempt
        if entry["kind"] == "boards" and entry["conclusion"] == "failure" \
                and entry.get("failed", "unknown") == "unknown":
            entry["failed"] = failure_of(entry["run"])
    return state


def failure_of(run_number):
    """What failed in a boards run: `timing` when only timing jobs (and
    the aggregate after them) failed and every board leg passed,
    `aggregate` when only the aggregate did, `jobs` otherwise, or
    `unknown` when GitHub could not list its jobs."""
    try:
        gate_watch = gate_module("gate_watch")
        jobs, _ = gate_watch.jobs_of(run_number)
        return gate_watch.failure_kind(jobs) or "unknown"
    except Exception:  # noqa: BLE001 -- a listing GitHub did not give
        return "unknown"


FAILURE_TEXT = {
    "timing": "timing only, every board leg passed: read the timing log,"
              " and if it reads as noise `item.py boards %s --rerun-failed`",
    "aggregate": "the aggregate alone, every job before it passed: its"
                 " verdict or the cycles comparison; read its log",
    "jobs": "board or other jobs failed: read their logs",
    "unknown": "its jobs could not be listed: `item.py gate %s` again",
}


def gate_text(entry, item):
    """A gate entry's status and conclusion, with what a failure was."""
    text = "%s %s" % (entry.get("status", ""), entry.get("conclusion", ""))
    if entry.get("failed"):
        explained = FAILURE_TEXT.get(entry["failed"], entry["failed"])
        text += " (%s)" % (explained % item if "%s" in explained
                           else explained)
    return text


def complete_listing(run_number):
    """None when RUN's every job passed or was skipped, else what did not."""
    jobs, _ = gate_module("gate_watch").jobs_of(run_number)
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
    if arguments.main and any(entry["kind"] == "main"
                              and entry["status"] == "completed"
                              for entry in shown):
        if release(item, "main's gate on %s has ended" % commit[:12]):
            print("main's gate has ended: the promotion token is released")
    for entry in shown:
        print("run %s  %-8s %s" % (entry["run"], entry["kind"],
                                   gate_text(entry, item)))
    if not shown:
        print("no gate run for %s yet" % commit[:12])
    if arguments.watch:
        return watch_gate(arguments, state, commit, shown)
    return 0


def watch_gate(arguments, state, commit, shown):
    """Follow COMMIT's newest gate run of the kind asked for.

    The watch is named by that run and its attempt, so a rerun on the same
    commit, a newer attempt or a new run, is watched afresh rather than
    answered with the finished watch of the old one.  Until GitHub lists a
    run the watch is named by the commit and waits for one.
    """
    item = arguments.item
    event, branch = (("push", "main") if arguments.main
                     else ("push", state["branch"]))
    prefix = "gate-%s-%s" % ("main" if arguments.main else "branch",
                             commit[:12])
    runs = item_directory(item) / "runs"
    for going in sorted(runs.glob(prefix + "*")):
        if run_state(going) == "running":
            print("already watched: python3 scripts/run_logged.py --wait %s"
                  % going)
            return 0
    kind = "main" if arguments.main else "software"
    newest = max((entry for entry in shown if entry["kind"] == kind),
                 key=lambda entry: entry["run"], default=None)
    if newest is None:
        name = prefix
        command = ["--commit", commit, "--event", event, "--branch", branch]
    else:
        name = "%s-run%s-attempt%s" % (prefix, newest["run"],
                                       newest.get("attempt", 1))
        command = ["--run", str(newest["run"])]
    directory = runs / name
    if directory.exists():
        print("already watched: python3 scripts/run_logged.py --wait %s"
              % directory)
        return 0
    arguments.name, arguments.limit = name, 7200
    arguments.command = ["python3", str(ROOT / "scripts/gate_watch.py"),
                         "--all", *command]
    return run(arguments)


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
    if arguments.rerun_failed:
        return rerun_boards(arguments, state, commit)
    git("fetch", "-q", "origin", "main", cwd=state["worktree"])
    if not arguments.unmerged and git(
            "merge-base", "--is-ancestor", "origin/main", commit,
            cwd=state["worktree"], check=False) is None:
        raise Refused("main has moved past %s, so promotion would refuse"
                      " this tree and its boards would be dispatched again:"
                      " merge main first (`item.py merge-main %s`), or"
                      " --unmerged for board feedback before the final merge"
                      % (commit[:12], item))
    if arguments.unmerged:
        journal(item, "boards dispatched with --unmerged")
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
                return watch_boards(arguments, new[0]["databaseId"], 1)
            return 0
        time.sleep(4)
    raise Refused("the dispatch was accepted but GitHub lists no run yet;"
                  " `item.py gate %s` records it once it does" % item)


def watch_boards(arguments, run_number, attempt):
    arguments.name = "boards-%s" % run_number + (
        "-attempt%d" % attempt if attempt > 1 else "")
    arguments.limit = 7200
    arguments.command = ["python3", str(ROOT / "scripts/gate_watch.py"),
                         "--all", "--run", str(run_number)]
    return run(arguments)


def rerun_failed_jobs(run_number):
    """Ask GitHub to re-run RUN's failed jobs and the jobs that need them,
    the aggregate among them, as the run's next attempt."""
    result = subprocess.run(["gh", "run", "rerun", str(run_number),
                             "--failed"], cwd=repository(), text=True,
                            stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise Refused("the re-run failed: %s" % result.stderr.strip())


def rerun_boards(arguments, state, commit):
    """Re-run only the failed jobs of the head's newest boards run, when
    every board leg passed and only timing jobs failed."""
    item = arguments.item
    record_gates(state, commit)
    save(state)
    boards_runs = [entry for entry in state["gates"]
                   if entry["commit"] == commit and entry["kind"] == "boards"]
    if not boards_runs:
        raise Refused("no boards run on %s to re-run: `item.py boards %s`"
                      % (commit[:12], item))
    newest = max(boards_runs, key=lambda entry: entry["run"])
    if newest.get("status") != "completed":
        raise Refused("boards run %s has not ended" % newest["run"])
    if newest.get("conclusion") != "failure":
        raise Refused("boards run %s ended %s, not failed: nothing to re-run"
                      % (newest["run"], newest.get("conclusion")))
    kind = failure_of(newest["run"])
    newest["failed"] = kind
    save(state)
    if kind != "timing":
        raise Refused("boards run %s did not fail in timing alone (%s):"
                      " re-running its failed jobs would not give the"
                      " missing evidence" % (newest["run"], gate_text(
                          newest, item)))
    rerun_failed_jobs(newest["run"])
    attempt = newest.get("attempt", 1) + 1
    journal(item, "boards run %s: failed timing jobs re-run as attempt %d"
            % (newest["run"], attempt))
    print("boards run %s: its failed jobs re-run as attempt %d"
          % (newest["run"], attempt))
    if arguments.watch:
        return watch_boards(arguments, newest["run"], attempt)
    return 0


# ------------------------------------------------------- the promotion queue

def gate_module(name):
    """One of this script's sibling modules, gate_inputs or gate_watch."""
    if str(ROOT / "scripts") not in sys.path:
        sys.path.insert(0, str(ROOT / "scripts"))
    return __import__(name)


@contextlib.contextmanager
def queue_locked(cwd=None):
    """The clone's promotion queue, read and written under one lock:
    {"holder": {"item", "why", "taken"} or None, "waiting": [ITEM, ...]}."""
    root = state_root(cwd)
    root.mkdir(parents=True, exist_ok=True)
    with open(root / (QUEUE + ".lock"), "a", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = root / QUEUE
        data = (json.loads(path.read_text(encoding="utf-8"))
                if path.exists() else {})
        data.setdefault("holder", None)
        data.setdefault("waiting", [])
        before = json.dumps(data, sort_keys=True)
        yield data
        if json.dumps(data, sort_keys=True) != before:
            temporary = root / (QUEUE + ".tmp")
            temporary.write_text(json.dumps(data, indent=2) + "\n",
                                 encoding="utf-8")
            os.replace(temporary, path)


def alive(item, cwd=None):
    """Whether this clone still runs ITEM: its state exists, unfinished."""
    path = item_directory(item, cwd) / "state.json"
    if not path.exists():
        return False
    return json.loads(path.read_text(encoding="utf-8"))["phase"] != "finished"


def main_gate_ended(item, commit):
    """Whether main's gate on COMMIT, which ITEM promoted while holding the
    token, has ended, as GitHub lists it now; False when GitHub cannot
    say.  An earlier promotion of the same item, a --partial one, is not
    asked about: its gate ended before this hold began."""
    try:
        state = load(item)
        record_gates(state, commit)
        save(state)
    except (Refused, OSError, ValueError):
        return False
    return any(entry["kind"] == "main" and entry.get("status") == "completed"
               for entry in state["gates"] if entry["commit"] == commit)


def settle(data, ask):
    """Drop a holder or waiter this clone no longer runs, and, when ASK,
    a holder whose main gate has ended."""
    holder = data["holder"]
    if holder and not alive(holder["item"]):
        data["holder"] = None
    elif holder and ask and holder.get("promoted") and \
            main_gate_ended(holder["item"], holder["promoted"]):
        journal(holder["item"], "promotion token released: main's gate on"
                " the promoted commit has ended")
        data["holder"] = None
    data["waiting"] = [waiting for waiting in data["waiting"]
                       if alive(waiting)]


def wait_command(item):
    return ("python3 scripts/item.py run %s queue-wait --limit 7200 --"
            " python3 scripts/item.py queue --wait %s --timeout 7000, then"
            " wait on the run it names; or python3 scripts/item.py queue"
            " --wait %s, again on exit 124" % (item, item, item))


def take(item, why, ask=True):
    """(True, None) when ITEM holds the promotion token, taking it if it is
    free and nobody waits before ITEM; else (False, why not), with ITEM
    put in line."""
    with queue_locked() as data:
        settle(data, ask)
        holder = data["holder"]
        if holder and holder["item"] == item:
            return True, None
        if holder:
            if item not in data["waiting"]:
                data["waiting"].append(item)
            return False, (
                "%s holds the promotion token since %s (%s), until main's"
                " gate on its promotion ends; %s is number %d in line. A"
                " merge or promotion now would be gated again once it lands."
                " Wait: %s" % (holder["item"], holder["taken"], holder["why"],
                               item, data["waiting"].index(item) + 1,
                               wait_command(item)))
        ahead = (data["waiting"][:data["waiting"].index(item)]
                 if item in data["waiting"] else list(data["waiting"]))
        if ahead:
            if item not in data["waiting"]:
                data["waiting"].append(item)
            return False, ("%s waits for the promotion token before %s."
                           " Wait: %s" % (", ".join(ahead), item,
                                          wait_command(item)))
        data["waiting"] = [other for other in data["waiting"]
                           if other != item]
        data["holder"] = {"item": item, "why": why, "taken": stamp()}
    journal(item, "promotion token taken (%s)" % why)
    return True, None


def mark_promoted(item, commit):
    """Record on ITEM's hold the commit it promoted, whose main gate
    ending ends the hold."""
    with queue_locked() as data:
        if data["holder"] and data["holder"]["item"] == item:
            data["holder"]["promoted"] = commit


def release(item, why):
    """Give up ITEM's token or place in line; whether it held the token."""
    with queue_locked() as data:
        held = bool(data["holder"]) and data["holder"]["item"] == item
        if held:
            data["holder"] = None
        data["waiting"] = [other for other in data["waiting"]
                           if other != item]
    if held:
        journal(item, "promotion token released: %s" % why)
    return held


def queue(arguments):
    if arguments.release:
        held = release(arguments.release, "given up with `queue --release`")
        print("%s %s" % (arguments.release, "released the promotion token"
                         if held else "holds no token; left the line"))
        return 0
    if arguments.wait:
        load(arguments.wait)
        deadline = time.monotonic() + arguments.timeout
        asked = 0.0
        while True:
            ask = time.monotonic() - asked >= QUEUE_ASK
            if ask:
                asked = time.monotonic()
            taken, why = take(arguments.wait, "waited in line", ask=ask)
            if taken:
                print("%s holds the promotion token: merge main"
                      " (`item.py merge-main %s`) or promote"
                      % (arguments.wait, arguments.wait))
                return 0
            if time.monotonic() >= deadline:
                print(why.split(" Wait: ")[0])
                return 124
            time.sleep(min(QUEUE_POLL, max(0.0, deadline - time.monotonic())))
    with queue_locked() as data:
        settle(data, ask=True)
        holder, waiting = data["holder"], list(data["waiting"])
    print("promotion token: %s" % (
        "%s since %s (%s)" % (holder["item"], holder["taken"], holder["why"])
        if holder else "free"))
    print("waiting: %s" % (", ".join(waiting) or "nobody"))
    return 0


def queue_line():
    """The token's holder and line, for `status`, without asking GitHub."""
    path = state_root() / QUEUE
    if not path.exists():
        return None
    data = json.loads(path.read_text(encoding="utf-8"))
    holder = data.get("holder")
    if not holder and not data.get("waiting"):
        return None
    return "promotion token: %s; waiting: %s" % (
        "%s since %s" % (holder["item"], holder["taken"]) if holder
        else "free", ", ".join(data.get("waiting") or []) or "nobody")


# ------------------------------------------------------- merging and pushing

def citations_problem(worktree):
    """Why the worktree's citations.txt is stale, or None.  It names the
    compiler sources' digest, so a merge that brings a compiler change
    leaves it stale, and the documents job fails minutes into the gate."""
    worktree = Path(worktree)
    if not (worktree / "check.py").exists() or \
            not (worktree / "citations.txt").exists():
        return None
    probe = ("import sys\nsys.path.insert(0, '.')\nimport check\n"
             "fresh = check.citations_dump()\n"
             "held = open('citations.txt', encoding='utf-8').read()\n"
             "if fresh is not None and fresh != held:\n"
             "    print(check.regenerating('citations.txt'))\n"
             "    sys.exit(1)\n")
    result = subprocess.run([sys.executable, "-B", "-c", probe],
                            cwd=worktree, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    if result.returncode == 0:
        return None
    if result.returncode == 1 and result.stdout.strip():
        return ("citations.txt is stale over this tree: regenerate it with"
                " %s, commit it, then push" % result.stdout.strip())
    return "the citations check could not run: %s" % (
        result.stderr.strip().splitlines() or ["no output"])[-1]


def merge_main(arguments):
    item = arguments.item
    state = load(item)
    worktree = state["worktree"]
    git("fetch", "-q", "origin", cwd=worktree)
    if git("status", "--porcelain", cwd=worktree):
        raise Refused("the worktree has uncommitted changes: commit them"
                      " first")
    head = git("rev-parse", "HEAD", cwd=worktree)
    if git("merge-base", "--is-ancestor", "origin/main", head, cwd=worktree,
           check=False) is not None:
        print("origin/main is already in %s: nothing to merge" % head[:12])
        return 0
    if not arguments.no_queue:
        taken, why = take(item, "final merge of main")
        if not taken:
            raise Refused(why)
    gate_inputs = gate_module("gate_inputs")
    log = git("log", "--format=%H%x00%B%x01", "HEAD..origin/main",
              cwd=worktree)
    brought = [entry.strip("\n").split("\0", 1)
               for entry in log.split("\x01") if entry.strip()]
    undeclared = [sha[:12] for sha, body in brought
                  if not gate_inputs.DECLARATION.search(body)]
    merged = subprocess.run(["git", "merge", "--no-ff", "--no-commit",
                             "origin/main"], cwd=worktree, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if merged.returncode != 0:
        conflicted = git("diff", "--name-only", "--diff-filter=U",
                         cwd=worktree, check=False) or ""
        journal(item, "merge of origin/main stopped on conflicts: %s"
                % " ".join(conflicted.split()))
        raise Refused(
            "the merge stopped on conflicts in %s: resolve them and commit."
            " A merge with resolved conflicts is a new tree: push it"
            " (`item.py push %s --watch`), then its boards. The promotion"
            " token stays %s's until main's gate on its promotion ends"
            % (", ".join(conflicted.split()) or "the files git names", item,
               item))
    tree = git("write-tree", cwd=worktree)
    same = gate_inputs.key(tree, cwd=worktree) == \
        gate_inputs.key(head, cwd=worktree)
    declare = same and not undeclared
    message = "Merge origin/main into %s" % state["branch"]
    if declare:
        message += ("\n\nEvery commit it brings says it is explanatory, and"
                    " the merged tree has the candidate's gate key.\n\n"
                    + EXPLANATORY)
    git("commit", "-q", "-m", message, cwd=worktree)
    merge = git("rev-parse", "HEAD", cwd=worktree)
    journal(item, "merged origin/main as %s%s" % (
        merge[:12], ", declared explanatory" if declare else ""))
    print("merged origin/main as %s" % merge[:12])
    if declare:
        print("it says `%s`: the gate reuses the candidate's pass, and a"
              " boards dispatch that passed on %s still counts; push it"
              " (`item.py push %s --watch`) and promote once its gate"
              " passes" % (EXPLANATORY, head[:12], item))
    else:
        reasons = []
        if undeclared:
            reasons.append("commits from main without `%s`: %s" % (
                EXPLANATORY, ", ".join(undeclared[:8])
                + (" and %d more" % (len(undeclared) - 8)
                   if len(undeclared) > 8 else "")))
        if not same:
            changed = [path for path in (git(
                "diff", "--name-only", head, tree, cwd=worktree) or ""
            ).splitlines() if path not in gate_inputs.CONTENT_FREE
                and not path.startswith(gate_inputs.CONTENT_FREE_TREES)]
            reasons.append("paths outside the explanatory set differ: %s" % (
                ", ".join(changed[:8]) + (" and %d more" % (len(changed) - 8)
                                          if len(changed) > 8 else "")
                if changed else "modes or paths of the explanatory files"))
        print("the merged tree is new (%s): push it (`item.py push %s"
              " --watch`), and once its gate passes dispatch its boards"
              % ("; ".join(reasons), item))
    stale = citations_problem(worktree)
    if stale:
        print(stale)
    return 0


def push(arguments):
    item = arguments.item
    state = load(item)
    worktree = state["worktree"]
    if git("status", "--porcelain", cwd=worktree):
        raise Refused("the worktree has uncommitted changes: commit them"
                      " first")
    if git("rev-parse", "-q", "--verify", "MERGE_HEAD", cwd=worktree,
           check=False):
        raise Refused("a merge is in progress: commit it first")
    stale = citations_problem(worktree)
    if stale:
        raise Refused(stale)
    git("push", "-q", "-u", "origin", "HEAD:refs/heads/%s" % state["branch"],
        cwd=worktree)
    head = git("rev-parse", "HEAD", cwd=worktree)
    journal(item, "pushed %s" % head[:12])
    print("pushed %s to %s" % (head[:12], state["branch"]))
    arguments.main = False
    return gate(arguments)


# ---------------------------------------------------------------- promotion

def explanatory_since(worktree, older, newer):
    """Whether every commit after OLDER up to NEWER says Gate: explanatory."""
    messages = git("log", "--format=%B%x00", "%s..%s" % (older, newer),
                   cwd=worktree)
    bodies = [body for body in messages.split("\0") if body.strip()]
    #  The gate's own reading: the declaration on a line of its own, not a
    #  sentence that mentions it.
    declaration = gate_module("gate_inputs").DECLARATION
    return all(declaration.search(body) for body in bodies)


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
        raise Refused("main has moved past the candidate's base: `item.py"
                      " merge-main %s` takes the promotion token, merges"
                      " origin/main and says whether the merged tree reuses"
                      " the pass; push it and gate it" % item)
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
        with queue_locked() as data:
            settle(data, ask=True)
            holder = data["holder"]
        print("would push %s to main; the promotion token is %s" % (
            commit[:12], "free" if not holder else "%s's" % holder["item"]))
        return 0
    taken, why = take(item, "promotion of %s" % commit[:12])
    if not taken:
        raise Refused(why)
    try:
        git("push", "origin", "%s:refs/heads/main" % commit, cwd=worktree)
    except Refused:
        release(item, "the push to main failed")
        raise
    mark_promoted(item, commit)
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
    release(item, "finished")
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
        out.append("  run %s: %s (%s)%s" % (
            entry["name"], run_state(entry["directory"]), entry["directory"],
            "" if entry.get("cwd", str(worktree)) == str(worktree)
            else ", in " + entry["cwd"]))
    for entry in state["gates"]:
        out.append("  gate run %s %s on %s: %s" % (
            entry["run"], entry["kind"], entry["commit"][:12],
            gate_text(entry, state["item"])))
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
                " `item.py promote %s`; if main has moved, `item.py merge-main"
                " %s` first, once" % (item, item, item, item))
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
    line = queue_line()
    if line:
        print(line)
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
        lines.append("  %s: %s%s, %s (log %s)" % (
            entry["name"], entry["command"],
            "" if entry.get("cwd", state["worktree"]) == state["worktree"]
            else " in " + entry["cwd"], run_state(entry["directory"]),
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
    sub.add_argument("--cwd", metavar="DIR", help="the directory the command"
                     " runs in, such as a stream's worktree (the item's"
                     " worktree)")
    sub.set_defaults(handler=run)

    sub = commands.add_parser("push", help="refuse stale citations, push the"
                              " head, record its gate runs")
    sub.add_argument("item")
    sub.add_argument("--watch", action="store_true", help="follow the gate"
                     " to its end in a detached gate_watch.py --all run")
    sub.set_defaults(handler=push)

    sub = commands.add_parser("merge-main", help="take the promotion token,"
                              " merge origin/main, and declare the merge"
                              " explanatory when the reuse rule allows it")
    sub.add_argument("item")
    sub.add_argument("--no-queue", action="store_true", help="a merge to"
                     " pick up main while work goes on, without the token;"
                     " the final merge still takes it")
    sub.set_defaults(handler=merge_main)

    sub = commands.add_parser("queue", help="the promotion token's holder"
                              " and line")
    which = sub.add_mutually_exclusive_group()
    which.add_argument("--wait", metavar="ITEM", help="return 0 once ITEM"
                       " holds the token, taking it; 124 at the timeout")
    which.add_argument("--release", metavar="ITEM", help="give up ITEM's"
                       " token or place in line")
    sub.add_argument("--timeout", type=float, default=270)
    sub.set_defaults(handler=queue)

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
    sub.add_argument("--unmerged", action="store_true", help="dispatch"
                     " although main is not an ancestor of the head")
    sub.add_argument("--rerun-failed", action="store_true", help="re-run"
                     " only the failed jobs of the head's boards run that"
                     " failed in timing alone")
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
