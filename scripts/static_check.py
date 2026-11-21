#!/usr/bin/env python3
"""Run a packaged static Linux compiler where no glibc is.

    scripts/static_check.py --archive ARCHIVE --alpine ROOTFS --work DIR

ARCHIVE is what `scripts/package.sh` made for this host from a Linux
release build, whose executables have glibc linked into them
(compiler/ada/landin_common.gpr).  ROOTFS is an unpacked Alpine
minirootfs, as `landin_fetch_alpine` in environments/pins.sh unpacks the
pinned one: a musl system, with no glibc and no glibc loader.  DIR is a
scratch directory outside the checkout, emptied first.

The checks, each run under bubblewrap with PATH and HOME alone:

- the archive: `bin/refine` and every split command request no program
  interpreter and name no shared library, and the archive carries
  LICENSE-GLIBC and NOTICE-GLIBC;
- an empty root holding the archive and nothing else, no C library, no
  shell and no linker: `refine version`, `refine check` and
  `refine compile --emit=asm` of the first program, and every split
  command's `--help`;
- Alpine with only `gcc` and `musl-dev` added: `install.sh`, pointed at
  ARCHIVE served from 127.0.0.1 as a release serves it, installs it and
  its `refine run` runs the first program; then every runtime fixture
  that says `link: libc` and names `linux-x86-64` or `linux-arm64` among
  its targets is compiled with `--link=libc` by the installed `refine`,
  linked against musl by Alpine's gcc and run, and must exit with its
  status and print its expected output.

Alpine's packages are fetched with `apk add`, so the check needs the
network.  A host whose kernel refuses unprivileged user namespaces, as
Ubuntu 24.04's AppArmor does by default, must allow them first
(`sysctl kernel.apparmor_restrict_unprivileged_userns=0`); the gate's
job does.
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import install_check  # noqa: E402
import program_interpreter  # noqa: E402

FIRST_PROGRAM = ROOT / "compiler/tests/fixtures/runtime/first-program"
RUNTIME = ROOT / "compiler/tests/fixtures/runtime"
HOST_TARGETS = {"x86_64": "linux-x86-64", "aarch64": "linux-arm64"}
PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


def fixture_meta(path):
    meta = {}
    for line in path.read_text().splitlines():
        key, sep, value = line.partition(":")
        if sep:
            meta[key.strip()] = value.strip()
    return meta


def libc_fixtures(target):
    """The runtime fixtures that link with the C library on TARGET."""
    found = []
    for meta_path in sorted(RUNTIME.glob("*/fixture.meta")):
        meta = fixture_meta(meta_path)
        targets = [one.strip() for one in meta.get("targets", "").split(",")]
        if meta.get("link") == "libc" and target in targets:
            found.append((meta_path.parent, meta))
    return found


def needed_libraries(data):
    """The DT_NEEDED count of an ELF executable's bytes: zero when it has
    no dynamic section or names no library."""
    import struct
    wide = data[4] == 2
    order = "<" if data[5] == 1 else ">"
    if wide:
        phoff, = struct.unpack_from(order + "Q", data, 32)
        phentsize, phnum = struct.unpack_from(order + "HH", data, 54)
    else:
        phoff, = struct.unpack_from(order + "I", data, 28)
        phentsize, phnum = struct.unpack_from(order + "HH", data, 42)
    count = 0
    for index in range(phnum):
        at = phoff + index * phentsize
        kind, = struct.unpack_from(order + "I", data, at)
        if kind != 2:  # PT_DYNAMIC
            continue
        if wide:
            offset, = struct.unpack_from(order + "Q", data, at + 8)
            size, = struct.unpack_from(order + "Q", data, at + 32)
            step, form = 16, order + "qQ"
        else:
            offset, = struct.unpack_from(order + "I", data, at + 4)
            size, = struct.unpack_from(order + "I", data, at + 16)
            step, form = 8, order + "iI"
        for entry in range(offset, offset + size, step):
            tag, _ = struct.unpack_from(form, data, entry)
            if tag == 0:
                break
            if tag == 1:  # DT_NEEDED
                count += 1
    return count


class Checks:
    def __init__(self, work):
        self.work = work
        self.failures = []
        self.passed = 0

    def ok(self, what):
        self.passed += 1
        print("ok   %s" % what)

    def fail(self, what, detail):
        self.failures.append("%s: %s" % (what, detail))
        print("FAIL %s" % what)

    def expect(self, what, ran, status=0, output=None):
        if ran.returncode != status or (output is not None
                                        and ran.stdout != output):
            self.fail(what, "exited %d (expected %d)\n%s%s" % (
                ran.returncode, status,
                ran.stdout.decode("utf-8", "replace"),
                ran.stderr.decode("utf-8", "replace")))
            return False
        self.ok(what)
        return True


def bwrap(root_args, command, cwd="/", env=None, timeout=600, stdin=b""):
    """COMMAND under bubblewrap in the root ROOT_ARGS lays out, with PATH
    and HOME alone, or ENV."""
    env = env or {"PATH": PATH, "HOME": "/root"}
    argv = ["bwrap", "--unshare-user", "--uid", "0", "--gid", "0",
            "--unshare-pid", "--die-with-parent", "--clearenv"]
    argv += root_args
    argv += ["--dev", "/dev", "--proc", "/proc", "--chdir", cwd]
    for key, value in env.items():
        argv += ["--setenv", key, value]
    return subprocess.run(argv + ["--"] + command, capture_output=True,
                          input=stdin, timeout=timeout)


def check_archive(checks, archive, prefix):
    what = "the archive's executables request no loader and no library"
    executables = [prefix / "bin/refine"] + sorted(
        (prefix / "libexec/landin").glob("refine-*"))
    dynamic = []
    for path in executables:
        data = path.read_bytes()
        if (program_interpreter.interpreter(data) is not None
                or needed_libraries(data)):
            dynamic.append(str(path.relative_to(prefix)))
    if dynamic:
        checks.fail(what, "linked dynamically: " + ", ".join(dynamic))
    else:
        checks.ok(what)
    what = "the archive carries glibc's licence and notice"
    missing = [name for name in ("LICENSE-GLIBC", "NOTICE-GLIBC")
               if not (prefix / name).is_file()]
    if missing:
        checks.fail(what, "%s holds no %s" % (archive, ", ".join(missing)))
    else:
        checks.ok(what)


def check_empty_root(checks, prefix, splits):
    """The archive alone in an empty root: no C library, no shell."""
    project = checks.work / "empty-project"
    project.mkdir()
    shutil.copy(FIRST_PROGRAM / "main.ldn", project / "main.ldn")
    root = ["--tmpfs", "/", "--ro-bind", str(prefix), "/opt/landin",
            "--bind", str(project), "/work", "--tmpfs", "/tmp"]
    env = {"PATH": "/opt/landin/bin", "HOME": "/tmp"}
    where = " in an empty root"

    def run(*argv):
        return bwrap(root, list(argv), cwd="/work", env=env)

    ran = run("refine", "version")
    if checks.expect("refine version" + where, ran):
        if not ran.stdout.startswith(b"refine "):
            checks.fail("refine version" + where,
                        "printed %r" % ran.stdout[:80])
    checks.expect("refine check main.ldn" + where,
                  run("refine", "check", "main.ldn"))
    ran = run("refine", "compile", "--emit=asm", "-o", "/work/main.s",
              "main.ldn")
    if (checks.expect("refine compile --emit=asm main.ldn" + where, ran)
            and b"main" not in (project / "main.s").read_bytes()):
        checks.fail("refine compile --emit=asm main.ldn" + where,
                    "main.s names no main")
    for name in splits:
        checks.expect("refine %s --help%s" % (name, where),
                      run("refine", name, "--help"))


def check_alpine(checks, archive, alpine, target):
    """Alpine with gcc and musl-dev: install.sh, the first program and the
    C library's fixtures."""
    root = ["--bind", str(alpine), "/", "--ro-bind", "/etc/resolv.conf",
            "/etc/resolv.conf", "--tmpfs", "/tmp",
            "--ro-bind", str(ROOT / "install.sh"), "/opt/install.sh"]
    ran = bwrap(root, ["apk", "add", "--no-progress", "-q", "gcc",
                       "musl-dev", "curl"])
    if not checks.expect("apk add gcc musl-dev curl on Alpine", ran):
        return
    musl = [path for path in (alpine / "lib").glob("ld-musl-*")]
    if not musl or any((alpine / "lib64").glob("ld-linux*")):
        checks.fail("Alpine is a musl system", "its /lib holds %s" %
                    sorted(p.name for p in (alpine / "lib").iterdir()))
        return

    served = checks.work / "served"
    version = install_check.SERVED
    install_check.publish(served, version,
                          install_check.host_platform(),
                          pathlib.Path(archive).read_bytes())
    server = install_check.serve(served, version)
    releases = "http://127.0.0.1:%d/releases" % server.server_address[1]
    try:
        ran = bwrap(root, ["sh", "/opt/install.sh"], env={
            "PATH": PATH, "HOME": "/root", "LANDIN_RELEASES": releases})
    finally:
        server.shutdown()
        server.server_close()
    if not checks.expect("install.sh installs the archive on Alpine", ran):
        return
    if b"installed refine " + version.encode() not in ran.stdout:
        checks.fail("install.sh installs the archive on Alpine",
                    "it did not say it installed refine %s" % version)
        return

    project = alpine / "root/first"
    project.mkdir(parents=True, exist_ok=True)
    shutil.copy(FIRST_PROGRAM / "main.ldn", project / "main.ldn")
    path = "/root/.landin/bin:" + PATH
    env = {"PATH": path, "HOME": "/root"}
    checks.expect("refine run of the first program on Alpine",
                  bwrap(root, ["refine", "run", "main.ldn"],
                        cwd="/root/first", env=env),
                  output=(FIRST_PROGRAM / "output.txt").read_bytes())

    fixtures = libc_fixtures(target)
    if not fixtures:
        checks.fail("the --link=libc fixtures", "none names " + target)
    for directory, meta in fixtures:
        run_fixture(checks, alpine, root, env, directory, meta)


def listed(meta, key):
    return [one.strip() for one in meta.get(key, "").split(",")
            if one.strip()]


def run_fixture(checks, alpine, root, env, directory, meta):
    """Compile DIRECTORY's program with the installed refine and
    `--link=libc`, link it against musl and run it, as the harness does a
    runtime fixture (compiler/tests/README.md): its import root, C
    archives, shared objects, arguments, files, standard input, status or
    trap, and expected output.  One profile, the default."""
    name = directory.name
    what = "%s, linked with --link=libc against musl" % name
    copy = alpine / "root/fixtures" / name
    shutil.rmtree(copy, ignore_errors=True)
    shutil.copytree(directory, copy)
    work = "/root/fixtures/" + name
    program = work + "/" + name
    bound = root + ["--ro-bind", str(ROOT), "/src"]

    def run(argv, cwd=work, stdin=None):
        return bwrap(bound, argv, cwd=cwd, env=env, stdin=stdin)

    #  The C archives the program's linker.directory finds, each alone
    #  as lib<stem>.a beside its source in the work copy.
    for source in listed(meta, "c-archives"):
        stem = pathlib.PurePosixPath(source)
        objects = "%s/%s.o" % (work, stem.with_suffix(""))
        archive = "%s/%s/lib%s.a" % (work, stem.parent, stem.stem)
        for argv in (["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                      "-fPIC", "-O2", "-c", work + "/" + source, "-o",
                      objects], ["ar", "rcs", archive, objects]):
            ran = run(argv)
            if ran.returncode != 0:
                checks.expect(what + ": C archive " + source, ran)
                return
    #  The shared objects it loads, named for the executable, whose paths
    #  are its first arguments.
    shared = []
    for source in listed(meta, "c-shared"):
        built = "%s-%s.so" % (program, pathlib.PurePosixPath(source).stem)
        ran = run(["gcc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-fPIC",
                   "-O2", "-shared", work + "/" + source, "-o", built])
        if ran.returncode != 0:
            checks.expect(what + ": shared object " + source, ran)
            return
        shared.append(built)

    compile_argv = ["refine", "compile", "--link=libc"]
    for library in listed(meta, "library-directories"):
        compile_argv += ["-L", work + "/" + library]
    compile_argv += ["-o", program]
    if "root" in meta:
        #  A rooted program is compiled where it is, in the checkout bound
        #  read-only, its module root named; the archive's own library is
        #  the one it compiles against.
        rooted = (directory / meta["root"]).resolve().relative_to(ROOT)
        source = directory.relative_to(ROOT)
        ran = run(compile_argv + ["--root=" + str("/src" / rooted),
                                  meta["program"]],
                  cwd=str("/src" / source))
    else:
        ran = run(compile_argv + [meta["program"]])
    if ran.returncode != 0:
        checks.expect(what + ": compiled", ran)
        return

    argv = ([program] + shared + meta.get("run_args", "").split()
            + [work + "/" + one for one in listed(meta, "run_files")])
    stdin = (directory / meta["stdin"]).read_bytes() if "stdin" in meta \
        else b""
    #  The harness runs a program from compiler/ada, where build/ is, and
    #  a program may write its output under it, as r480-hosted-text does.
    (copy / "build").mkdir(exist_ok=True)
    ran = run(argv, stdin=stdin)
    shown = "exited %d\n%s%s" % (ran.returncode,
                                  ran.stdout.decode("utf-8", "replace"),
                                  ran.stderr.decode("utf-8", "replace"))
    stream = meta.get("stream", "merged")
    output = ran.stdout if stream == "output" else ran.stdout + ran.stderr
    if meta.get("traps") == "yes":
        #  Ended by a signal: bubblewrap reports it as 128 and its number.
        if ran.returncode <= 128 and ran.returncode >= 0:
            checks.fail(what, "returned a status, not a trap: " + shown)
            return
        report = meta.get("trap_report")
        if report and report.encode() not in output.splitlines():
            checks.fail(what, "did not report %r: %s" % (report, shown))
            return
    elif ran.returncode != int(meta.get("status", "0")):
        checks.fail(what, "expected status %s: %s"
                    % (meta.get("status", "0"), shown))
        return
    if stream == "output" and ran.stderr:
        checks.fail(what, "wrote to standard error: " + shown)
        return
    if "run_expect" in meta and \
            output != (directory / meta["run_expect"]).read_bytes():
        checks.fail(what, "printed other than %s: %s"
                    % (meta["run_expect"], shown))
        return
    checks.ok(what)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--alpine", type=pathlib.Path, required=True)
    parser.add_argument("--work", type=pathlib.Path, required=True)
    args = parser.parse_args()
    if shutil.which("bwrap") is None:
        parser.error("bubblewrap's bwrap is not on PATH; install it, the"
                     " package bubblewrap on Debian and Ubuntu")
    work = args.work.resolve()
    if work == ROOT or ROOT in work.parents:
        parser.error("%s is inside the checkout" % work)
    if not (args.alpine / "etc/alpine-release").is_file():
        parser.error("%s is no Alpine root: it has no etc/alpine-release;"
                     " landin_fetch_alpine in environments/pins.sh unpacks"
                     " the pinned one" % args.alpine)
    machine = os.uname().machine
    target = HOST_TARGETS.get(machine)
    if target is None:
        parser.error("no Linux archive is built for %s" % machine)
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    checks = Checks(work)
    prefix = work / "prefix"
    prefix.mkdir()
    with tarfile.open(args.archive) as archive:
        archive.extractall(prefix, filter="tar")
    splits = sorted(path.name[len("refine-"):] for path
                    in (prefix / "libexec/landin").glob("refine-*"))
    check_archive(checks, args.archive, prefix)
    check_empty_root(checks, prefix, splits)
    check_alpine(checks, args.archive.resolve(), args.alpine.resolve(),
                 target)
    for failure in checks.failures:
        print("FAIL " + failure, file=sys.stderr)
    print("static check: %d passed, %d failed"
          % (checks.passed, len(checks.failures)))
    return 1 if checks.failures else 0


if __name__ == "__main__":
    sys.exit(main())
