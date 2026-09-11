# Native acceptance operations

`ROADMAP.md` R0.70 owns this environment. `scripts/ci/policy.json` is the
canonical acceptance job list; `scripts/ci/common.py` independently requires
every job and command. SourceHut runs only approved-main Pages publication
and GitHub mirroring. A development run cannot authorize publication.

## Commands

Run from a clean invocation checkout for acceptance, approval and promotion.
The commit may be on an isolated worktree branch. These commands never modify
the shared main checkout or its index.

```sh
export LANDIN_CI_SSH="ssh -i ~/.ssh/landin-ci-2026-09-10"
python3 scripts/ci/controller.py dev --slot my-change -- \
    ./scripts/dev-test.sh --fixture=negative/variant-match-duplicate
python3 scripts/ci/controller.py accept HEAD
python3 scripts/ci/controller.py status RUN_ID
python3 scripts/ci/controller.py accept COMMIT --resume RUN_ID
python3 scripts/ci/controller.py export RUN_ID
python3 scripts/ci/controller.py approve ~/.local/state/landin/acceptance/RUN_ID/bundle
python3 scripts/ci/controller.py promote FULL_COMMIT
```

`--host` and `--state` are global options, placed before the subcommand.
The default host is `landin-ci-x86-64`. Development uses a working-tree
snapshot and preserves its slot's build cache. It prints
`DEVELOPMENT / NOT ACCEPTANCE`; exact developer selectors remain available.

Acceptance resolves the full commit and tree, creates one Git archive, and
compares its content inventory with the Git objects, including filename bytes,
executable bits and symlinks. Export attributes cannot silently change the
source under test. The controller rejects unsafe paths, special files,
symlink escapes and reserved cache/evidence paths before transfer. All eight
jobs receive the same archive. Each slot recomputes the inventory before and
after its commands and checks the initialized policy and environment.

The policy runs clean debug/release complete suites and native report identity,
clean debug/release quality, clean debug/release native GDB, Clang-19 bindings,
and document/tooling regressions plus full `check.py` and verified rendering.
`refine --identify` is recorded in both suite jobs. Native GDB has no QEMU
fallback. Runtime, ABI and workload profiles remain owned by their existing
harnesses. There is no filtered, recording-mode or incremental acceptance.
Private font absence is recorded explicitly; publication still requires the
licensed fonts. The native runner need not hold those private files.

## Host protocol and deployment

The supported host is native Linux x86-64, with Python 3, SSH, `flock`, rsync,
Git, Debian's Clang-19, GDB, binutils and libc6-dev, plus the GNAT/GPRbuild
installations selected by `environments/pins.sh`. No new version source is
introduced. The existing installed runner protocol is:

```text
landin-ci run SLOT -- COMMAND...    # stdin is a gzip tar snapshot
landin-ci list
landin-ci clean SLOT
```

The installed runner validates slot names, locks
`/home/landin/work/SLOT/lock` with nonblocking `flock`, extracts the snapshot
into `incoming`, and uses `rsync -a --checksum --delete` to update `src`,
excluding `/compiler/ada/build/`. It runs the command from `src` while holding
the slot lock. Exit 75 means busy and carries no compiler verdict. The
controller validates archives before using this trusted installed protocol.
Do not use `clean` on a live slot or on retained acceptance evidence.

The host runs the account `landin` inside its existing container, reachable
through the tailnet's SSH service. Its persistent work volume owns both slots
and `.acceptance`. Native GDB requires the existing ptrace capability. The
initial migration adds repository-owned Python job/evidence handling; it
requires no daemon, sudo, image rebuild or signing secret. Provision a new
host with the same installed slot protocol and packages, install the Ada
archives with `landin_install_toolchain` from `environments/pins.sh`, and make
`LANDIN_GNAT_HOME` and `LANDIN_GPRBUILD_HOME` available to SSH sessions.

For an existing runner image without Git, the repository supplies a user-owned
Debian package installation, leaving the installed runner and toolchain intact:

```sh
ssh landin@landin-ci-x86-64 sh -s < environments/native-ci/setup-user-tools.sh
```

It downloads Debian's Git package into the account's tools directory and
records the package version and download hash. The acceptance environment
selects that Git, its helper programs and templates explicitly; provenance
records the actual Git binary path, version and hash. Refresh this installation
deliberately between runs. A tool or environment change requires new acceptance.
The shell uses a private package-list directory and does not update system
packages. Account credentials and tailnet/SSH key management remain host
administration; this repository contains no secrets or signing service.

## Records and recovery

Initialization creates `/home/landin/work/.acceptance/RUN_ID` atomically. It
contains the request, source archive and extracted source, environment record,
per-job attempts, retained logs and artifacts, successful job records, and a
completed `record.json` only when every required job validates. Actual package
versions, tool binary hashes, OS/kernel/boot identity, exact argv, whitelisted
environment, timestamps, elapsed times, exits and file hashes are retained.

Each attempt has a start record and streams progress with its job name.
`status` distinguishes running work from missing/interrupted work. A second
process cannot acquire the same job lock. Missing/interrupted work can resume
only with the original initialized request and unchanged environment. A
completed failed attempt requires a new run. Successful jobs validate their
retained evidence and do not run again on resume. Completed records are never
overwritten. Keep failed and partial attempts for diagnosis.

The controller exports and verifies the completed bundle under
`~/.local/state/landin/acceptance/RUN_ID/bundle` before approval. This is a
second copy independent of the host's mutable slots and temporary directories.
Preserve approved host records and local exports indefinitely; there is no
automatic expiry, pruning or backup service in this migration. An operator
must arrange any additional backup. Lost/corrupt evidence cannot be replaced
by an assertion of success; rerun acceptance when it cannot be recovered.

## Approval and publication

Approval creates the ordinary annotated administrative tag
`ci/accepted/FULL_COMMIT`. Its strict JSON annotation binds commit/tree,
source/archive/policy, initialized request, environment, completed record and
all required job hashes/outcomes. This is not a release or version tag.
Canonical Git maintainer write access is the approval authority, as with the
previous repository-controlled CI. The runner account can modify its own
storage: these are durable operational records, not tamper-proof attestations
or protection against a hostile maintainer.

Promotion validates the tag, fetches canonical main, requires fast-forward
ancestry and atomically pushes the tag plus main without force. Tag collisions
and non-fast-forward races refuse the operation without partial promotion.
Direct unapproved main pushes are not prevented by server-side protection;
the publication guard refuses them.

Both `.build.yml` and `scripts/site.sh --publish` call
`scripts/ci/approval.py`. It requires a clean checkout at current canonical
main, fetches the exact canonical annotated approval without replacement,
reconstructs source/tree/policy identities, and verifies all required outcomes.
The SourceHut guard runs before private-font access. Manual publication checks
again after rendering. Canonical ref checks detect known-stale revisions;
there is no cross-service transaction locking Git while Pages uploads. If
publication fails, diagnose the failure and retain the previous site; do not
bypass the guard. Non-publishing rendering remains available for any checkout.

## Supplemental Nix validation

When `flake.nix`, `flake.lock`, `environments/pins.sh` or shell-related scripts
change, run the shell check explicitly on native Linux with Nix installed:

```sh
nix develop --command sh -eu -c './scripts/toolchain.sh; ./scripts/test.sh'
```

This checks the Nix environment and is supplemental. It is neither an automatic
SourceHut job nor a required job in the native acceptance policy. Historical
Nix and SourceHut results remain in `docs/environments.md` and `ROADMAP.md`.
