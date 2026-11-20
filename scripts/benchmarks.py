#!/usr/bin/env python3
"""Time the Benchmark Game ports against C, and one refine against another.

docs/benchmarks.md describes the method this carries out;
compiler/tests/measure/benchmarks.json names each port, the size it is
timed at and the C program it is compared with.  Each compiler given with
--refine builds every port at `--optimize speed` with its own library, the
C compiler builds the Benchmark Game's C programs, and every image is then
run interleaved with the others, a fresh copy each time, pinned to one core.

    benchmarks.py --refine 0.2.10=PATH --refine candidate=PATH --output DIR
    benchmarks.py --refine candidate=PATH --size timing --runs 5 --output DIR
    benchmarks.py --refine candidate=PATH --no-c --only fasta --output DIR

`--size performance` (the default) runs the Benchmark Game's performance
sizes, which take minutes each; `--size timing` runs the smaller timing
arguments of compiler/tests/measure/workloads.json, its fibre and thread
workloads included, which have no C counterpart.

It writes DIR/results.json and DIR/report.md: each image's median wall
time, its multiple of C's, the geometric mean of those multiples, peak
resident memory, the image's allocated bytes and `.text`, and each
compile's median wall time over --compile-runs compiles after one more
that warms the caches.  Every output must be the reference's, byte for
byte: C's, or without C the first --refine's.

The C sources are not in this tree.  The Benchmark Game serves them in one
archive that changes when its programs do, so the archive is not pinned and
each member is: a member missing from it or whose SHA-256 differs is
refused, and --c-archive takes a copy kept from an earlier download.  The
cache is $LANDIN_INPUTS/benchmarks, or ~/.cache/landin/inputs/benchmarks.

Run it inside the pinned environment, whose assembler and linker refine
uses; the C compiler is --cc, `cc` by default, and the nix wrappers drop
-march=native unless NIX_ENFORCE_NO_NATIVE=0, which this sets for it.

Standard library only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent
MEASURE = ROOT / "compiler/tests/measure"
FIXTURES = ROOT / "compiler/tests/fixtures"
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "compiler/tests"))
import fixture_meta  # noqa: E402
from measure import elf_sections, median  # noqa: E402

RUN_LIMIT = 900
# GNU time's %M, the program's own peak: a peak read from the waiting
# process would count the Python interpreter the child was forked from.
TIME = next((path for path in ("/usr/bin/time", "/run/current-system/sw/bin/time")
             if os.access(path, os.X_OK)), None)


class Failure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


# --- what is measured --------------------------------------------------------

def programs(size: str, only: list[str]) -> list[dict]:
    """The programs to build and run, each with its arguments and, where
    it has one, its C program."""
    table = json.loads((MEASURE / "benchmarks.json").read_text())
    known = {entry["name"]: entry for entry in table["programs"]}
    if size == "performance":
        chosen = [dict(entry) for entry in table["programs"]]
    else:
        chosen = []
        for workload in json.loads((MEASURE / "workloads.json").read_text())["hosted"]:
            entry = {"name": workload["name"], "fixture": workload["fixture"],
                     "args": workload["timing"].get("args", [])}
            if "stdin_repeat" in workload["timing"]:
                entry["stdin_repeat"] = workload["timing"]["stdin_repeat"]
            if workload["name"] in known:
                entry["c"] = known[workload["name"]]["c"]
            chosen.append(entry)
    if only:
        missing = sorted(set(only) - {entry["name"] for entry in chosen})
        require(not missing, f"no program named {', '.join(missing)} at size {size}")
        chosen = [entry for entry in chosen if entry["name"] in only]
    return chosen


def c_flags() -> list[str]:
    return json.loads((MEASURE / "benchmarks.json").read_text())["c_flags"]


def cache_dir() -> Path:
    base = os.environ.get("LANDIN_INPUTS")
    root = Path(base) if base else Path.home() / ".cache/landin/inputs"
    return root / "benchmarks"


def c_sources(chosen: list[dict], archive: Path | None) -> dict[str, Path]:
    """Each chosen program's C source, verified, from the cache, the given
    archive or a fresh download of the Benchmark Game's."""
    table = json.loads((MEASURE / "benchmarks.json").read_text())
    cache = cache_dir()
    cache.mkdir(parents=True, exist_ok=True)
    wanted = {entry["name"]: entry["c"] for entry in chosen if "c" in entry}
    found: dict[str, Path] = {}
    for name, c in wanted.items():
        path = cache / (Path(c["member"]).name + ".c")
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == c["sha256"]:
            found[name] = path
    if len(found) == len(wanted):
        return found
    if archive is None:
        archive = cache / "benchmarksgame-sourcecode.zip"
        url = table["c_source"]["url"]
        print(f"fetching {url}", file=sys.stderr)
        with urllib.request.urlopen(url, timeout=120) as response:
            archive.write_bytes(response.read())
    with zipfile.ZipFile(archive) as bundle:
        names = set(bundle.namelist())
        for name, c in wanted.items():
            if name in found:
                continue
            require(c["member"] in names,
                    f"{archive} has no {c['member']}: the Benchmark Game has changed"
                    f" its programs; give a kept copy with --c-archive, or pin the"
                    f" new program in compiler/tests/measure/benchmarks.json")
            data = bundle.read(c["member"])
            digest = hashlib.sha256(data).hexdigest()
            require(digest == c["sha256"],
                    f"{c['member']} has SHA-256 {digest}, not the pinned {c['sha256']}:"
                    f" the program changed; give a kept copy with --c-archive")
            path = cache / (Path(c["member"]).name + ".c")
            path.write_bytes(data)
            found[name] = path
    return found


# --- building ----------------------------------------------------------------

def timed(command: list[str], **kwargs) -> tuple[float, subprocess.CompletedProcess]:
    start = time.perf_counter()
    done = subprocess.run(command, capture_output=True, text=True, **kwargs)
    return time.perf_counter() - start, done


def compile_landin(refine: str, library: str | None, entry: dict, image: Path) -> list[str]:
    fixture = FIXTURES / entry["fixture"]
    meta = fixture_meta.read(fixture)
    return [refine, "compile", "--optimize=speed",
            *([f"--library={library}"] if library else []),
            *meta.source_arguments(fixture), "-o", str(image)]


def compile_c(cc: str, source: Path, c: dict, image: Path) -> list[str]:
    return [cc, *c_flags(), str(source), "-o", str(image), *c.get("libs", [])]


def build(label: str, command_for, scratch: Path, final: Path, runs: int, env) -> list[float]:
    """Build once into FINAL, then time RUNS more compiles, each into a
    fresh directory, after one that warms the caches."""
    final.parent.mkdir(parents=True, exist_ok=True)
    seconds, done = timed(command_for(final), env=env, cwd=ROOT / "compiler/ada")
    require(done.returncode == 0, f"{label}: {' '.join(command_for(final))}\n"
                                  f"{done.stdout}{done.stderr}")
    times = []
    for _ in range(runs):
        place = Path(tempfile.mkdtemp(dir=scratch)) / final.name
        seconds, done = timed(command_for(place), env=env, cwd=place.parent)
        require(done.returncode == 0, f"{label} failed on a repeat:\n{done.stderr}")
        times.append(seconds)
        shutil.rmtree(place.parent)
    return times


def image_size(path: Path) -> dict:
    sections = elf_sections(path.read_bytes())
    return {"allocated": sum(sections.values()), "text": sections.get(".text", 0)}


# --- running -----------------------------------------------------------------

def run_once(image: Path, args: list[str], stdin: Path | None, core: int | None,
             scratch: Path) -> dict:
    """One run of a fresh copy of IMAGE: wall seconds, peak resident
    kilobytes, status and the output's digest."""
    fresh = Path(tempfile.mkdtemp(dir=scratch)) / image.name
    shutil.copy2(image, fresh)
    measured = scratch / "rss"
    command = ([*([TIME, "-f", "%M", "-o", str(measured)] if TIME else []),
                *(["taskset", "-c", str(core)] if core is not None else []),
                str(fresh), *args])
    digest = hashlib.sha256()
    with (open(stdin, "rb") if stdin else open(os.devnull, "rb")) as given:
        start = time.perf_counter()
        process = subprocess.Popen(command, stdin=given, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL,
                                   env={**os.environ, "LC_ALL": "C"})
        deadline = start + RUN_LIMIT
        while True:
            chunk = process.stdout.read(1 << 20)
            if not chunk:
                break
            digest.update(chunk)
            if time.perf_counter() > deadline:
                process.kill()
                break
        status = process.wait()
        seconds = time.perf_counter() - start
    shutil.rmtree(fresh.parent)
    rss = None
    if TIME and measured.exists():
        rss = int(measured.read_text().split()[-1])
        measured.unlink()
    return {"seconds": seconds, "max_rss_kb": rss,
            "status": status,
            "digest": digest.hexdigest(),
            "timed_out": seconds > RUN_LIMIT}


def identity(command: list[str]) -> str:
    try:
        done = subprocess.run(command, capture_output=True, text=True, timeout=60)
        return (done.stdout or done.stderr).splitlines()[0].strip()
    except (OSError, IndexError, subprocess.TimeoutExpired):
        return "unknown"


def host() -> dict:
    model = "unknown"
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                model = line.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    return {"cpu": model, "system": f"{platform.system()} {platform.release()}",
            "cores": os.cpu_count()}


def geometric_mean(values: list[float]) -> float | None:
    return math.exp(sum(math.log(v) for v in values) / len(values)) if values else None


# --- the report --------------------------------------------------------------

def report(results: dict) -> str:
    labels = results["implementations"]
    names = [entry["name"] for entry in results["programs"]]
    has_c = "C" in labels
    lines = [f"# Benchmarks, {results['size']} size", "",
             f"Host: {results['host']['cpu']}, {results['host']['system']};"
             f" core {results['core']}; median of {results['runs']} runs;"
             f" load average {results['load_before'][0]:.2f} before and"
             f" {results['load_after'][0]:.2f} after.", ""]
    for label in labels:
        lines.append(f"- {label}: {results['versions'][label]}")
    lines += ["", "## Time", "",
              "Seconds" + (", and in brackets the multiple of C's time." if has_c else "."), "",
              "| | " + " | ".join(names) + (" | geometric mean |" if has_c else " |"),
              "|---|" + "---|" * (len(names) + (1 if has_c else 0))]
    for label in labels:
        cells, ratios = [], []
        for name in names:
            cell = results["time"].get(label, {}).get(name)
            if cell is None:
                cells.append("—")
                continue
            c = results["time"].get("C", {}).get(name)
            if has_c and c and label != "C":
                ratio = cell / c
                ratios.append(ratio)
                cells.append(f"{cell:.3g} ({ratio:.2f})")
            else:
                cells.append(f"{cell:.3g}")
        mean = geometric_mean(ratios)
        tail = (f" {mean:.2f} |" if mean else " |") if has_c else ""
        lines.append(f"| {label} | " + " | ".join(cells) + " |" + tail)
    for title, field, unit in (("Peak resident memory", "max_rss_kb", "megabytes"),
                               ("The image's allocated sections", "allocated", "bytes"),
                               ("The image's `.text`", "text", "bytes"),
                               ("Compile time", "compile", "seconds")):
        lines += ["", f"## {title}", "", f"In {unit}.", "",
                  "| | " + " | ".join(names) + " |", "|---|" + "---|" * len(names)]
        for label in labels:
            cells = []
            for name in names:
                value = results[field].get(label, {}).get(name)
                if value is None:
                    cells.append("—")
                elif field == "max_rss_kb":
                    cells.append(f"{value / 1024:.1f}")
                elif field == "compile":
                    cells.append(f"{value:.2f}")
                else:
                    cells.append(f"{value:,}")
            lines.append(f"| {label} | " + " | ".join(cells) + " |")
    return "\n".join(line for line in lines) + "\n"


# --- main ----------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="See the module's own text for the method.")
    parser.add_argument("--refine", action="append", default=[], metavar="LABEL=PATH",
                        help="a compiler to measure, under LABEL; repeatable")
    parser.add_argument("--library", action="append", default=[], metavar="LABEL=DIR",
                        help="the library LABEL's compiler uses, when not its own")
    parser.add_argument("--cc", default="cc", help="the C compiler (default cc)")
    parser.add_argument("--no-c", action="store_true", help="measure no C")
    parser.add_argument("--c-archive", type=Path,
                        help="a kept copy of the Benchmark Game's source archive")
    parser.add_argument("--size", choices=("performance", "timing"), default="performance")
    parser.add_argument("--only", action="append", default=[], metavar="NAME")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--compile-runs", type=int, default=5)
    parser.add_argument("--core", type=int, default=None,
                        help="the core every run is pinned to (default: unpinned)")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        require(args.refine, "give at least one --refine LABEL=PATH")
        compilers = dict(item.split("=", 1) for item in args.refine)
        libraries = dict(item.split("=", 1) for item in args.library)
        require(len(compilers) == len(args.refine), "each --refine needs its own LABEL")
        require("C" not in compilers, "C is the label of the C programs")
        chosen = programs(args.size, args.only)
        sources = {} if args.no_c else c_sources(chosen, args.c_archive)
        args.output.mkdir(parents=True, exist_ok=True)
        scratch = Path(tempfile.mkdtemp(prefix="benchmarks-", dir=args.output))
        labels = list(compilers) + ([] if args.no_c else ["C"])
        versions = {label: identity([path, "--version"]) for label, path in compilers.items()}
        if not args.no_c:
            versions["C"] = identity([args.cc, "--version"]) + " " + " ".join(c_flags())
        c_env = {**os.environ, "NIX_ENFORCE_NO_NATIVE": "0"}
        images: dict[str, dict[str, Path]] = {label: {} for label in labels}
        results = {"size": args.size, "runs": args.runs, "core": args.core,
                   "host": host(), "versions": versions, "implementations": labels,
                   "programs": chosen, "load_before": list(os.getloadavg()),
                   "time": {}, "max_rss_kb": {}, "allocated": {}, "text": {},
                   "compile": {}, "compile_runs": {}, "runs_seen": {}}
        for entry in chosen:
            name = entry["name"]
            for label in labels:
                if label == "C":
                    if name not in sources:
                        continue
                    command_for = (lambda image, s=sources[name], c=entry["c"]:
                                   compile_c(args.cc, s, c, image))
                    env = c_env
                else:
                    command_for = (lambda image, r=compilers[label], lib=libraries.get(label):
                                   compile_landin(r, lib, entry, image))
                    env = os.environ
                final = args.output / "images" / label / name
                print(f"building {label} {name}", file=sys.stderr)
                times = build(f"{label} {name}", command_for, scratch, final,
                              args.compile_runs, env)
                images[label][name] = final
                results["compile"].setdefault(label, {})[name] = median(times) if times else None
                results["compile_runs"].setdefault(label, {})[name] = times
                size = image_size(final)
                results["allocated"].setdefault(label, {})[name] = size["allocated"]
                results["text"].setdefault(label, {})[name] = size["text"]
        inputs: dict[str, Path] = {}
        for entry in chosen:
            if "stdin_from" in entry:
                source = entry["stdin_from"]
                maker = next(label for label in (["C"] + labels)
                             if source["program"] in images.get(label, {}))
                made = args.output / f"{entry['name']}.stdin"
                with open(made, "wb") as out:
                    done = subprocess.run([str(images[maker][source["program"]]),
                                           *source["args"]], stdout=out)
                require(done.returncode == 0, f"making {made.name} failed")
                inputs[entry["name"]] = made
            elif "stdin_repeat" in entry:
                fixture = FIXTURES / entry["fixture"]
                meta = fixture_meta.read(fixture)
                made = args.output / f"{entry['name']}.stdin"
                made.write_bytes((fixture / meta["stdin"]).read_bytes() * entry["stdin_repeat"])
                inputs[entry["name"]] = made
        seen: dict[str, dict[str, list[dict]]] = {}
        for round_number in range(args.runs):
            for entry in chosen:
                name = entry["name"]
                present = [label for label in labels if name in images[label]]
                shift = round_number % len(present)
                for label in present[shift:] + present[:shift]:
                    print(f"run {round_number + 1}/{args.runs} {label} {name}", file=sys.stderr)
                    run = run_once(images[label][name], entry["args"], inputs.get(name),
                                   args.core, scratch)
                    run["load"] = os.getloadavg()[0]
                    require(not run["timed_out"], f"{label} {name} took over {RUN_LIMIT} s")
                    require(run["status"] == 0, f"{label} {name} returned {run['status']}")
                    seen.setdefault(label, {}).setdefault(name, []).append(run)
        for entry in chosen:
            name = entry["name"]
            present = [label for label in labels if name in images[label]]
            reference = "C" if "C" in present else present[0]
            expected = seen[reference][name][0]["digest"]
            for label in present:
                runs = seen[label][name]
                require(all(run["digest"] == expected for run in runs),
                        f"{label} {name}'s output differs from {reference}'s")
                results["time"].setdefault(label, {})[name] = median([r["seconds"] for r in runs])
                peaks = [r["max_rss_kb"] for r in runs if r["max_rss_kb"] is not None]
                results["max_rss_kb"].setdefault(label, {})[name] = max(peaks) if peaks else None
                results["runs_seen"].setdefault(label, {})[name] = runs
        results["load_after"] = list(os.getloadavg())
        shutil.rmtree(scratch)
        (args.output / "results.json").write_text(json.dumps(results, indent=1, default=str) + "\n")
        text = report(results)
        (args.output / "report.md").write_text(text)
        print(text)
        return 0
    except Failure as failure:
        print(f"benchmarks.py: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
