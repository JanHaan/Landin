#!/usr/bin/env python3
"""Build a budgeted, task-directed source context pack.

The pack keeps project guidance and Ada specifications, adds a mechanical
declaration/dependency outline, and spends the remaining budget on exact
source slices selected by a query. It reads tracked files and never changes
the source tree.
"""

import argparse
from dataclasses import dataclass
import hashlib
import math
import os
from pathlib import Path
import re
import subprocess
import sys


ADA_SUFFIXES = frozenset((".adb", ".ads", ".gpr"))
IMPLEMENTATION_SUFFIXES = frozenset((".adb", ".c"))
IGNORED_DIRECTORIES = frozenset((
    ".git", ".scratch", "build", "__pycache__",
))
QUERY_STOP_WORDS = frozenset((
    "a", "an", "and", "bug", "change", "code", "fix", "for", "from",
    "in", "into", "is", "it", "of", "on", "or", "the", "this", "to",
    "with",
))
DECLARATION = re.compile(
    r"^\s*(?:generic\b|package(?:\s+body)?\b|procedure\b|function\b|"
    r"type\b|subtype\b|task(?:\s+body|\s+type)?\b|"
    r"protected(?:\s+body|\s+type)?\b|entry\b)",
    re.IGNORECASE,
)
DEPENDENCY = re.compile(
    r"^\s*(?:(?:limited|private)\s+with\b|with\b|use\b)",
    re.IGNORECASE,
)
C_DECLARATION = re.compile(
    r"^\s*(?:#\s*(?:include|define)\b|"
    r"(?:[A-Za-z_]\w*[\s*]+)+[A-Za-z_]\w*\s*\([^;]*$)"
)


@dataclass(frozen=True)
class Source:
    path: Path
    display: str
    text: str
    digest: str


@dataclass(frozen=True)
class Block:
    category: str
    display: str
    score: int
    text: str


class TokenCounter:
    """Count o200k tokens when available, otherwise use a named estimate."""

    def __init__(self, choice):
        self.encoding = None
        if choice != "estimate":
            try:
                import tiktoken
                self.encoding = tiktoken.get_encoding("o200k_base")
            except Exception as error:
                if choice == "o200k":
                    raise ValueError(
                        "--tokenizer=o200k could not load the optional "
                        f"tiktoken counter: {error}"
                    ) from error
        self.name = (
            "o200k_base" if self.encoding is not None
            else "estimated tokens (UTF-8 bytes / 3)"
        )

    def count(self, text):
        if self.encoding is not None:
            return len(self.encoding.encode(text))
        return math.ceil(len(text.encode("utf-8")) / 3)


def command_output(arguments, cwd):
    try:
        completed = subprocess.run(
            arguments, cwd=cwd, check=False, capture_output=True,
        )
    except OSError:
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout


def repository_files(requested):
    """Return the repository root and tracked paths below requested."""
    probe = requested if requested.is_dir() else requested.parent
    root_bytes = command_output(
        ["git", "rev-parse", "--show-toplevel"], probe,
    )
    if root_bytes is not None:
        repository = Path(os.fsdecode(root_bytes.strip())).resolve()
        relative = requested.resolve().relative_to(repository)
        names = command_output(
            ["git", "ls-files", "-z", "--", os.fspath(relative)],
            repository,
        )
        if names is None:
            raise ValueError(f"could not list tracked files below {requested}")
        paths = [
            repository / os.fsdecode(name)
            for name in names.split(b"\0") if name
        ]
        return repository, paths

    repository = requested.resolve() if requested.is_dir() else requested.parent
    if requested.is_file():
        return repository, [requested.resolve()]
    paths = []
    for directory, names, filenames in os.walk(requested):
        names[:] = sorted(name for name in names if name not in IGNORED_DIRECTORIES)
        paths.extend(Path(directory) / name for name in sorted(filenames))
    return repository, paths


def read_sources(repository, paths):
    sources = []
    for path in paths:
        try:
            data = path.read_bytes()
            if b"\0" in data:
                continue
            text = data.decode("utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        sources.append(Source(
            path=path,
            display=path.relative_to(repository).as_posix(),
            text=text,
            digest=hashlib.sha256(data).hexdigest(),
        ))
    return sources


def query_words(query):
    words = {
        word.casefold()
        for word in re.findall(r"[A-Za-z][A-Za-z0-9_]{1,}", query)
        if word.casefold() not in QUERY_STOP_WORDS
    }
    expanded = set(words)
    for word in words:
        expanded.update(
            part for part in word.split("_")
            if len(part) > 1 and part not in QUERY_STOP_WORDS
        )
    return tuple(sorted(expanded))


def relevance(display, text, words):
    if not words:
        return 0
    path = display.casefold()
    folded = text.casefold()
    score = 0
    for word in words:
        if len(word) <= 3:
            pattern = rf"(?<![a-z0-9]){re.escape(word)}(?![a-z0-9])"
            path_count = len(re.findall(pattern, path))
            text_count = len(re.findall(pattern, folded))
        else:
            path_count = path.count(word)
            text_count = folded.count(word)
        score += 60 * path_count
        score += min(30, text_count)
    return score


def strip_ada_comment(line):
    """Remove an Ada comment while respecting doubled quotes in strings."""
    index = 0
    quoted = False
    while index < len(line):
        if line[index] == '"':
            if quoted and index + 1 < len(line) and line[index + 1] == '"':
                index += 2
                continue
            quoted = not quoted
            index += 1
            continue
        if not quoted and line[index:index + 2] == "--":
            return line[:index]
        index += 1
    return line


def normalize_outside_strings(line):
    output = []
    index = 0
    quoted = False
    pending_space = False
    while index < len(line):
        character = line[index]
        if character == '"':
            if pending_space and output and output[-1] not in "([,":
                output.append(" ")
            pending_space = False
            output.append(character)
            if quoted and index + 1 < len(line) and line[index + 1] == '"':
                output.append('"')
                index += 2
                continue
            quoted = not quoted
            index += 1
            continue
        if not quoted and character.isspace():
            pending_space = True
            index += 1
            continue
        if not quoted and character in "()[],;":
            while output and output[-1] == " ":
                output.pop()
            output.append(character)
            pending_space = False
            index += 1
            continue
        if pending_space and output and output[-1] not in "([,":
            output.append(" ")
        pending_space = False
        output.append(character)
        index += 1
    return "".join(output).strip()


def compact_interface(text):
    """Produce a line-preserving, comment-free view of Ada source."""
    lines = []
    for original in text.splitlines():
        line = normalize_outside_strings(strip_ada_comment(original))
        if line:
            lines.append(line)
    return "\n".join(lines) + ("\n" if lines else "")


def source_block(source, mode="full", first=None, last=None):
    if first is None:
        contents = source.text
        location = ""
    else:
        lines = source.text.splitlines(keepends=True)
        contents = "".join(lines[first - 1:last])
        location = f' lines="{first}-{last}"'
    if contents and not contents.endswith("\n"):
        contents += "\n"
    return (
        f'<source path="{source.display}" mode="{mode}"{location} '
        f'sha256="{source.digest}">\n{contents}</source>\n'
    )


def declaration_outline(source):
    lines = source.text.splitlines()
    rows = []
    suffix = source.path.suffix.lower()
    for number, line in enumerate(lines, 1):
        without_comment = (
            strip_ada_comment(line) if suffix in ADA_SUFFIXES else line
        )
        matches = (
            DECLARATION.match(without_comment)
            or DEPENDENCY.match(without_comment)
            if suffix in ADA_SUFFIXES
            else C_DECLARATION.match(without_comment)
        )
        if matches:
            normalized = " ".join(without_comment.split())
            rows.append(f"{number}: {normalized}")
    if not rows:
        return ""
    return (
        f'<outline path="{source.display}" sha256="{source.digest}">\n'
        + "\n".join(rows)
        + "\n</outline>\n"
    )


def source_chunks(source, words, chunk_lines, overlap):
    lines = source.text.splitlines(keepends=True)
    if not lines or not words:
        return []
    step = chunk_lines - overlap
    chunks = []
    for start in range(0, len(lines), step):
        stop = min(len(lines), start + chunk_lines)
        contents = "".join(lines[start:stop])
        # A matching path ranks a chunk, but does not make every chunk from a
        # large file relevant. At least one query word must occur in the
        # chunk's exact text.
        score = relevance("", contents, words)
        if score:
            score += relevance(source.display, "", words)
            chunks.append(Block(
                category="exact source",
                display=f"{source.display}:{start + 1}-{stop}",
                score=score,
                text=source_block(
                    source, mode="exact", first=start + 1, last=stop,
                ),
            ))
        if stop == len(lines):
            break
    return chunks


def guidance_sources(repository, requested, sources):
    selected = []
    source_paths = {source.path.resolve() for source in sources}
    current = requested.resolve() if requested.is_dir() else requested.parent.resolve()
    while current == repository or repository in current.parents:
        candidate = current / "AGENTS.md"
        if candidate.is_file() and candidate.resolve() not in source_paths:
            selected.extend(read_sources(repository, [candidate]))
        if current == repository:
            break
        current = current.parent
    return selected


def take_blocks(candidates, limit, counter, selected, selected_ids):
    used = 0
    for block in candidates:
        identity = (block.category, block.display)
        if identity in selected_ids:
            continue
        cost = counter.count(block.text)
        if used + cost <= limit:
            selected.append(block)
            selected_ids.add(identity)
            used += cost
    return used


def build_pack(args):
    requested = args.path.resolve()
    if not requested.exists():
        raise ValueError(f"path does not exist: {args.path}")
    repository, paths = repository_files(requested)
    sources = read_sources(repository, paths)
    guidance = guidance_sources(repository, requested, sources)
    counter = TokenCounter(args.tokenizer)
    words = query_words(args.query)
    if not words:
        raise ValueError("query contains no searchable words")

    direct = []
    interfaces = []
    outlines = []
    exact = []
    requested_directory = requested if requested.is_dir() else requested.parent

    for source in guidance:
        direct.append(Block(
            "guidance", source.display, 10_000,
            source_block(source, mode="full"),
        ))

    for source in sources:
        suffix = source.path.suffix.lower()
        is_direct = source.path.parent.resolve() == requested_directory.resolve()
        if is_direct and (
            source.path.name in ("AGENTS.md", "README.md", "TOOLCHAIN.md")
            or suffix == ".gpr"
        ):
            direct.append(Block(
                "guidance", source.display,
                9_000 + relevance(source.display, source.text, words),
                source_block(source, mode="full"),
            ))
        elif suffix == ".ads":
            contents = (
                compact_interface(source.text)
                if args.compact_interfaces else source.text
            )
            rendered = Source(
                source.path, source.display, contents, source.digest,
            )
            mode = "compact-interface" if args.compact_interfaces else "full"
            interfaces.append(Block(
                "interface", source.display,
                relevance(source.display, source.text, words),
                source_block(rendered, mode=mode),
            ))
        elif suffix in IMPLEMENTATION_SUFFIXES:
            outline = declaration_outline(source)
            if outline:
                outlines.append(Block(
                    "outline", source.display,
                    relevance(source.display, outline, words), outline,
                ))
            exact.extend(source_chunks(
                source, words, args.chunk_lines, args.chunk_overlap,
            ))

    ordering = lambda block: (-block.score, block.display)
    direct.sort(key=ordering)
    interfaces.sort(key=ordering)
    outlines.sort(key=ordering)
    exact.sort(key=ordering)

    reserve = min(2_000, max(300, args.budget_tokens // 100))
    usable = args.budget_tokens - reserve
    selected = []
    selected_ids = set()
    used = 0
    used += take_blocks(
        direct, usable * 15 // 100, counter, selected, selected_ids,
    )
    used += take_blocks(
        exact, usable * 40 // 100, counter, selected, selected_ids,
    )
    used += take_blocks(
        interfaces, usable * 35 // 100, counter, selected, selected_ids,
    )
    used += take_blocks(
        outlines, usable * 10 // 100, counter, selected, selected_ids,
    )

    remainder = usable - used
    leftovers = sorted(
        exact + interfaces + outlines + direct,
        key=lambda block: (
            {"outline": 0, "interface": 1,
             "exact source": 2, "guidance": 3}[block.category],
            -block.score, block.display,
        ),
    )
    take_blocks(leftovers, remainder, counter, selected, selected_ids)

    category_order = {
        "guidance": 0, "interface": 1, "outline": 2, "exact source": 3,
    }
    def output_order(block):
        match = re.match(r"^(.*):(\d+)-(\d+)$", block.display)
        if match is None:
            return category_order[block.category], block.display, 0
        return category_order[block.category], match.group(1), int(match.group(2))

    selected.sort(key=output_order)
    body = "\n".join(block.text for block in selected)
    def make_header():
        included = {
            category: sum(block.category == category for block in selected)
            for category in category_order
        }
        return (
            "# Source context pack\n\n"
            f"requested-path: {requested.relative_to(repository).as_posix()}\n"
            f"query: {args.query}\n"
            f"token-budget: {args.budget_tokens}\n"
            f"token-counter: {counter.name}\n"
            f"tracked-text-files-seen: {len(sources)}\n"
            f"included-blocks: {len(selected)}\n"
            f"included-guidance: {included['guidance']}\n"
            f"included-interfaces: {included['interface']}\n"
            f"included-outlines: {included['outline']}\n"
            f"included-exact-slices: {included['exact source']}\n"
            "\n"
            "Outlines are mechanical indexes. Compact interfaces have comments "
            "and optional layout removed. Exact source slices retain original "
            "text; consult the named file before editing.\n\n"
        )

    header = make_header()
    output = header + body
    while selected and counter.count(output) > args.budget_tokens:
        selected.pop()
        body = "\n".join(block.text for block in selected)
        header = make_header()
        output = header + body
    return output, counter.count(output), counter.name, selected


def parse_arguments(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="file or directory to package")
    parser.add_argument(
        "--query", required=True,
        help="task, diagnostic, symbol, or concept used to rank exact source",
    )
    parser.add_argument(
        "--budget-tokens", type=int, default=500_000,
        help="maximum packed tokens or estimated tokens (default: 500000)",
    )
    parser.add_argument(
        "--tokenizer", choices=("auto", "estimate", "o200k"), default="auto",
        help="use optional tiktoken or a standard-library byte estimate",
    )
    parser.add_argument(
        "--compact-interfaces", action="store_true",
        help="strip Ada interface comments and optional layout",
    )
    parser.add_argument(
        "--chunk-lines", type=int, default=240,
        help="maximum lines in a task-selected exact slice (default: 240)",
    )
    parser.add_argument(
        "--chunk-overlap", type=int, default=0,
        help="overlap between candidate source slices (default: 0)",
    )
    parser.add_argument(
        "--output", type=Path,
        help="write the pack here instead of standard output",
    )
    args = parser.parse_args(argv)
    if args.budget_tokens < 1_000:
        parser.error("--budget-tokens must be at least 1000")
    if args.chunk_lines < 20:
        parser.error("--chunk-lines must be at least 20")
    if not 0 <= args.chunk_overlap < args.chunk_lines:
        parser.error("--chunk-overlap must be smaller than --chunk-lines")
    return args


def main(argv=None):
    args = parse_arguments(argv)
    try:
        output, tokens, counter_name, selected = build_pack(args)
        if args.output is None:
            sys.stdout.write(output)
        else:
            args.output.write_text(output, encoding="utf-8")
            print(
                f"wrote {args.output}: {tokens} {counter_name}; "
                f"{len(selected)} blocks",
                file=sys.stderr,
            )
    except (OSError, ValueError) as error:
        print(f"context_pack.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
