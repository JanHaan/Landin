#!/usr/bin/env python3
"""Count the instructions a program's own code executes under its lane's emulator.

docs/measurement.md's `instructions` class: compiler/tests/measure/qemu/
count.c, a QEMU TCG plugin of the repository's own, counts every executed
instruction whose address lies in the image's executable range.

    measure_count.py count --target linux-rv64 --level L IMAGE [-- ARG ...]
        run IMAGE under QEMU's user emulation with the RV64 lane's QEMU_CPU
    measure_count.py count --target cortex-m0 --level L IMAGE [--tools DIR]
        run IMAGE on the level's machine, as environments/cortex-m/
        backend.py's LEVELS gives it, under -icount, until it reaches
        `_landin_firmware_returned`, or the corpus harness's `backend_done`
    measure_count.py plugin --qemu QEMU --output DIR
        build the plugin for the API version QEMU accepts
    measure_count.py check-header --header DIR --api N --cflags '...'
        compile the plugin's own declarations against a QEMU's
        <qemu-plugin.h>, which needs glib's headers

`--from SYMBOL` and `--to SYMBOL` count only from the first time SYMBOL's
instruction is about to execute, and up to (not including) the first time
the other's is.  A corpus harness image, one with `backend_done`, counts
from `main` by default, as the Cortex-M corpus's `--program` prints it;
any other counts its whole run.  RV32 and Xtensa run under Espressif's
QEMU, which is built without plugins, so they are refused here.

The plugin is compiled by the host's C compiler, `$CC` or `cc`, and needs
no QEMU or glib header: count.c declares the calls it makes, in the form
of the plugin API version the running QEMU accepts, which this asks QEMU
itself.  Standard library only; scripts/measure.py imports it.
"""
from __future__ import annotations

import argparse
import functools
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "compiler/tests/measure/qemu/count.c"
CORTEX = ROOT / "environments/cortex-m"

#  The QEMU_CPU every level of the RV64 lane runs under: the gate's
#  rv64-qemu job and the test program's own command for the lane.  It has
#  every extension of every level `refine targets` gives linux-rv64.
RV64_CPU = "max,xtheadba=true"

#  The plugin API versions count.c is written for: 2 to 6 share one form of
#  the calls it makes, and 7 passes user data to every callback.
KNOWN_API = range(2, 8)

#  The symbol a firmware image built with refine's own firmware link
#  (D923) reaches when its entry returns, and the corpus harness's own.
FIRMWARE_RETURNED = "_landin_firmware_returned"
HARNESS_DONE = "backend_done"
HARNESS_RESULT = "backend_result"

#  How long one counted run may take, emulator and all.
LIMIT = 600

EMULATED_ELSEWHERE = {
    "rv32": "rv32 runs under Espressif's QEMU, which is built without plugins"
            " (`-plugin` says `plugin interface not enabled in this build`), so"
            " docs/measurement.md times its levels on their boards",
    "xtensa": "xtensa runs under Espressif's QEMU, which is built without plugins"
              " (`-plugin` says `plugin interface not enabled in this build`), so"
              " docs/measurement.md times its levels on their boards",
}


class Failure(Exception):
    pass


def require(condition, message):
    if not condition:
        raise Failure(message)


# --- the image ---------------------------------------------------------------

class Image:
    """What counting needs of an ELF image: its machine, its executable
    range and its symbols' addresses, a Thumb routine's without its low
    bit."""

    def __init__(self, path: Path):
        data = path.read_bytes()
        require(data[:4] == b"\x7fELF", f"{path} is not an ELF image")
        wide = data[4] == 2
        order = "<" if data[5] == 1 else ">"
        self.path = path
        self.machine, = struct.unpack_from(order + "H", data, 18)
        if wide:
            phoff, shoff = struct.unpack_from(order + "QQ", data, 0x20)
            phentsize, phnum, shentsize, shnum = struct.unpack_from(
                order + "HHHH", data, 0x36)
        else:
            phoff, shoff = struct.unpack_from(order + "II", data, 0x1C)
            phentsize, phnum, shentsize, shnum = struct.unpack_from(
                order + "HHHH", data, 0x2A)
        ranges = []
        for index in range(phnum):
            at = phoff + index * phentsize
            if wide:
                kind, flags, _, vaddr, _, _, memsz = struct.unpack_from(
                    order + "IIQQQQQ", data, at)
            else:
                kind, _, vaddr, _, _, memsz, flags = struct.unpack_from(
                    order + "IIIIIII", data, at)
            if kind == 1 and flags & 1 and memsz:
                ranges.append((vaddr, vaddr + memsz))
        require(ranges, f"{path} has no executable segment")
        #  One range from the lowest executable byte to the highest: an
        #  image whose reset copies code to RAM (D1359) spans both, and
        #  nothing between them executes.
        self.executable = (min(lo for lo, _ in ranges), max(hi for _, hi in ranges))
        self.symbols: dict[str, int] = {}
        thumb = self.machine == 40  # EM_ARM
        for index in range(shnum):
            at = shoff + index * shentsize
            if wide:
                _, kind, _, _, offset, size, link, _, _, entsize = struct.unpack_from(
                    order + "IIQQQQIIQQ", data, at)
            else:
                _, kind, _, _, offset, size, link, _, _, entsize = struct.unpack_from(
                    order + "IIIIIIIIII", data, at)
            if kind != 2:  # SHT_SYMTAB
                continue
            strings_at = shoff + link * shentsize
            if wide:
                s_offset, s_size = struct.unpack_from(order + "QQ", data, strings_at + 24)
            else:
                s_offset, s_size = struct.unpack_from(order + "II", data, strings_at + 16)
            strings = data[s_offset:s_offset + s_size]
            for entry in range(size // entsize):
                base = offset + entry * entsize
                if wide:
                    name, info, _, shndx, value = struct.unpack_from(
                        order + "IBBHQ", data, base)
                else:
                    name, value, _, info, _, shndx = struct.unpack_from(
                        order + "IIIBBH", data, base)
                if not name or shndx == 0:
                    continue
                label = strings[name:strings.index(b"\0", name)].decode()
                if thumb and info & 0xF == 2:  # STT_FUNC
                    value &= ~1
                self.symbols.setdefault(label, value)

    def address(self, symbol: str) -> int:
        if symbol in self.symbols:
            return self.symbols[symbol]
        try:
            return int(symbol, 0)
        except ValueError:
            raise Failure(f"{self.path} has no symbol {symbol}") from None


# --- the plugin --------------------------------------------------------------

def compiler() -> list[str]:
    return (os.environ.get("CC") or "cc").split()


def plugin_api(qemu: list[str], env: dict | None = None) -> int:
    """The newest plugin API version QEMU accepts, as QEMU says it.

    QEMU refuses a plugin that asks for a newer version than it has,
    naming its own, so a probe asking for one no QEMU has gets the answer.
    """
    with tempfile.TemporaryDirectory(prefix="landin-count-probe-") as directory:
        source = Path(directory) / "probe.c"
        source.write_text(
            "#include <stdint.h>\n"
            '__attribute__((visibility("default"))) int qemu_plugin_version = 9999;\n'
            '__attribute__((visibility("default"))) int qemu_plugin_install('
            "uint64_t id, const void *info, int argc, char **argv) { return 0; }\n")
        probe = Path(directory) / "probe.so"
        built = subprocess.run([*compiler(), "-shared", "-fPIC", "-o", str(probe),
                                str(source)], capture_output=True, text=True)
        require(built.returncode == 0, "the host's C compiler could not build the"
                f" plugin probe:\n{built.stdout}{built.stderr}")
        said = subprocess.run([qemu[0], "-plugin", str(probe), *qemu[1:]], capture_output=True,
                              text=True, env=env, stdin=subprocess.DEVNULL, timeout=60)
    text = said.stdout + said.stderr
    found = re.search(r"supports only up to version (\d+)", text)
    if found is None:
        require("plugin interface not enabled" not in text,
                f"{qemu[0]} is built without plugins: {text.strip()}")
        raise Failure(f"{qemu[0]} did not name its plugin API version: {text.strip()}")
    return int(found.group(1))


def build_plugin(api: int, directory: Path) -> Path:
    """count.c built for plugin API version API under DIRECTORY."""
    require(api in KNOWN_API, f"the emulator's plugin API is version {api}; count.c"
            f" knows versions {KNOWN_API.start} to {KNOWN_API.stop - 1}: add the"
            " new version's form of its calls, checked with `check-header`")
    directory.mkdir(parents=True, exist_ok=True)
    plugin = directory / f"count-api{api}.so"
    built = subprocess.run(
        [*compiler(), "-O2", "-shared", "-fPIC", "-Wall", "-Wextra", "-Werror",
         "-Wno-unused-parameter", f"-DCOUNT_API={api}", "-o", str(plugin), str(SOURCE)],
        capture_output=True, text=True)
    require(built.returncode == 0, f"count.c did not build for plugin API {api}:\n"
            f"{built.stdout}{built.stderr}")
    return plugin


@functools.cache
def plugin_for(qemu: tuple[str, ...], env_items: tuple = ()) -> Path:
    """The plugin built for QEMU, once per emulator per process."""
    env = dict(env_items) if env_items else None
    api = plugin_api(list(qemu), env)
    return build_plugin(api, Path(tempfile.mkdtemp(prefix="landin-count-")))


def plugin_argument(plugin: Path, image: Image, out: Path, start=None, stop=None,
                    within=None) -> str:
    lo, hi = within or image.executable
    spec = f"{plugin},lo={lo:#x},hi={hi:#x},out={out}"
    if start is not None:
        spec += f",from={start:#x}"
    if stop is not None:
        spec += f",to={stop:#x}"
    return spec


def read_count(out: Path) -> dict:
    """The plugin's file: the count, and whether its bounds were met."""
    require(out.exists(), f"the counting plugin wrote no {out}: the emulator did not"
            " exit through its own shutdown")
    fields = dict(line.split() for line in out.read_text().splitlines() if line)
    return {"instructions": int(fields["instructions"]),
            "started": fields.get("started") != "0",
            "reached": fields.get("reached") != "0"}


# --- RV64 --------------------------------------------------------------------

def count_rv64(image: Image, level: str, arguments=(), stdin=None, start=None,
               stop=None, qemu="qemu-riscv64", work: Path | None = None) -> dict:
    """IMAGE run once under QEMU's user emulation, as the RV64 lane runs it."""
    require(image.machine == 243, f"{image.path} is not a RISC-V image")
    #  The guest's environment is QEMU's own, and the runtime's start walks
    #  it: each variable cost 128 instructions, so the run's environment is
    #  QEMU_CPU alone and a count does not depend on the shell it ran from.
    env = {"QEMU_CPU": RV64_CPU}
    found = shutil.which(qemu)
    require(found is not None, f"no {qemu} on PATH; nix develop provides the pinned one")
    qemu = found
    #  User emulation wants a program before it loads a plugin; the probe's
    #  refusal comes first, so the program never runs.
    plugin = plugin_for((qemu, sys.executable), tuple(sorted(env.items())))
    work = work or Path(tempfile.mkdtemp(prefix="landin-count-run-"))
    out = work / "count.txt"
    out.unlink(missing_ok=True)
    first = image.address(start) if start else None
    last = image.address(stop) if stop else None
    with (open(stdin, "rb") if stdin else open(os.devnull, "rb")) as given:
        done = subprocess.run(
            [qemu, "-plugin", plugin_argument(plugin, image, out, first, last),
             str(image.path), *arguments], stdin=given, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, env=env, timeout=LIMIT)
    counted = read_count(out)
    require(counted["started"], f"{image.path} never reached --from {start}")
    require(not stop or counted["reached"], f"{image.path} never reached --to {stop}")
    return {"target": "linux-rv64", "level": level, "emulator": qemu,
            "cpu": RV64_CPU, "status": done.returncode,
            "output_sha256": hashlib.sha256(done.stdout).hexdigest(),
            **counted}


# --- Cortex-M ----------------------------------------------------------------

def cortex_level(level: str) -> str:
    """LEVEL as backend.py's LEVELS names it: refine's armv7e-m runs on the
    AN500 lane, whose key names its float unit."""
    sys.path.insert(0, str(CORTEX))
    from backend import LEVELS  # noqa: E402
    if level in LEVELS:
        return level
    named = [key for key, row in LEVELS.items() if row.get("level") == level]
    require(len(named) == 1, f"no Cortex-M lane runs level {level}; the levels are"
            f" {', '.join(key for key in LEVELS if 'arch' not in LEVELS[key])}")
    return named[0]


def count_cortex(image: Image, level: str, tools: Path, start=None, stop=None,
                 words=(), work: Path | None = None) -> dict:
    """IMAGE run once on LEVEL's machine under -icount, stopped by the
    debugger at STOP, the firmware return or the harness's end by default."""
    sys.path.insert(0, str(CORTEX))
    from backend import LEVELS  # noqa: E402
    from run import gdb_listener  # noqa: E402
    lane = cortex_level(level)
    row = LEVELS[lane]
    require(row.get("arch") != "rv32", EMULATED_ELSEWHERE["rv32"])
    require(image.machine == 40, f"{image.path} is not an Arm image")
    harness = HARNESS_DONE in image.symbols
    if stop is None:
        stop = HARNESS_DONE if harness else FIRMWARE_RETURNED
    if start is None and harness:
        start = "main"
    first = image.address(start) if start else None
    last = image.address(stop)
    usr = tools / "root/usr"
    libraries = usr / "lib/x86_64-linux-gnu"
    env = {**os.environ, "LC_ALL": "C", "LANG": "C",
           "LD_LIBRARY_PATH": f"{libraries}:{libraries / 'pulseaudio'}"}
    qemu = str(usr / "bin/qemu-system-arm")
    plugin = plugin_for((qemu, "-M", "none", "-display", "none"),
                        tuple(sorted(env.items())))
    work = work or Path(tempfile.mkdtemp(prefix="landin-count-run-"))
    out = work / "count.txt"
    out.unlink(missing_ok=True)
    listener, port, stub = gdb_listener()
    cpu = ["-cpu", row["cpu"]] if "cpu" in row else []
    argv = [qemu, "-M", row["machine"], *cpu, "-accel", "tcg,thread=single",
            "-icount", "shift=0,align=off,sleep=off", "-display", "none",
            "-monitor", "none", "-serial", "none", "-kernel", str(image.path),
            "-S", *stub, "-plugin", plugin_argument(plugin, image, out, first)]
    reads = [f'print("COUNT-WORD {name} %d" % v("*(unsigned*)&{name}"))'
             for name in ([HARNESS_RESULT] if harness else []) + list(words)]
    script = work / "count.gdb"
    script.write_text("\n".join([
        "set pagination off", "set confirm off",
        f"target remote 127.0.0.1:{port}",
        f"break *{last:#x}", "continue", "python",
        "import gdb",
        "def v(s): return int(gdb.parse_and_eval(s)) & 0xffffffff",
        'print("COUNT-PC %d" % v("$pc"))', *reads, "end", "kill", "quit", ""]))
    with (work / "qemu.log").open("wb") as log:
        with listener:
            process = subprocess.Popen(argv, cwd=work, env=env, stdout=log, stderr=log,
                                       start_new_session=True,
                                       pass_fds=(listener.fileno(),))
        try:
            session = subprocess.run(
                [str(usr / "bin/gdb-multiarch"), "-q", "-nx", "-batch", "-x", str(script),
                 str(image.path)], cwd=work, env=env, capture_output=True, text=True,
                timeout=LIMIT)
            (work / "count-gdb.log").write_text(session.stdout + session.stderr)
            process.wait(timeout=30)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
    pc = re.search(r"^COUNT-PC (\d+)$", session.stdout, re.M)
    require(pc is not None and int(pc.group(1)) == last, f"{image.path} did not stop at {stop}; inspect"
            f" {work / 'count-gdb.log'}")
    seen = {name: int(value) for name, value in
            re.findall(r"^COUNT-WORD (\S+) (\d+)$", session.stdout, re.M)}
    counted = read_count(out)
    require(counted["started"], f"{image.path} never reached --from {start}")
    result = {"target": "cortex-m0", "level": level, "machine": row["machine"],
              "emulator": "qemu-system-arm", "from": start, "to": stop, **counted}
    result["reached"] = True
    if harness:
        result["status"] = seen.pop(HARNESS_RESULT)
    if seen:
        result["words"] = seen
    return result


# --- the interface -----------------------------------------------------------

def count(target: str, level: str, image: Path, arguments=(), stdin=None, start=None,
          stop=None, words=(), tools: Path | None = None, work: Path | None = None) -> dict:
    """One counted run of IMAGE at TARGET's LEVEL under its lane's emulator."""
    require(target not in EMULATED_ELSEWHERE, EMULATED_ELSEWHERE.get(target, ""))
    elf = Image(Path(image))
    if target == "linux-rv64":
        require(not words, "--word reads a firmware image's datum")
        return count_rv64(elf, level, arguments, stdin, start, stop, work=work)
    require(target == "cortex-m0", f"{target} is not counted under emulation: only"
            " linux-rv64 and cortex-m0 are (docs/measurement.md, Runners)")
    require(not arguments and not stdin, "a firmware program takes no arguments or input")
    return count_cortex(elf, level, tools, start, stop, words, work=work)


def nixos_route() -> None:
    """The Cortex-M lanes' Debian QEMU and GDB start on NixOS only inside
    the flake's FHS environment; run this again there, as the lanes do."""
    sys.path.insert(0, str(CORTEX))
    from setup import nixos_route as route  # noqa: E402
    route()


def run_count(args) -> int:
    tools = None
    if args.target == "cortex-m0":
        nixos_route()
        sys.path.insert(0, str(CORTEX))
        from setup import DEFAULT, installed_tools  # noqa: E402
        tools = installed_tools(args.tools or DEFAULT)
    results = []
    for index in range(args.repeat):
        work = Path(args.output) / f"run-{index + 1}" if args.output else None
        if work:
            work.mkdir(parents=True, exist_ok=True)
        results.append(count(args.target, args.level, args.image, args.arguments,
                             args.stdin, getattr(args, "from"), args.to, args.word,
                             tools, work))
    figures = sorted({one["instructions"] for one in results})
    for one in results:
        bounds = "".join(f" {key} {one[key]}" for key in ("from", "to") if one.get(key))
        print(f"{args.image}: {one['instructions']} instructions at {args.target}"
              f" {args.level}{bounds}"
              + (f"; status {one['status']}" if "status" in one else "")
              + "".join(f"; {name} {value:#010x}" for name, value in
                        one.get("words", {}).items()))
    if args.repeat > 1:
        print(f"{args.repeat} runs: " + ("identical" if len(figures) == 1 else
                                         f"spread {figures[0]} to {figures[-1]}"))
    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=1) + "\n")
    return 0


# --- the noise study ---------------------------------------------------------

def spread(figures: list[int]) -> dict:
    """FIGURES' least, greatest and their difference, relative too."""
    least, most = min(figures), max(figures)
    return {"runs": len(figures), "figures": figures, "min": least, "max": most,
            "spread": most - least,
            "relative": round((most - least) / least, 9) if least else None}


def hosted_noise(refine: Path, profile: tuple[str, str], runs: int, out: Path,
                 jobs: int) -> dict:
    """Every hosted workload's timing run counted RUNS times at linux-rv64's
    first level, PROFILE."""
    import concurrent.futures
    import measure  # noqa: E402
    level = measure.targets(refine)["linux-rv64"][0]
    images = out / "rv64"
    images.mkdir(parents=True, exist_ok=True)
    work = []
    for workload in measure.workloads()["hosted"]:
        image, meta, fixture = measure.hosted_build(
            refine, "linux-rv64", level, profile, workload, images, None)
        timing = workload["timing"]
        arguments = timing.get("args", meta.program_arguments(fixture))
        stdin = None
        if "stdin" in meta:
            given = (fixture / meta["stdin"]).read_bytes()
            stdin = images / (image.name + ".stdin")
            stdin.write_bytes(given * timing.get("stdin_repeat", 1))
        work += [(workload["name"], image, arguments, stdin, index)
                 for index in range(runs)]

    def one(item):
        name, image, arguments, stdin, index = item
        place = out / "runs" / f"{name}-{index + 1}"
        place.mkdir(parents=True, exist_ok=True)
        return name, count("linux-rv64", level, image, arguments, stdin, work=place)

    found: dict[str, list] = {}
    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        for name, result in pool.map(one, work):
            found.setdefault(name, []).append(result)
            print(f"rv64 {name}: {result['instructions']} (status {result['status']})",
                  flush=True)
    return {"target": "linux-rv64", "level": level, "cpu": RV64_CPU,
            "profile": "-".join(profile), "workloads": {
                name: {**spread([r["instructions"] for r in results]),
                       "statuses": sorted({r["status"] for r in results}),
                       "output_sha256": sorted({r["output_sha256"] for r in results})}
                for name, results in sorted(found.items())}}


def firmware_noise(refine: Path, tools: Path, workloads: list[dict], profile, runs: int,
                   out: Path) -> dict:
    """Every firmware workload built as the Cortex-M corpus's `--program`
    builds it, at each M-profile level, and counted RUNS times under
    -icount; the corpus's own run, without -icount, is kept beside."""
    sys.path.insert(0, str(CORTEX))
    from backend import LEVELS  # noqa: E402
    import backend_corpus  # noqa: E402
    levels = [level for level, row in LEVELS.items() if row.get("arch") != "rv32"]
    fixtures = [one["fixture"] for one in workloads]
    words = {one["fixture"]: [one["checksum"]] if "checksum" in one else []
             for one in workloads}
    programs = [ROOT / "compiler/tests/fixtures" / name / "main.ldn" for name in fixtures]
    observed = backend_corpus.observe(out / "corpus", tools, refine, programs, [profile],
                                      levels)
    machines: dict[str, dict] = {}
    for result, (name, elf) in zip(
            observed, ((name, out / "corpus" / (backend_corpus.program_names(programs)[i]
                                                + "--" + "-".join(profile)
                                                + ("" if level == "armv6-m"
                                                   else "--" + level)) / "program.elf")
                       for i, name in enumerate(fixtures) for level in levels)):
        level = result["level"]
        figures, statuses, checksums = [], set(), set()
        for index in range(runs):
            place = out / "runs" / f"{name.replace('/', '-')}-{level}-{index + 1}"
            place.mkdir(parents=True, exist_ok=True)
            counted = count("cortex-m0", level, elf, words=words[name], tools=tools,
                            work=place)
            figures.append(counted["instructions"])
            statuses.add(counted["status"])
            checksums.update(f"{value:#010x}" for value in counted.get("words", {}).values())
        row = machines.setdefault(LEVELS[level]["machine"], {"level": level,
                                                             "workloads": {}})
        row["workloads"][name] = {**spread(figures), "statuses": sorted(statuses),
                                  **({"checksum": sorted(checksums)} if checksums else {}),
                                  "corpus_run_without_icount": result.get("instructions")}
        print(f"{LEVELS[level]['machine']} {name}: {figures}"
              f" (corpus {result.get('instructions')})", flush=True)
    return {"target": "cortex-m0", "profile": "-".join(profile),
            "icount": "shift=0,align=off,sleep=off", "machines": machines}


def run_noise(args) -> int:
    out = Path(args.output)
    out.mkdir(parents=True, exist_ok=True)
    profile = tuple(args.profile.split("-"))
    refine = args.refine.resolve(strict=True)
    sys.path.insert(0, str(ROOT / "scripts"))
    study = {"schema": 1, "class": "instructions", "runs": args.runs,
             "compiler_sha256": hashlib.sha256(refine.read_bytes()).hexdigest(),
             "plugin_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest()}
    if args.part in ("all", "firmware"):
        nixos_route()
        sys.path.insert(0, str(CORTEX))
        from setup import DEFAULT, installed_tools  # noqa: E402
        tools = installed_tools(args.tools or DEFAULT)
        import measure  # noqa: E402
        workloads = measure.workloads().get("firmware", [])
        require(workloads, "compiler/tests/measure/workloads.json names no firmware workload")
        study["firmware"] = firmware_noise(refine, tools, workloads, profile, args.runs, out)
    if args.part in ("all", "hosted"):
        study["hosted"] = hosted_noise(refine, profile, args.runs, out, args.jobs)
    (out / "instructions.json").write_text(json.dumps(study, indent=1) + "\n")
    print(out / "instructions.json")
    return 0


def run_plugin(args) -> int:
    api = plugin_api(args.qemu.split())
    print(build_plugin(api, Path(args.output)))
    return 0


def run_check_header(args) -> int:
    """Compile count.c's own declarations against a real <qemu-plugin.h>."""
    done = subprocess.run(
        [*compiler(), "-fsyntax-only", "-Wall", "-Wextra", "-Werror",
         "-Wno-unused-parameter", f"-DCOUNT_API={args.api}", "-DCOUNT_CHECK_HEADER",
         f"-I{args.header}", *args.cflags.split(), str(SOURCE)],
        capture_output=True, text=True)
    require(done.returncode == 0, f"count.c's declarations disagree with"
            f" {args.header}/qemu-plugin.h at API {args.api}:\n{done.stderr}")
    print(f"count.c agrees with {args.header}/qemu-plugin.h at API {args.api}")
    return 0


def add_commands(commands) -> None:
    """Add `count`, `plugin` and `check-header` to COMMANDS, an argparse
    subparsers object, so scripts/measure.py offers them as its own; each
    sets `run`, which takes the parsed arguments and may raise Failure."""
    one = commands.add_parser("count", help="count one image's instructions",
                              description=__doc__.split("\n\n")[0],
                              formatter_class=argparse.RawDescriptionHelpFormatter,
                              epilog=__doc__.split("\n\n", 1)[1])
    one.add_argument("--target", required=True, help="linux-rv64 or cortex-m0")
    one.add_argument("--level", required=True,
                     help="the image's level, as refine or the Cortex-M lanes name it")
    one.add_argument("image", type=Path)
    one.add_argument("arguments", nargs="*", help="RV64: the program's arguments")
    one.add_argument("--stdin", type=Path, help="RV64: the program's standard input")
    one.add_argument("--from", metavar="SYMBOL",
                     help="count from SYMBOL's first execution")
    one.add_argument("--to", metavar="SYMBOL",
                     help="count up to SYMBOL's first execution")
    one.add_argument("--word", action="append", default=[], metavar="SYMBOL",
                     help="Cortex-M: print the 32-bit word at SYMBOL after the run")
    one.add_argument("--tools", type=Path,
                     help="Cortex-M: the lanes' tool root (environments/cortex-m/setup.py)")
    one.add_argument("--repeat", type=int, default=1, help="count the same image N times")
    one.add_argument("--output", help="keep each run's files under this directory")
    one.add_argument("--json", help="write every run's result here")
    one.set_defaults(run=run_count)
    noise = commands.add_parser("noise", help="count every workload repeatedly")
    noise.add_argument("--refine", type=Path, required=True)
    noise.add_argument("--output", required=True)
    noise.add_argument("--runs", type=int, default=5)
    noise.add_argument("--profile", default="speed-auto", help="OPTIMIZE-SPECIALIZE")
    noise.add_argument("--part", choices=("all", "hosted", "firmware"), default="all")
    noise.add_argument("--tools", type=Path)
    noise.add_argument("--jobs", type=int, default=os.cpu_count() or 1)
    noise.set_defaults(run=run_noise)
    build = commands.add_parser("plugin", help="build the plugin for an emulator")
    build.add_argument("--qemu", required=True,
                       help="the emulator and any arguments it needs to start")
    build.add_argument("--output", required=True)
    build.set_defaults(run=run_plugin)
    check = commands.add_parser("check-header",
                                help="hold count.c to a QEMU's <qemu-plugin.h>")
    check.add_argument("--header", required=True, type=Path,
                       help="the directory holding qemu-plugin.h")
    check.add_argument("--api", required=True, type=int)
    check.add_argument("--cflags", default="", help="glib's include flags")
    check.set_defaults(run=run_check_header)


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(
        prog="measure_count.py", description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("\n\n", 1)[1])
    add_commands(top.add_subparsers(dest="command", required=True))
    return top


def main(argv=None) -> int:
    args = parser().parse_args(argv)
    try:
        return args.run(args)
    except Failure as error:
        print(f"measure_count.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
