# Native acceptance operations

> **Retired.** This describes the exact-revision gate that approved every
> revision through 0.2.0. Nothing submits it now and no revision is accepted;
> `scripts/ci/` is retained but dead. Kept because it is the operational
> record of how those approvals were produced, and because the replacement
> gate is not designed yet. See [`MOVING.md`](../../MOVING.md).

`ROADMAP.md` R0.70 owns this environment. `scripts/ci/policy.json` is the
canonical acceptance job list; `scripts/ci/common.py` independently requires
every job and command for the committed scope. SourceHut runs only approved-main Pages publication
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
symlink escapes and reserved cache/evidence paths before transfer. All selected
jobs receive the same archive. Each slot recomputes the inventory before and
after its commands and checks the initialized policy and environment.

The committed policy has two scopes. Routine R5/R6 promotion runs five jobs:
clean debug compiler-host checks (`test.sh --host`), the complete release
suite and native report identity, release object quality, Clang-19 bindings,
and documents/tooling with full `check.py` and verified rendering. A routine
change with substantial source-debugging regression risk adds release GDB.
Full milestone acceptance runs the complete suite, quality and native GDB in
both compiler modes, plus bindings and documents: eight jobs.

Select the scope **before committing**; acceptance has no unrecorded scope
switch. The policy, commands and scope are bound into the archive, request,
evidence and annotated approval:

```sh
python3 scripts/ci/policy.py routine
python3 scripts/ci/policy.py routine --debugger  # substantial debugging risk
python3 scripts/ci/policy.py milestone          # major phase/parity milestone
```

A debugger risk includes changed debug metadata, source/variable location
tracking, unwind or frame conventions, debugger transport/tests, or acceptance
selection/verification of debugger coverage.
An ordinary documentation, scanner or unrelated tooling change does not
trigger GDB. Record the decision in the change's review/roadmap evidence.
Major phase/parity closure, including R5.50 and R6.100, requires milestone
scope; routine approval is not evidence of full milestone coverage. Return
to routine scope in the next development commit after milestone delivery.

Schema-1 policies and approvals retain their historical eight-job meaning.
Schema-2 policies explicitly name `routine` or `milestone` and the debugger
choice; new approvals expose the scope and required job hashes. Missing jobs,
substituted commands or relabelled scope are refused. There is no recording-mode
or incremental acceptance. `HOST-ONLY` is allowed only in routine debug scope;
release runtime/ABI execution remains complete. Private font absence is
recorded explicitly; publication still requires the licensed fonts.

See [the validation workflow](../../docs/process.md) for the measured costs,
development cadence, parallelism and deferred Nix CI work.

## Resource containment

Acceptance runs on the native Linux host. Its policy allows eight concurrent jobs,
with explicit `-j8` bootstrap builds, and at most 100 GiB of memory with no swap
for the execution cgroup and its descendants. These are aggregate kernel
limits, not estimates from process RSS or per-process virtual-memory limits.
A failed job writes a durable run-local cancellation marker; peer command
supervisors terminate their owned sessions even if live output stalls. The
controller also requests cancellation on a failed SSH job. Eight host-wide
slots bound acceptance concurrency across controllers. Children inherit the
slot, individual job lock and shared compatibility lock; an older exclusive
serial runner cannot overlap these jobs. With the mandatory compiler/peripheral
documents lane, milestone acceptance has seven compiler build jobs and at most
56 build workers; routine acceptance has four, or five when GDB is required. All remain within
the same aggregate limits on the 96-CPU host.

Before probing tools, initialization verifies the current unified cgroup v2
membership and reads that cgroup's `memory.max` and `memory.swap.max`.
Missing, unlimited or excessive values refuse acceptance. For this supported
deployment, both limits must be explicit on the execution cgroup; an unseen
ancestor limit is not accepted as evidence. The actual limits become part of
the environment record and must remain unchanged on resume. The runner reads
the configuration and never changes host cgroups itself.

The host administrator must provide a dedicated runner container or execution
cgroup with `memory.max` no greater than `107374182400` and
`memory.swap.max` equal to `0`. Check that no existing work is active before
changing its limits; do not lower a shared container's cap beneath unrelated
live workloads. The aggregate cap is enforced by the
[Linux memory controller](https://www.kernel.org/doc/html/v6.14/admin-guide/cgroup-v2.html).
Initial deployment inspection found unlimited memory and swap and no cgroup
write access for the runner account. After the maintainer redeployed the
Docker runner with the 100 GiB settings, a direct kernel read confirmed
`memory.max=107374182400`, `memory.swap.max=0` and zero OOM events. This supplies
configuration evidence; no deliberate OOM workload is needed to verify it.

The existing deployment uses Docker Compose. Its local deployment notes live
in the main worktree's `.scratch/ci-hosts/`; its `runner` and `tailscale`
services share networking but keep separate containers. The tracked
`environments/native-ci/compose.resources.yaml` overrides only the runner's
memory settings. Docker's `memswap_limit` counts memory plus swap, so setting
it equal to `mem_limit` disables swap; see the
[Compose service reference](https://docs.docker.com/reference/compose-file/services/#memswap_limit).

If the Containerfile changed, first run `docker compose build runner` from
the deployed Compose directory. This rebuilds the runner image, including
Git installed in the image.

Once all runner work is idle, copy that override beside the deployed
`compose.yaml` on the Docker host and apply it there:

```sh
docker compose -f compose.yaml -f compose.resources.yaml \
    up -d --no-deps --no-build --pull never runner
docker compose -f compose.yaml -f compose.resources.yaml \
    exec -T runner sh -c \
    'cat /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max'
```

The expected kernel values are `107374182400` and `0`, respectively; Docker
configuration alone is not sufficient evidence. The first command may
recreate the runner and disconnect its SSH sessions, which is why it requires
idle work. It preserves the existing work and SSH host-key volumes and leaves
the Tailscale service running. Retain both Compose files in future deployment
commands so recreation does not remove the limits. Do not use `down -v`.

Each policy command has a two-hour outer deadline, covering descendants and
inherited output pipes. Timeout terminates the process group and records a
failure. On Linux, supervision also stops the separate tool process groups
that the compiler creates inside the command's session. Existing finer-grained
harness deadlines remain applicable. Cgroup
OOM kill counters are retained before and after each job; a change fails the
job even if its commands returned zero. Smaller limits may cause a legitimate
workload to fail: retain that failure and diagnose it rather than silently
raising the limit or approving incomplete evidence.

Containment does not authorize giant-image assembly or replace an input audit.
R4.91 retains its forbidden giant fixtures as source/IR evidence, and the
remaining native execution plan must be reviewed before launching the gate.
No assembler sweep is run to validate these controls. They are tested using
fake cgroup files and tiny supervised Python processes.

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

It downloads Debian's Git package into `~/work/.ci-tools` on the persistent
work volume and
records the package version and download hash. The acceptance environment
selects that Git, its helper programs and templates explicitly; provenance
records the actual Git binary path, version and hash. Refresh this installation
deliberately between runs. A tool or environment change requires new acceptance.
The earlier `~/.local/share/landin-ci-tools` location lived in the container's
writable layer and disappeared on recreation; it is no longer selected.
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

Promotion uses canonical `git@git.sr.ht:~sinnfrei/landin` with the maintainer's
existing Git SSH credentials. It validates the tag, fetches canonical main,
requires fast-forward ancestry and atomically pushes the tag plus main without
force. Pages reads canonical refs over HTTPS. Tag collisions
and non-fast-forward races refuse the operation without partial promotion.
Direct unapproved main pushes are not prevented by server-side protection;
the publication guard refuses them.

`scripts/ci/approval.py` requires a clean checkout at current canonical
main, fetches the exact canonical annotated approval without replacement,
reconstructs source/tree/policy identities, and verifies all required outcomes.
Nothing calls it any more: the `.build.yml` that ran it on a push is retired,
and `scripts/site.sh` no longer publishes. It is described here as the
retired arrangement. That
publication entered `scripts/ci/publish.py`, which holds an owned canonical Git
lease across rendering, the final approval check and both domain uploads.
Waiting jobs recheck the exact approved revision after acquiring the lease.
This serializes participating publishers; it does not lock canonical main
against promotion or make the two domain uploads atomic. A failed upload may
have changed one domain, and a timed-out client cannot establish whether its
server request has finished. The publisher retains its lock after an uncertain
upload. Inspect the job and server outcome before recovery; do not bypass the
guard or assume the previous site remains on both domains. The
[site guide](../../docs/site/README.md) owns activation requirements and
exact-lease recovery instructions. Non-publishing rendering remains available
for any checkout.

## Supplemental Nix validation

When `flake.nix`, `flake.lock`, `environments/pins.sh` or shell-related scripts
change, run the shell check explicitly on native Linux with Nix installed:

```sh
nix develop --command sh -eu -c './scripts/toolchain.sh; ./scripts/test.sh'
```

This checks the Nix environment and is supplemental. It is neither an automatic
SourceHut job nor a required job in the native acceptance policy. Historical
Nix and SourceHut results remain in `docs/environments.md` and `ROADMAP.md`.


## Matching Darwin evidence

For source revisions carrying `environments/macos-arm64/acceptance.json`,
Linux acceptance alone cannot authorize approval. Run the native Mac policy
with `scripts/ci/darwin.py accept COMMIT`, then supply its verified export:

```sh
python3 scripts/ci/controller.py approve LINUX_BUNDLE --darwin DARWIN_BUNDLE
```

Both bundles must have identical commit, tree, archive and source inventories.
The approval annotation binds the Mac policy and retained record; ordinary
promotion and publication validate this additional identity. Darwin schema 4 must select the same routine/milestone and debugger choice as
Linux. `policy.py` writes both policies together. Routine retains debug/release
Mac host checks and complete release hosted coverage; debugger risk adds full
release LLDB, and milestones retain both modes. Historical schema 3 still
requires Linux milestone scope. Only Linux supports resume. See the
[native Mac operations guide](../macos-arm64/README.md).

## Cortex-M environment evidence

R6.10 adds the [embedded profile](../cortex-m/README.md) to the Linux
documents job. Install its pinned private tools with
`python3 environments/cortex-m/setup.py` before acceptance. The job runs
`test.py` and `run.py`, and retains `artifacts/cortex-m` in the verified
export. Missing tools fail; these are mandatory environment probes on the
Linux host, separate from the hosted Landin workloads. The unchanged
dual-native approval binds this job together with Darwin's native evidence.

R6.20 keeps that mandatory path and adds the QEMU layout/ABI controls to
`run.py`. The same exported `cortex-m` directory retains their contract inputs,
measurements, assembly witnesses, ELF/maps/disassembly and GDB assertions.
The annotated approval binds their actual execution to the accepted revision;
a planner golden alone cannot satisfy this obligation.

R6.30 extends the same mandatory embedded job with independent M0 memory and
interrupt controls plus bounded SC, release-sequence, DMA and cache models.
`memory-model.json`, tool commands, inputs, ELF and GDB results are exported
with the unchanged R6.10/R6.20 lanes. Hosted release fixtures additionally
execute Landin-generated memory operations. Routine debugger-risk scope keeps
native release GDB; model success alone cannot approve this compiler change.

R6.40 extends that mandatory probe command with `--refine {refine}` and a
committed debug build in the documents job. The compiler-generated Linux/Renode
transport lane and its six profiles remain beside the independent M0 C controls
in `artifacts/cortex-m`; the existing inventory/export checks bind both to the
accepted archive. Packed native lowering and raw-carrier DWARF changes select
routine acceptance with debugger risk on both hosts. Development transcripts
and model success never substitute for identical-revision dual-native approval.


R6.50 extends that same mandatory embedded path with the complete inventoried
Cortex-M corpus, generated ABI/frame and arithmetic controls, and direct
synthetic peripheral/DMA execution. `artifacts/cortex-m/backend` retains its
ELF/object/map/disassembly, scripts, commands, identities, results and explicit
physical-limit records. Existing R6.10/R6.20/R6.30/R6.40 evidence and Renode lock
cleanup remain required. These artifacts belong to the accepted archive;
development selectors cannot approve a revision.

R6.60's compiler-owned startup lane retains `artifacts/cortex-m/firmware`.
R6.70's active library increment additionally retains
`artifacts/cortex-m/freestanding`, including explicit module/linker closure,
CPU and allocator consumers, ordinary-slice DMA traces and fresh artifact
comparisons. `run.py` executes these after every inherited lane and the existing
recursive export hashes bind them to the accepted archive. The old corpus,
firmware counts and Renode lock-cleanup obligations remain mandatory. These
additional controls do not by themselves close the remaining R6.70 panic and
noreturn obligations.

R6.80 adds `devices.py` after the inherited Cortex lanes. Its checked-in vendor
inputs, regeneration checks, source refusals, compiler-owned firmware and
independent C/assembly peripheral control are mandatory; recursive artifact
hashes bind `artifacts/cortex-m/devices` to the same accepted archive.

R6.90 appends `driver.py` to the same mandatory embedded runner and recursive
export. Its complete application, API client and separate layout control
retain compiler-owned firmware, independent assertions and every inherited
lane. Matching routine debugger-risk policies cover the checker/context and
BSS ELF load-address repairs. See the [derivation](../../compiler/tests/driver/DERIVATION.md);
R6.100 still owns full Cortex source-debugging and measured-stack closure.

R6.100 uses compatible dual-native milestone policies. The documents job's
mandatory embedded entry includes `evidence.py` after the complete driver:
Cortex line/function GDB, complete measured application scenarios, debug/load
identity checks and independent stack/exception controls. Its recursive export
includes the new `evidence` tree. Native GDB runs in both Ada modes as well;
Cortex remote debugging does not replace it. Failed or interrupted embedded
commands cannot be approved or substituted by development artifacts.
