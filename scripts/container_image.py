#!/usr/bin/env python3
"""Build, check and publish the two container images of a release.

    python3 scripts/container_image.py build user ARCHIVE --tag TAG [--version V --revision R]
    python3 scripts/container_image.py build contributor --tag TAG [--version V --revision R]
    python3 scripts/container_image.py check user TAG [--debugger]
    python3 scripts/container_image.py check contributor TAG
    python3 scripts/container_image.py save TAG FILE
    python3 scripts/container_image.py publish VERSION DIRECTORY [--layout DIR] [--outputs FILE]

The user image, `ghcr.io/OWNER/landin`, is a release archive's prefix
unpacked into `/usr/local` of a Debian image with its own gcc and
binutils (D1667); the contributor image, `ghcr.io/OWNER/landin-contributor`,
is the pinned GNAT and GPRbuild environment that builds the compiler
(D1668).  Both are built from `environments/images/`, for the platform of
the host that builds them, with `docker` or with the engine `--engine`
names.  OWNER is the repository's owner, as `scripts/release.py` reads it,
so a transfer changes nothing here.

`build user` puts ARCHIVE, as `scripts/package.sh` lays one out, in an
empty context beside the recipe, so nothing else of the checkout reaches
the image.  `build contributor` builds from `environments/`, whose
`pins.sh` the recipe copies in.  `--version` and `--revision` label the
image with the release and the commit, and the source label names the
repository, which links a published package to it.

`check user` runs what the README's "In a container" section tells a
reader to, in a fresh container each time, with a directory of the
reader's mounted at `/work` and the container run as the reader's own
user: `refine version`, which must name the library in
`/usr/local/lib/landin`, then the first program compiled with `refine
compile`, owned by the reader, and run, and run again with `refine run`,
each printing exactly its fixture's output.  With
`--debugger` it also installs Debian's GDB in a container and stops the
first program at `main`, with and without `--cap-add=SYS_PTRACE`, and
requires the run the README gives to stop there.

`check contributor` bind-mounts this checkout at `/work`, builds `refine`
there with the image's toolchain under the build tag `image`, as the
invoking user, and runs the first program with it.

`save` writes TAG as an archive for `publish`, which reads
DIRECTORY/user-amd64.tar, user-arm64.tar, contributor-amd64.tar and
contributor-arm64.tar.  For each image it assembles one manifest list of
both platforms with `podman` and refuses unless the list holds exactly
linux/amd64 and linux/arm64.  With `--layout DIR` it pushes the lists into
an OCI layout there, which publishes nothing and is how the release
rehearsal checks the step; without it it pushes each to the registry as
VERSION, the only tag it ever moves.  A tag the registry
already holds is never replaced, since the build is not reproducible: it
is reported and left as it is, so a publication that stopped part-way is
completed by running again.  `--outputs` appends `user-digest=` and
`contributor-digest=` lines, for the attestation steps, to FILE.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import release  # noqa: E402

RECIPES = ROOT / "environments/images"
FIRST_PROGRAM = ROOT / "compiler/tests/fixtures/runtime/first-program"
REGISTRY = "ghcr.io"
NAMES = {"user": "landin", "contributor": "landin-contributor"}
ARCHITECTURES = ("amd64", "arm64")
LIBRARY = "/usr/local/lib/landin"


class Refused(Exception):
    pass


def run(argv, check=True, **options):
    print("+ " + " ".join(argv), flush=True)
    done = subprocess.run(argv, **options)
    if check and done.returncode:
        raise Refused("%s ended with status %d" % (argv[0], done.returncode))
    return done


def capture(argv, stdin=b""):
    """ARGV's status, standard output and error, given STDIN."""
    print("+ " + " ".join(argv), flush=True)
    done = subprocess.run(argv, input=stdin, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)
    return done.returncode, done.stdout, done.stderr


def owner():
    return release.repository().split("/")[0].lower()


def reference(kind, version):
    return "%s/%s/%s:%s" % (REGISTRY, owner(), NAMES[kind], version)


def labels(kind, version, revision):
    found = ["org.opencontainers.image.source=https://github.com/%s"
             % release.repository(),
             "org.opencontainers.image.title=" + NAMES[kind],
             "org.opencontainers.image.description=" + (
                 "The Landin compiler refine, its library and the C compiler "
                 "it links with" if kind == "user" else
                 "The pinned GNAT and GPRbuild environment that builds refine")]
    if version:
        found.append("org.opencontainers.image.version=" + version)
    if revision:
        found.append("org.opencontainers.image.revision=" + revision)
    return [word for label in found for word in ("--label", label)]


def build(engine, kind, archive, tag, version, revision):
    marks = labels(kind, version, revision)
    if kind == "contributor":
        run([engine, "build", "--file", str(RECIPES / "contributor.Containerfile"),
             "--tag", tag, *marks, str(ROOT / "environments")])
        return
    if archive is None or not Path(archive).is_file():
        raise Refused("build user needs the release archive to unpack; "
                      "%s is not a file" % archive)
    with tempfile.TemporaryDirectory(prefix="landin-user-image-") as context:
        shutil.copyfile(RECIPES / "user.Containerfile",
                        Path(context) / "Containerfile")
        shutil.copyfile(archive, Path(context) / "landin.tar.gz")
        run([engine, "build", "--file", str(Path(context) / "Containerfile"),
             "--tag", tag, *marks, context])


def first_program():
    return ((FIRST_PROGRAM / "main.ldn").read_bytes(),
            (FIRST_PROGRAM / "output.txt").read_bytes())


def expect(failures, what, status, printed, said, wanted):
    if status != 0:
        failures.append("%s ended with status %d\n%s" % (
            what, status, said.decode("utf-8", "replace")))
    elif printed != wanted:
        failures.append("%s printed %r, not %r\n%s" % (
            what, printed, wanted, said.decode("utf-8", "replace")))
    else:
        print("ok   " + what, flush=True)


def check_user(engine, tag, debugger):
    """The README's commands, as it gives them: the reader's directory
    mounted at /work and the container run as the reader's own user."""
    failures = []
    source, wanted = first_program()
    with tempfile.TemporaryDirectory(prefix="landin-user-check-") as work:
        (Path(work) / "main.ldn").write_bytes(source)
        os.chmod(work, 0o755)
        reader = [engine, "run", "--rm", "--volume", "%s:/work" % work,
                  "--user", "%d:%d" % (os.getuid(), os.getgid()), tag]
        status, printed, said = capture(reader + ["refine", "version"])
        lines = printed.decode("utf-8", "replace").splitlines()
        if status != 0 or len(lines) < 2 or not lines[0].startswith("refine ") \
                or lines[1] != "library: " + LIBRARY:
            failures.append("refine version did not name %s as its library\n%s%s"
                            % (LIBRARY, printed.decode("utf-8", "replace"),
                               said.decode("utf-8", "replace")))
        else:
            print("ok   refine version: %s, %s" % (lines[0], lines[1]),
                  flush=True)
        status, printed, said = capture(reader + ["refine", "compile",
                                                  "main.ldn", "-o", "main"])
        if status != 0:
            failures.append("refine compile ended with status %d\n%s%s" % (
                status, printed.decode("utf-8", "replace"),
                said.decode("utf-8", "replace")))
        else:
            status, printed, said = capture(reader + ["./main"])
            expect(failures, "refine compile, then the program", status,
                   printed, said, wanted)
            owner_id = (Path(work) / "main").stat().st_uid
            if owner_id != os.getuid():
                failures.append("the program belongs to user %d, not to the "
                                "reader, %d" % (owner_id, os.getuid()))
        status, printed, said = capture(reader + ["refine", "run", "main.ldn"])
        expect(failures, "refine run", status, printed, said, wanted)
    if debugger:
        failures += check_debugger(engine, tag, source)
    return failures


def check_debugger(engine, tag, source):
    """GDB from Debian's archive, as the README tells a reader to add it,
    stopping the first program at main; the run without the capability is
    reported, so the README's advice stays a measured one."""
    script = ("set -e; apt-get update -qq >&2; "
              "apt-get install -qq --yes --no-install-recommends gdb >&2; "
              "cd /tmp; cat > main.ldn; refine compile main.ldn -o main >&2; "
              "gdb -batch -ex 'break main' -ex run -ex bt ./main 2>&1")
    failures = []
    for granted in (["--cap-add=SYS_PTRACE"], []):
        what = "gdb stops at main%s" % (
            " with --cap-add=SYS_PTRACE" if granted else
            " without the capability")
        status, printed, said = capture(
            [engine, "run", "--rm", "--interactive", *granted, tag,
             "sh", "-c", script], source)
        text = printed.decode("utf-8", "replace")
        stopped = status == 0 and "Breakpoint 1," in text
        print("%s %s\n%s" % ("ok  " if stopped else "no  ", what, text),
              flush=True)
        if granted and not stopped:
            failures.append("%s: it did not\n%s%s" % (
                what, text, said.decode("utf-8", "replace")))
    return failures


def check_contributor(engine, tag):
    failures = []
    who = "%d:%d" % (os.getuid(), os.getgid())
    mount = ["--user", who, "--env", "HOME=/tmp", "--env",
             "LANDIN_BUILD_TAG=image", "--volume", "%s:/work" % ROOT,
             "--workdir", "/work"]
    status = run([engine, "run", "--rm", *mount, tag,
                  "./scripts/build.sh", "--compiler-only"],
                 check=False).returncode
    if status:
        return ["the compiler did not build inside %s: status %d"
                % (tag, status)]
    print("ok   the compiler built inside the image", flush=True)
    _, wanted = first_program()
    status, printed, said = capture(
        [engine, "run", "--rm", *mount, tag,
         "compiler/ada/build/image/debug/bin/refine", "run",
         str(FIRST_PROGRAM.relative_to(ROOT) / "main.ldn")])
    expect(failures, "the image's own refine runs the first program", status,
           printed, said, wanted)
    return failures


def loaded(archive):
    """The name `podman load` gives the image in ARCHIVE."""
    done = run(["podman", "load", "--input", str(archive)],
               stdout=subprocess.PIPE, text=True)
    print(done.stdout, end="")
    names = [line.split(":", 1)[1].strip() for line in done.stdout.splitlines()
             if line.startswith("Loaded image")]
    if not names:
        raise Refused("podman named no image loaded from %s" % archive)
    return names[-1]


def published(ref):
    """Whether the registry already holds REF."""
    status, _, said = capture(["skopeo", "inspect", "--raw", "docker://" + ref])
    if status == 0:
        return True
    text = said.decode("utf-8", "replace")
    if "manifest unknown" in text or "not found" in text.lower():
        return False
    raise Refused("the registry could not say whether it holds %s:\n%s"
                  % (ref, text))


def platforms(manifest):
    listed = json.loads(run(["podman", "manifest", "inspect", manifest],
                            stdout=subprocess.PIPE, text=True).stdout)
    return sorted("%s/%s" % (entry["platform"]["os"],
                             entry["platform"]["architecture"])
                  for entry in listed.get("manifests", []))


def publish(version, directory, layout, outputs):
    directory = Path(directory)
    wanted = ["linux/%s" % arch for arch in ARCHITECTURES]
    said = []
    for kind in NAMES:
        ref = reference(kind, version)
        if layout is None and published(ref):
            print("%s is already published; it is left as it is" % ref)
            continue
        manifest = "landin-publish-%s" % kind
        run(["podman", "manifest", "rm", manifest], check=False,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run(["podman", "manifest", "create", manifest])
        for arch in ARCHITECTURES:
            archive = directory / ("%s-%s.tar" % (kind, arch))
            if not archive.is_file():
                raise Refused("%s is missing: publish takes both platforms "
                              "of both images" % archive)
            run(["podman", "manifest", "add", manifest,
                 "containers-storage:" + loaded(archive)])
        held = platforms(manifest)
        if held != wanted:
            raise Refused("%s's list holds %s, not %s" % (
                kind, ", ".join(held) or "nothing", ", ".join(wanted)))
        print("ok   %s holds %s" % (ref, ", ".join(held)), flush=True)
        if layout is not None:
            destination = "oci:%s:%s-%s" % (layout, NAMES[kind], version)
        else:
            destination = "docker://" + ref
        with tempfile.TemporaryDirectory(prefix="landin-digest-") as scratch:
            digest_file = Path(scratch) / "digest"
            run(["podman", "manifest", "push", "--all", "--digestfile",
                 str(digest_file), manifest, destination])
            digest = digest_file.read_text().strip()
        print("pushed %s to %s as %s" % (ref, destination, digest), flush=True)
        said.append("%s-digest=%s" % (kind, digest))
        said.append("%s-name=%s" % (kind, ref.rsplit(":", 1)[0]))
    if outputs:
        with open(outputs, "a", encoding="utf-8") as stream:
            for line in said:
                stream.write(line + "\n")


def main(argv):
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n")[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--engine", default="docker",
                        help="the container engine that builds and runs, "
                             "docker by default")
    commands = parser.add_subparsers(dest="command", required=True)
    built = commands.add_parser("build")
    built.add_argument("kind", choices=sorted(NAMES))
    built.add_argument("archive", nargs="?")
    built.add_argument("--tag", required=True)
    built.add_argument("--version", default="")
    built.add_argument("--revision", default="")
    checked = commands.add_parser("check")
    checked.add_argument("kind", choices=sorted(NAMES))
    checked.add_argument("tag")
    checked.add_argument("--debugger", action="store_true")
    saved = commands.add_parser("save")
    saved.add_argument("tag")
    saved.add_argument("file")
    sent = commands.add_parser("publish")
    sent.add_argument("version")
    sent.add_argument("directory")
    sent.add_argument("--layout")
    sent.add_argument("--outputs")
    asked = parser.parse_args(argv[1:])
    try:
        if asked.command == "build":
            if asked.kind == "contributor" and asked.archive:
                raise Refused("the contributor image is built from the "
                              "checkout and takes no archive")
            build(asked.engine, asked.kind, asked.archive, asked.tag,
                  asked.version, asked.revision)
        elif asked.command == "check":
            if asked.kind == "contributor" and asked.debugger:
                raise Refused("--debugger checks the user image")
            failures = (check_user(asked.engine, asked.tag, asked.debugger)
                        if asked.kind == "user" else
                        check_contributor(asked.engine, asked.tag))
            if failures:
                for failure in failures:
                    print("FAIL " + failure, file=sys.stderr)
                return 1
        elif asked.command == "save":
            run([asked.engine, "save", "--output", asked.file, asked.tag])
        else:
            publish(asked.version, asked.directory, asked.layout, asked.outputs)
    except Refused as refusal:
        print("container_image: %s" % refusal, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
