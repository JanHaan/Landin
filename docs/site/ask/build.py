#!/usr/bin/env python3
"""Build the private Q&A snapshot and preview; no network or publication."""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))
import render_html as site  # noqa: E402

MAX_CHARS = 6000


def authority(name):
    if name == "spec.md":
        return "normative language rules"
    if name == "README.md":
        return "current compiler capabilities and project status"
    if name == "ROADMAP.md":
        return "open work and future plans; status must be read explicitly"
    if name.startswith("prototype-"):
        return "design stress test, including historical syntax; not runnable"
    if name == "tour.md":
        return "language explanation; wider than the enabled compiler kernel"
    if name == "environments/native-ci/README.md":
        return "retired acceptance arrangement; historical only"
    return "derived guide or design explanation; not normative"


def sections(text):
    """Use the renderer's heading IDs, ignoring headings inside fences."""
    title, anchor, lines, fenced = "Introduction", "", [], False
    for line in text.splitlines(keepends=True):
        if line.startswith("```"):
            fenced = not fenced
        found = None if fenced else re.match(r"^(#{1,6}) (.+?)\s*$", line)
        if found:
            if lines:
                yield title, anchor, "".join(lines)
            title = found.group(2)
            construct = re.match(r"^\[(\d{4})\]", title)
            anchor = construct.group(1) if construct else site.slug(title)
            lines = [line]
        else:
            lines.append(line)
    if lines:
        yield title, anchor, "".join(lines)


def split_text(text):
    # Cut at paragraph/line boundaries when possible. Preserve every byte;
    # a long code block may span passages, with the same heading and URL.
    while text:
        end = min(len(text), MAX_CHARS)
        if end < len(text):
            cut = text.rfind("\n\n", MAX_CHARS // 2, end)
            if cut < 0:
                cut = text.rfind("\n", MAX_CHARS // 2, end)
            if cut >= 0:
                end = cut + 1
        yield text[:end]
        text = text[end:]


def terms(text):
    return dict(collections.Counter(re.findall(r"[a-z0-9_]+", text.lower())))


def make_corpus(root=ROOT):
    entries, digest = [], hashlib.sha256()
    pages = site.DOCS + site.GUIDES
    for page in pages:
        name = page["src"]
        raw = (root / name).read_bytes()
        digest.update(name.encode() + b"\0" + raw + b"\0")
        for title, anchor, body in sections(raw.decode("utf-8")):
            for number, part in enumerate(split_text(body)):
                identity = f"{name}\0{anchor}\0{number}\0{part}"
                entry = dict(
                    id="p" + hashlib.sha256(identity.encode()).hexdigest()[:16],
                    source=name, title=title, authority=authority(name),
                    url=f"{site.SITE_URL}/{page['out']}"
                        + (f"#{anchor}" if anchor else ""),
                    text=part, terms=terms(title + "\n" + part))
                entry["length"] = sum(entry["terms"].values())
                entries.append(entry)
    ids = [entry["id"] for entry in entries]
    if len(ids) != len(set(ids)) or not entries:
        raise SystemExit("ask: empty corpus or duplicate passage identity")
    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    source_paths = [page["src"] for page in pages]
    source_paths += ["docs/site/render_html.py", "docs/site/llms.py"]
    dirty = subprocess.run(
        ["git", "diff", "--quiet", "HEAD", "--", *source_paths],
        cwd=root, check=False).returncode
    if dirty not in (0, 1):
        raise SystemExit("ask: could not inspect snapshot source changes")
    postings = collections.defaultdict(list)
    for index, entry in enumerate(entries):
        for word, count in entry.pop("terms").items():
            postings[word].append([index, count])
    return dict(schema=1, commit=commit, dirty=bool(dirty),
                sha256=digest.hexdigest(), passages=entries, postings=dict(postings),
                averageLength=sum(entry["length"] for entry in entries) / len(entries))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", action="store_true",
                        help="require all deployment inputs to be committed")
    args = parser.parse_args()
    corpus = make_corpus()
    if args.release:
        changes = subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=all", "--",
             "docs/site/ask", "docs/site/llms.py", "docs/site/render_html.py",
             *[p["src"] for p in site.DOCS + site.GUIDES]],
            cwd=ROOT, text=True)
        if changes.strip():
            raise SystemExit("ask: commit deployment inputs before release")
    output = HERE / "build"
    public = output / "public"
    public.mkdir(parents=True, exist_ok=True)
    (output / "corpus.json").write_text(
        json.dumps(corpus, ensure_ascii=False, separators=(",", ":")) + "\n")
    for path in (HERE / "public").iterdir():
        if path.is_file():
            shutil.copyfile(path, public / path.name)
    # All brand assets still come from their repository-owned modules.
    (public / "icon.svg").write_text(site.landin_icon.svg("auto"))
    css = site.fonts.css() + "\n:root{--ui:" + site.fonts.stack("ui")
    css += ";--mono:" + site.fonts.stack("mono") + ";"
    css += f"--bg:{site.landin_icon.PAPER};--accent:{site.landin_icon.ACCENT};"
    css += "}\n@media(prefers-color-scheme:dark){:root{"
    css += f"--bg:{site.landin_icon.INK};--accent:{site.landin_icon.ACCENT_DARK};"
    css += "}}\n"
    (public / "brand.css").write_text(css)
    for name, path in site.fonts.files():
        target = public / "fonts" / name
        target.parent.mkdir(exist_ok=True)
        shutil.copyfile(path, target)
    print(f"ask: {len(corpus['passages'])} passages; "
          f"snapshot {corpus['sha256'][:12]}; dirty={corpus['dirty']}")


if __name__ == "__main__":
    main()
