"""The two files an agent asks a site for, generated from the sources.

`llms.txt` is the convention: a title, a summary, and annotated links.
`llms-full.txt` is everything, and it opens with a primer, because the
documents alone are a poor brief for writing Landin. The tour teaches the
language and the compiler enables a kernel narrower than the language, so
an agent that reads only the tour writes programs the compiler refuses by
name. The primer puts the kernel's vocabulary, its grammar in one piece,
every refused spelling and every diagnostic code in front of the prose.

Nothing here is written twice. The vocabulary and the grammar come out of
`spec.md`'s own `landin-grammar` fences, the refusals out of the two
tables the compiler dispatches on, the codes out of the catalogue
`check.py` already generates, the installation out of the README and the
invocation out of `examples.md`.
A rule that moves in any of those moves here with it.

Standard library only, like the rest of the site build.
"""
import re


SUMMARY = (
    "One systems language from a 32 KB microcontroller to a hosted "
    "application. Manual memory with arenas as the idiom and no garbage "
    "collector, reference counting or destructors; separate reference "
    "permission and binding mutability; local origin and escape analysis "
    "rather than a borrow checker; concepts with evidence tables for both "
    "static generics and runtime dispatch; no compile-time execution and no "
    "macros. Native backends emit assembly for hosted systems and "
    "microcontrollers; the capabilities page lists the current targets."
)

#  The two halves of [1830], as the compiler dispatches on them.  The
#  parser owns the spellings only it can tell from an enabled form; the
#  checker owns the ones that are a question about what a name resolved
#  to.  Both say what each refused form is.
REFUSAL_TABLES = (
    ("the parser", "compiler/ada/src/diagnostics/"
                   "landin-diagnostics-syntactic.ads", "Refused_Construct"),
    ("the checker", "compiler/ada/src/diagnostics/"
                    "landin-diagnostics-checking.ads", "Refused_Use"),
)
#  What each standing is called where a reader sees it.
STANDINGS = {"Recorded_Boundary": "a recorded source-form boundary",
             "Withdrawn": "withdrawn",
             "Transferred": "transferred to Language evolution"}


def read(source, name):
    path = source / name
    return path.read_text(encoding="utf-8") if path.exists() else ""


def version(readme):
    """The one place a version is written is README.md's status line."""
    found = re.search(r"specification (\d+\.\d+\.\d+)", readme)
    return found.group(1) if found else "unreleased"


def grammar(spec):
    """Every `landin-grammar` fence, in document order, as one grammar.

    The fences are interleaved with the prose that explains them, which is
    right for a reader and wrong for anything that wants the grammar. This
    is the same productions with the prose taken out.
    """
    return "\n".join(
        block.strip("\n")
        for block in re.findall(r"^```landin-grammar\n(.*?)^```$", spec,
                                re.S | re.M))


def production(rules, name):
    """One rule's quoted terminals, in the order the grammar writes them."""
    found = re.search(r"^%s\s*::=(.*?)(?=^\S|\Z)" % re.escape(name),
                      rules + "\n\u0000", re.S | re.M)
    return re.findall(r'"([^"]+)"', found.group(1)) if found else []


#  The lexical layer: rules that spell out part of a token and produce
#  nothing of their own.  Their terminals are bytes, not words, and a set
#  of words derived without excluding them contains `a`, `e`, `f`, `n` and
#  every `packed_unsigned` width.
SPELLING_RULES = frozenset((
    "lower", "digit", "hex_digit", "character_escape", "text_escape",
    "decimal_exponent", "binary_exponent", "packed_unsigned",
    "scalar_name", "text_name",
))


def owners(rules):
    """Which productions write each quoted word."""
    blocks = re.split(r"^(\S+)\s*::=", rules, flags=re.M)
    out = {}
    for name, body in zip(blocks[1::2], blocks[2::2]):
        for word in re.findall(r'"([a-z][a-z0-9_]*)"', body):
            out.setdefault(word, set()).add(name)
    return out


def contextual(rules, reserved):
    """Words a production recognises that [1760] does not reserve.

    Derived rather than transcribed: a quoted word the `keyword` rule
    omits is one the enclosing production recognises and an ordinary
    identifier everywhere else, which is the commonest way to misread the
    grammar. `variant`, `of` and `c` are here; `if` is not, and neither is
    the `e` of an exponent.
    """
    reserved = set(reserved)
    return sorted(
        word for word, where in owners(rules).items()
        if word not in reserved and where - SPELLING_RULES)


def cases(text, function, kind):
    """Read an Ada expression-function case table into a dict.

    `when A | B => "x"` binds both names, which is how the refusal tables
    are written and why the arms are split rather than matched whole. The
    value is a string literal in some of these tables and a bare
    enumeration name in `Refusal` and `Standing`, so both are read.
    """
    found = re.search(
        r"function %s\s*\(Item\s*:\s*%s\)[^()]*?is\s*\(case Item is(.*?)\);"
        % (re.escape(function), re.escape(kind)), text, re.S)
    if not found:
        return {}
    out = {}
    for arm in re.finditer(r"when\s+(.+?)\s*=>\s*(\"[^\"]*\"|[A-Za-z0-9_]+)",
                           re.sub(r"--[^\n]*", "", found.group(1)), re.S):
        for name in re.findall(r"[A-Za-z0-9_]+", arm.group(1)):
            out[name] = arm.group(2).strip('"')
    return out


def literals(text, kind):
    """The enumeration literals of an Ada type, in order; none if absent."""
    found = re.search(r"type %s is\s*\((.*?)\);" % re.escape(kind),
                      re.sub(r"--[^\n]*", "", text), re.S)
    return re.findall(r"[A-Za-z0-9_]+", found.group(1)) if found else []


def whole(text, path, function, kind):
    """`cases`, held to an arm for every literal of the kind.

    `cases` returns nothing when its pattern stops matching, after a
    parameter is renamed or an expression function is given a body, and a
    table that reads as nothing leaves the primer short of every refusal
    it owns with no word of it: the other table still yields rows.  So a
    reading that does not cover its enumeration stops the build.
    """
    names = literals(text, kind)
    got = cases(text, function, kind)
    missing = [name for name in names if name not in got]
    if not names or missing:
        raise SystemExit(
            "llms: %s: %s over %s was read for %d of its %d literals%s -- "
            "the primer would ship without the rest"
            % (path, function, kind, len(names) - len(missing), len(names),
               ", not for " + ", ".join(missing[:6]) if missing else ""))
    return got


def refusals(source):
    """Every spelling the compiler refuses by name, with its paragraph.

    Ordered as the tables are, and reported as what they are. None of
    these is unimplemented work: [1830] distinguishes a source form an
    implemented construct does not admit from a form the language withdrew
    and one a successor roadmap owns, and each table says which.
    """
    out = []
    for whose, path, kind in REFUSAL_TABLES:
        text = read(source, path)
        if not text:
            raise SystemExit("llms: %s's refusal table, %s, is not there -- "
                             "the primer would ship without its refusals"
                             % (whose, path))
        where = whole(text, path, "Construct", kind)
        standing = whole(text, path, "Standing", kind)
        #  Only the checker's table spells type names.
        spelt = bool(literals(text, "Refused_Type_Name"))
        spelling = (whole(text, path, "Spelling", "Refused_Type_Name")
                    if spelt else {})
        names = (whole(text, path, "Refusal", "Refused_Type_Name")
                 if spelt else {})
        written = {}
        for name, refused in names.items():
            written.setdefault(refused, []).append(spelling.get(name, name))
        for name in where:
            out.append((whose, name.replace("_", " ").lower(),
                        ", ".join(sorted(written.get(name, []))),
                        where[name], STANDINGS.get(standing.get(name), "")))
    return out


def titles(source):
    """`[NNNN]` to the sentence the documents head it with.

    A refusal names a category the compiler dispatches on -- `struct
    value`, `array element` -- which says nothing to a reader who has not
    read the Ada. The construct it cites is what says what was refused,
    so the two are reported together.
    """
    out = {}
    for name in ("tour.md", "spec.md"):
        for one, title in re.findall(r"^### \[(\d{4})\] (.+)$",
                                     read(source, name), re.M):
            out[one] = title
    return out


def vocabulary(rules):
    keywords = production(rules, "keyword")
    scalars = production(rules, "scalar_name")
    texts = production(rules, "text_name")
    return keywords, scalars, texts, contextual(rules, keywords)


def wrap(words, width=68, lead="  "):
    lines, row = [], lead
    for word in words:
        if len(row) + len(word) + 1 > width and row.strip():
            lines.append(row.rstrip())
            row = lead
        row += word + " "
    if row.strip():
        lines.append(row.rstrip())
    return "\n".join(lines)


def measure(text):
    """A size a reader can weigh against a context window."""
    size = len(text.encode("utf-8"))
    return ("%d KB" % round(size / 1024) if size < 1024 * 1024
            else "%.1f MB" % (size / 1024 / 1024))


def section(text, heading):
    """One `## heading` section of a Markdown document, heading included."""
    found = re.search(r"^## %s$(.*?)(?=^## |\Z)" % re.escape(heading),
                      text, re.S | re.M)
    return found.group(0).strip("\n") if found else ""


def primer(source, release, site_url):
    spec = read(source, "spec.md")
    rules = grammar(spec)
    keywords, scalars, texts, other = vocabulary(rules)
    refused = refusals(source)
    catalogue = read(source, "compiler/tests/diagnostics.catalogue")
    codes = "\n".join(line for line in catalogue.splitlines()
                      if not line.startswith("#"))
    invocation = section(read(source, "examples.md"), "Compile and run")
    installing = section(read(source, "README.md"), "Installing")

    #  Everything above is read out of something that can be renamed, and
    #  a reader that finds nothing would write a primer with a missing
    #  section rather than fail.  That is the failure this project keeps
    #  learning: a check that is quietly skipped reads the same as one
    #  that passed.  So an empty reading stops the build and says which.
    empty = [what for what, got in
             (("the grammar of spec.md", rules),
              ("[1760]'s keyword production", keywords),
              ("the scalar_name production", scalars),
              ("the compiler's refusal tables", refused),
              ("the diagnostic catalogue", codes),
              ("examples.md's `Compile and run`", invocation),
              ("README.md's `Installing`", installing))
             if not got]
    if empty:
        raise SystemExit("llms: nothing read from " + ", ".join(empty)
                         + " -- the primer would ship that section empty")

    out = ["# Landin %s, for whoever has to write it" % release, "",
           SUMMARY, "",
           "This half of the file is generated from the compiler's own "
           "tables and", "the specification's own grammar. The documents "
           "follow it in full.", "",
           "The one thing to know first: the kernel the compiler enables is "
           "narrower", "than the language the tour describes, and the "
           "compiler says which is", "which by name rather than guessing "
           "([1830]). Section 4 is that list. A", "program written against "
           "the whole tour fails with it, not with a parse", "error.", ""]

    #  A link written for the README's own page means nothing in a text
    #  file, so the README's links resolve to its published page, and the
    #  invocation's link to the README to the steps just above it there.
    def published(text):
        return re.sub(r"\]\((?:README\.md)?#([\w-]+)\)",
                      lambda m: "](%s/readme.html#%s)" % (site_url, m[1]),
                      text)

    out += ["## 1. Install, compile and run", "",
            published(installing.split("\n", 1)[1].strip("\n")), "",
            published(invocation.split("\n", 1)[1].strip("\n")), ""]

    out += ["## 2. The vocabulary of the enabled kernel", "",
            "%d reserved words. Reserved everywhere, including in ordinary "
            "name" % len(keywords),
            "positions (D225), so `begin: i32 = 10` is invalid and "
            "`begin_value` is not.", "", wrap(keywords), "",
            "%d scalar type names. Not keywords: they are ordinary declared "
            "names" % len(scalars),
            "the kernel predeclares, so nothing stops a program shadowing "
            "one.", "", wrap(scalars), ""]
    if texts:
        out += ["%d text type names, on the same footing." % len(texts), "",
                wrap(texts), ""]
    out += ["Words a production recognises that nothing reserves. Each is an "
            "ordinary", "identifier wherever its own production does not "
            "meet it, which is the", "commonest way to misread the grammar.",
            "", wrap(other), ""]

    out += ["## 3. The grammar of the enabled kernel, in one piece", "",
            "The %d productions of [1740] to [1830], with the prose that "
            "explains" % len(re.findall(r"^\S+\s*::=", rules, re.M)),
            "them removed. A name in lower case is a rule, a quoted word is "
            "itself,",
            "`?` is optional, `*` is none or more, `+` is one or more, "
            "`...` between",
            "two quoted bytes is every byte from one to the other, and "
            "parentheses",
            "group. This is what the hand-written parser is written "
            "against, and", "`check.py` derives the whole fixture corpus "
            "from it.", "", "```", rules, "```", ""]

    out += ["## 4. Spellings the compiler refuses by name", "",
            "Read this before writing anything the tour shows. Each row is "
            "a form",
            "the compiler recognises and declines, with the paragraph that "
            "describes",
            "it and what it is. None is pending work: [1830] separates a "
            "source form",
            "an implemented construct does not admit from a form the "
            "language",
            "withdrew and one a successor roadmap owns, and `spec.md`'s "
            "register", "says why for each.", ""]
    named = titles(source)
    for where in sorted({row[3] for row in refused}):
        out.append("  %s %s" % (where, named.get(where.strip("[]"), "")))
        for whose, name, written, at, standing in refused:
            if at != where:
                continue
            out.append("      %s refuses `%s`%s; %s"
                       % (whose, name,
                          ", spelled %s" % written if written else "",
                          standing))
    out.append("")

    if codes:
        out += ["## 5. Every diagnostic code", "",
                "What `refine` prints, and the rule behind it. `Retired` "
                "means the code",
                "is spent and never issued. Generated from the catalogue "
                "that owns", "them; nothing else writes a code.", "",
                "```", codes, "```", ""]

    out += ["## 6. What follows", "",
            "`tour.md` teaches the language, construct by numbered "
            "construct.",
            "`spec.md` decides it: the grammar above, the rules the tour "
            "leaves",
            "unsaid, and a register of every decision with the alternative "
            "it was",
            "chosen over and the fixture that pins it. `examples.md` holds "
            "complete",
            "programs that print what they compute, which the gate runs. "
            "Where the tour and the",
            "specification could be read differently, the specification "
            "decides.", ""]
    return "\n".join(out)


def index(pages, site_url, release, sizes, programs):
    """The convention: a title, a summary, then annotated links.

    The link list is built from the site's own page table, so a page that
    is added or renamed cannot leave a stale entry here.  PROGRAMS is how
    many programs examples.md holds, counted there: written here by hand
    it said eleven while the page held twenty-three.
    """
    def link(key, note):
        for page in pages:
            if page["key"] == key:
                return "- [%s](%s/%s): %s" % (page["nav"], site_url,
                                              page["out"], note)
        return ""

    groups = [
        ("Writing Landin", [
            ("", "- [Library reference](%s/library.html): public API signatures, "
                 "contracts, module overviews and executable examples. "
                 "The searchable inventory is [library-index.json](%s/library-index.json)."
                 % (site_url, site_url)),
            ("", "- [Installing](%s/readme.html#installing): the nix "
                 "routes, where a release archive unpacks and what "
                 "`refine version` prints." % site_url),
            ("", "- [The primer](%s/llms-primer.txt): start here. Generated "
                 "from the compiler's own tables — how to install, compile "
                 "and run, "
                 "the kernel's vocabulary, its grammar in one piece, every "
                 "spelling the compiler refuses by name, and every "
                 "diagnostic code. %s." % (site_url, sizes["primer"])),
            ("tour", "the language explained construct by numbered "
                     "construct, teaching by example. Teaches; does not "
                     "decide."),
            ("examples", "%d complete programs the compiler emits and the "
                         "gates run. Each is known to compile and run, so "
                         "each is safe to copy from." % programs),
        ]),
        ("Deciding what is legal", [
            ("spec", "normative. The grammar of the enabled kernel, the "
                     "rules the tour leaves unsaid, and every decision with "
                     "its alternative and the fixture that pins it."),
            ("documents", "which of the two documents holds which kind of "
                          "rule, and where a new one goes. Read it before "
                          "citing either."),
            ("fixtures", "the fixture corpus: what the compiler is held to "
                         "accept and refuse, and the format that outlives "
                         "the implementation checking it."),
        ]),
        ("Optional", [
            ("", "- [Everything in one file](%s/llms-full.txt): the primer "
                 "above, then the tour, the specification and the worked "
                 "programs in full. %s, most of it the register of "
                 "decisions, which says why a rule is what it is rather "
                 "than what to write." % (site_url, sizes["full"])),
            ("capabilities", "what the compiler, its library and its "
                             "tooling do today, target by target."),
            ("handoff", "the design in one page, and which decisions must "
                        "not be quietly reversed."),
            ("roadmap", "the sole authority for open work: its phases, "
                        "their items and gates, and the register."),
            ("ir", "how checked source becomes verified target-neutral IR."),
            ("targets", "target descriptions, ABI capabilities and backend "
                        "boundaries."),
            ("bindings", "the C binding generator's complete policy schema, "
                         "invocation and generated interfaces."),
            ("editors", "installable highlighting for the major editor "
                        "families."),
        ]),
    ]

    out = ["# Landin", "", "> " + SUMMARY, "",
           "Specification %s. Deliberately partial: it says what is true "
           "today rather" % release,
           "than what is intended, and it grows one slice at a time. There "
           "is no",
           "package acquisition story yet, and no claim of "
           "memory or",
           "resource safety — the language is deliberately unsafe with "
           "useful local",
           "checks. Read llms-full.txt before writing a program: the "
           "compiler enables",
           "a kernel narrower than the tour describes, and refuses the "
           "difference by",
           "name.", ""]
    for title, entries in groups:
        out += ["## " + title, ""]
        for key, note in entries:
            out.append(note if not key else link(key, note))
        out.append("")
    return "\n".join(line for line in out if line is not None)


def write(site, source, pages, site_url):
    """The three files, beside the sitemap. Returns what was written.

    Three and not two because the convention's pair does not fit this
    project. `llms-full.txt` carries the whole specification, and most of
    that is the register: 242 decisions with the alternative each was
    chosen over, which answers why a rule is what it is and is not what
    anyone writing a program needs to read. The primer alone is the file
    an agent can afford, so it is written on its own as well as at the
    head of the full one.
    """
    release = version(read(source, "README.md"))
    brief = primer(source, release, site_url)
    full = brief + "\n" + "\n\n".join(
        "".join(["=" * 72, "\n", name, "\n", "=" * 72, "\n\n",
                 read(source, name).strip("\n")])
        for name in ("tour.md", "spec.md", "examples.md")) + "\n"
    #  Stated so an agent can decide what it can afford, and measured
    #  rather than guessed, because a size written by hand is one that
    #  drifts the first time a document grows.
    sizes = {"primer": measure(brief), "full": measure(full)}
    #  A program on the examples page is a section with a fixture line.
    programs = len(re.findall(r"^Fixture source: ", read(source, "examples.md"),
                              re.M))
    if not programs:
        raise SystemExit("llms: examples.md names no `Fixture source:`, so "
                         "the index cannot say how many programs it holds")
    (site / "llms.txt").write_text(
        index(pages, site_url, release, sizes, programs) + "\n",
        encoding="utf-8")
    (site / "llms-primer.txt").write_text(brief, encoding="utf-8")
    (site / "llms-full.txt").write_text(full, encoding="utf-8")
    return ("llms.txt", "llms-primer.txt", "llms-full.txt")
