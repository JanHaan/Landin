# Ask about Landin

This is a private Cloudflare Worker prototype with a two-pane chat workspace.
The conversation supports follow-up messages; an editable source file and console
sit beside it. It answers from a snapshot of the reading copies' source documents and returns source
links. Its optional Cloudflare Containers endpoint compiles and runs a single Landin
source file inside a fresh Linux x86-64 microVM. The checked `refine` executable
is packaged in the image once; visitor requests never rebuild the compiler.
The website remains on GitHub Pages. Nothing here publishes automatically.

## Local preview and checks

Use Node 22 or later and Python 3. The ordinary site renderer still needs only
the Python standard library; Node belongs to this separate service.

```sh
cd docs/site/ask
npm ci --ignore-scripts
npm test
npm run dev
```

Open the local URL printed by Wrangler. Documentation search needs no model
API key, but private access and quotas require `PREVIEW_KEY` and `RATE_SALT`.
Generated answers also require an API key. Configure secrets in the ignored
`.dev.vars` file: `ANTHROPIC_API_KEY`, `PREVIEW_KEY` and `RATE_SALT`. The last
two must each contain at least 32 random characters. Keep keys outside Git
and never put them in a page, prompt or generated corpus. The preview key
is entered in the browser and retained only in that page's memory.

Configure a separate random `ADMIN_KEY`, at least 32 characters, for private
transcript export. It is never entered in the visitor page. A preview key
does not grant access to transcripts.

Personal Claude accounts can use the [Claude Console](https://platform.claude.com).
Its organization and workspace are API billing containers; they do not require
a Team subscription. Create a `Landin` workspace under Settings > Workspaces,
set $70 on its Spend limits tab, and create a key scoped only to that workspace.
The organization's Billing > Spend limits can also be set to $70 when no other
API projects need it. Store the key as `ANTHROPIC_API_KEY` in `.dev.vars` only
after setting the limits. See [workspace setup](https://platform.claude.com/docs/en/manage-claude/workspaces).
Max subscription API credits can fund that organization without buying credits;
keep automatic reload disabled if relying on those credits alone.

`build.py` reads the renderer's existing document inventory, preserves the
document headings and links, and creates a lexical search index. Snapshot
identity includes the source-content hash, Git commit and whether the source
documents have local changes. `build/`, dependencies and Wrangler's
local state are ignored. `npm run deploy` requires deployment inputs to be
committed; a deployment is still a separate operator action.

The pinned Wrangler uses an alpha Miniflare release supplied by its upstream
dependency tree. Both are locked in `package-lock.json`. The `sharp` override
uses the patched release for its librsvg dependency advisory; the packaging
and actual workerd controls run against that override. It is a development
dependency, never part of the deployed Worker.

## Authority and answer quality

The specification decides semantics; the README describes current compiler
capabilities; the roadmap describes open work and future plans. The tour
explains a wider language than the enabled kernel. Prototype sketches and
their historical rejected wording are not runnable examples. Retrieved
passages carry that standing into the prompt.

The service fixes the model, prompt, maximum output, source corpus and
upstream endpoints. Visitor input cannot supply tools, system messages,
models or destinations. The bounded agent loop has only `search_docs` and,
when execution is enabled, `compile_run`. It can inspect compiler diagnostics
and repair source. Each turn allows at most four model calls, three tool calls,
two sandbox attempts and 90 seconds. The last model call has no tools. Parallel
tool requests, unknown tools, oversized arguments and duplicate executions of
the same source are rejected. Transport failures never trigger another attempt.
Build and run also lets the visitor test an edited source file manually.

The browser sends only a question and its current source file, never model
history. A server-owned conversation stores at most eight completed pairs in
64 KiB of context, dropping old pairs together; full transcripts remain saved.
A random conversation capability is kept in page memory and sent as a header.
A shared preview key alone cannot read another conversation. One turn may be
active per conversation. Stop records cancellation; an in-flight call can finish,
but no further model or tool calls are admitted afterwards. Reloading loses the
page capability and starts a new chat. Every run compiles a complete source file;
there is no persistent interpreter state. Signed provider thinking is forwarded
only during the live tool loop and never stored or displayed. Citation IDs must belong to the retrieved passages; their
URLs come from the source index. This validates citation identity, not that
the cited passage supports every sentence: that needs answer evaluation.
Answers, source titles, diagnostics and program output are rendered as text.

`evaluation.json` records representative questions and answer criteria.
`npm test` checks retrieval, limits, authentication, upstream request shape,
failure accounting and concurrent reservations in workerd's SQLite-backed
Durable Object. `scripts/tests/test_ask.py` checks source preservation and
launcher resource controls using tiny Python children. Those tests make no
claim about model answer quality or native compiler/gVisor execution.
Evaluate actual model answers privately and verify deployed container isolation
and lifecycle behavior before making execution public. Subscription-based
Claude Code trials are useful comparative evidence, but do not establish the
public API's latency or exact billing behavior.

The selected private profile is Haiku 5.5 with adaptive thinking, `high` effort
and a hard 4,096-token limit shared by thinking and final text. Visitors cannot
change those settings. Incomplete provider responses are rejected and their
reported usage is charged to the ledger; the service does not retry them.
The paired subscription comparison below supports this choice, while a
direct API trial is still needed to test the enforced limit and response time.

### Subscription comparison, 2026-10-08

A parallel Paseo agent used the personal Claude subscription for 18 identical
first-attempt cases per exact model: 12 documentation/refusal questions and
six generated programs. Tools, retries and repair turns were disabled. All
54 responses passed JSON and citation-ID validation. Manual source review
gave these results:

| model | documentation/refusal pass | partial | fail | program compile/run result |
| --- | --- | --- | --- | --- |
| Haiku 5.5 | 9/12 | 1 | 2 | 6/6 |
| Sonnet 5.5 | 12/12 | 0 | 0 | 5/6 |
| Opus 5.5 | 11/12 | 1 | 0 | 6/6 |

Haiku incorrectly denied a 32-bit backend and confused atomic synchronization
with volatile access. Its allocator explanation was incomplete. Opus omitted
a determinism qualifier. Sonnet's generated GCD example returned the wrong
requested process status, illustrating why compilation alone cannot establish
that a program answers the question. The undefined L0080 question tested
honest abstention; the evaluation inventory now says so and adds a known code.

All 18 programs compiled and ran against the same prebuilt compiler. The
program column requires the requested exit value as well as successful
compilation. Native checks used fresh, bounded, network-disabled Docker
containers. The original fixed UID 65532 collided with 123 existing threads
on the shared Docker kernel and could not pass its 64-process limit. A separate
diagnostic used unused UID/GID 65017 and adjusted work-directory ownership,
while preserving the other restrictions and unmodified model source. These
results establish program correctness in that diagnostic, not the exact
production UID's operation or Cloudflare's microVM boundary. The collision
failures, image identities, limits and output are retained in native evidence.

The CLI used each model's default effort, with no effective-effort label in
the results. It did not impose the then-proposed 1,024-token output cap:
10 Haiku responses reported more than 1,024 output tokens, including thinking;
Sonnet and Opus stayed below it. CLI startup/subscription timings and estimated
charges are not API measurements. The frozen prompts, raw results, source
judgments and unmodified programs are retained locally under ignored
`build/model-evaluation/`. This small comparison supports Sonnet's stronger
documentation accuracy, but does not certify public behavior of any model.
Haiku remains the private budget candidate pending API-specific evaluation;
there is no automatic escalation to a more expensive model.

A separately requested `xhigh` follow-up repeated only Haiku's two failed
documentation answers and its incomplete allocator answer, with identical
frozen sources and no corrective hints. It fixed target coverage and allocator
coverage; the atomics/volatile distinction still failed source review. All
three responses reported more than 1,024 output tokens including thinking.
The CLI accepted requested `xhigh` but did not report an effective effort label;
`max` was never requested. These selected reruns do not replace the original
matrix or demonstrate behavior under an enforced API cap. Their evidence is
retained separately in `build/model-evaluation/xhigh-followup/`.

A fresh paired comparison then ran the same 18 frozen cases once at explicit
`high` and once at `xhigh`, alternating order, with no corrective feedback,
tools, repairs or retries. Both passed JSON/citation-ID validation in all
18 cases. Source review passed all 12 documentation/refusal answers at high
and 11 at xhigh; xhigh falsely claimed identical emitted code across target
architectures. Neither comparison requested `max`.

| measurement, 18 cases per effort | high | xhigh |
| --- | ---: | ---: |
| documentation/refusal pass | 12/12 | 11/12 |
| generated programs with requested runtime result | 6/6 | 6/6 |
| output tokens, including thinking | 21,564 | 36,932 |
| largest reported output | 2,393 | 4,003 |
| CLI wall time median / p95, seconds | 5.60 / 10.80 | 9.80 / 18.32 |
| hypothetical uncached API cost, total | $0.02861 | $0.03629 |

High used about 21% less estimated API cost and had about 43% lower median
CLI wall time, with no observed documentation quality loss. Every response
fit 4,096 reported output tokens, but the CLI did not enforce that cap.
The p95 is the sample maximum for this small sample. Timings include Claude
Code and subscription routing; costs apply published API rates to reported
tokens, not paid API charges. The paired raw answers, source review and
12 unchanged generated programs are retained separately in
`build/model-evaluation/haiku-effort-comparison/`.
All 12 programs compiled and returned their requested results in the same
bounded native Docker diagnostic described above, without repairs or retries.
High was faster in all 18 pairs; the median paired xhigh-minus-high wall-time
offset was 2.96 seconds. This differs from subtracting the aggregate medians.

A subsequent three-request direct API smoke used the actual service's high,
adaptive-thinking and hard 4,096-token profile. Targets, concurrency and a
requested GCD program returned complete validated responses in 4.30, 5.23
and 8.88 seconds. Reported output was 863, 1,000 and 1,808 tokens, including
thinking; reconciled cost totaled $0.004583. All three displayed transcripts
were persisted and privately exported without server secret values. These
three requests test the deployed request shape locally, not a general quality
or latency guarantee. The unchanged GCD source also compiled and returned 21
in one run of the same UID 65017 native Docker diagnostic; it did not rebuild
the compiler or verify Cloudflare execution. Raw evidence is retained in
ignored `build/api-smoke-20261008/`.

## Cost and abuse boundaries

The application's model API budget is $70 per UTC calendar month. One shared
Durable Object books a worst-case reservation before each operation, atomically
with rate and concurrency limits. It stays the same across source snapshots
and redeployments. A successful response reconciles the reservation against
the provider's reported usage. Chat turns reserve all four possible calls
up front and reconcile their combined usage. An uncertain provider failure
retains that whole turn reservation; unused calls are refunded when billing is
known. Internal model calls do not consume extra visitor answer quotas; every
sandbox attempt consumes the separate execution quota. A failure with uncertain billing retains the
reservation; expiry only releases a concurrency slot. There is no automatic
provider retry, and duplicate settlement cannot refund twice.

The reservation covers Haiku 5.5's entire one-million-token context at the
published higher input rate and 4,096 output tokens at its higher output
rate. Normal prompts are much smaller. Prices and the model are fixed
together in `src/policy.js`, using the
[October 2026 announcement](https://www.anthropic.com/claude-haiku-5-5).
This spending boundary depends on those provider prices and limits staying
valid. A separate Claude Console workspace with a $70 spend limit is the
provider-side backstop; provision its key only after setting that limit.
Do not delete the Durable Object namespace or rename the Worker to reset
quota state. Do not reuse the workspace key for other applications.

| operation | per visitor per minute | per visitor per day | service per day | simultaneous |
|---|---|---|---|---|
| answer / chat turn | 3 | 20 | 1,000 | 4 |
| documentation search | 10 | 50 | 1,000 | 4 |
| build and run | 2 | 5 | 200 | 1 |

Visitors are counted through a daily rotating HMAC of Cloudflare's connecting
IP, using `RATE_SALT`. Raw IPs are not saved by the application. The ledger
retains counts and reservations; the private transcript store below retains
submitted content. Shared IPs
share limits; changing IP can bypass a visitor quota but cannot bypass
service quotas or the model budget. Private documentation search also requires the preview key, preventing
anonymous callers from filling the transcript store. Public access requires
server-validated Turnstile tokens with the expected hostname and operation.
These controls bound abuse; they do not promise that abuse is impossible.

The Cloudflare execution admission budget is a separate $5 per UTC month. Each
job books $0.002 before a container can start; successful jobs and ambiguous
failures keep the booking. At most 2,500 jobs fit in a month, before daily and
visitor limits. The booking conservatively covers a 45-second attempt with
one vCPU, 1 GiB memory and 4.096 GB disk at the reviewed container rates. It
is an admission counter, not reconciliation against a provider invoice.
Changing resources, deadlines or provider rates requires reviewing it.

Containers require the **Workers Paid plan**, starting at $5/month plus
usage. Container CPU/memory/disk, network, paid Worker requests, Durable
Objects, registry storage and optional logs have their own billing terms.
The $70 API budget and $5 execution admission budget do **not** cap all those
charges, taxes or the base plan. Rejected requests can still invoke a paid
Worker. Cloudflare budget alerts do not stop spending; announced hard caps
must be verified in the actual account before relying on them. Static assets bypass Worker execution; API requests
remain billable even when rejected. Authentication and admission quotas reduce
exposure but are not an account-wide invoice cap. See
[container pricing](https://developers.cloudflare.com/containers/platform/pricing/),
[Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/),
[budget alerts](https://developers.cloudflare.com/billing/manage/budget-alerts/)
and the [hard-cap announcement](https://blog.cloudflare.com/enterprise-for-all-update/).
Do not publish the paid service as having a guaranteed total dollar ceiling
unless the provider enforces one for every enabled billable product.

The search/answer-only configuration in `wrangler.jsonc` can remain on
Workers Free. Its limits reject excess usage instead of billing overages.
Verify cold and representative queries within its 10 ms CPU limit. The
container configuration sets a 25 ms paid Worker CPU limit per invocation;
that limits individual work, not the number of billable invocations.
An attacker can exhaust quotas and deny service; GitHub Pages remains available.

## Private transcripts

Every valid documentation-search submission and authenticated question or
execution submission is saved in the existing budget Durable Object's SQLite
storage. Records contain the input, timestamp, random conversation identity,
corpus identity, fixed model profile, displayed response or error, usage and
accounting result. Chat records also retain the submitted workspace source,
model-call usage and each documentation/tool step, exact executed source and
bounded result. Step intent is persisted before work, and result before the
next model call; interrupted turns can retain partial progress. Generated examples and execution output remain untrusted.
Headers, API/preview/administrator keys, Turnstile tokens, raw IPs and provider
thinking are not copied into records. Visitors are told before submitting
that transcripts are stored to improve the assistant, and to avoid private code.

An input record must be persisted before calling the model or sandbox. A
completion record must be saved before delivering an answer. Interrupted work
can leave a `pending` record; that is evidence of an incomplete operation,
not a completed answer. Storage failures pause new answers, with no logging
retry or additional model call. Authentication failures and invalid bodies
are rejected without recording their headers or contents.

SQLite-backed Durable Objects include 5 GB of stored data on Workers Free,
with daily operation quotas. Exceeding Free limits rejects operations instead
of charging overages. The same storage has different billing on Workers Paid;
do not treat its included allocation as a paid-account spending ceiling.
See [Durable Object pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/).
Records are retained without automatic expiry. Export periodically before
storage fills; there is no automatic deletion or reset of the budget namespace.

The `GET /api/transcripts` export requires `X-Admin-Key`, has five records per
page and uses a numeric cursor. Responses are not cached. The supplied exporter
reads the secret file, refuses redirects and writes a private JSONL file:

```sh
python3 docs/site/ask/export_transcripts.py \
  --url https://YOUR-WORKER.workers.dev \
  --output docs/site/ask/build/transcripts-20261008.jsonl
```

Review exports for failures and useful new evaluation questions, verify their
answers against maintained sources, then update `evaluation.json` or the
retrieval/prompt deliberately. Visitor statements do not become authoritative
documentation and transcripts do not automatically retrain the model.

## Cloudflare execution

Use a Linux x86-64 compiler from a checked build of this checkout's compiler
revision, with its recorded SHA-256. Native builds and image checks belong
on the Linux x86-64 development host; they never execute visitor code on a
development or CI machine. The image preparer verifies the executable hash,
architecture and compiler/core revision before packaging it. It contains only
the checked executable, public core modules, pinned toolchain and launcher.
It does not copy Ada compiler sources or invoke a compiler build.
Documentation and service changes can reuse the checked compiler when its
compiler/core tree is identical; a newer whole-repository commit alone does
not force another compiler build. The configuration generator rejects a
context whose launcher differs from the current reviewed helper files.

From the repository root, prepare a new ignored context and configuration:

```sh
python3 docs/site/ask/runner/prepare_image.py --cloudflare \
  --refine /path/to/checked/refine --sha256 CHECKED_COMPILER_SHA256 \
  --commit CHECKED_SOURCE_COMMIT --output docs/site/ask/build/container
python3 docs/site/ask/runner/configure_cloudflare.py \
  --context docs/site/ask/build/container
```

On a host without native x86-64 Docker, validate Worker packaging without
building or updating the image:

```sh
cd docs/site/ask
npx wrangler deploy --dry-run --containers-rollout=none \
  --config build/wrangler.containers.json --outdir build/container-bundle
```

Image builds run on the native host. An already checked native image can be
loaded and pushed from a coordination host without executing it, using
`npx wrangler containers push LOCAL_IMAGE_TAG`. Retain the archive, config,
manifest and registry digest identities. Pass its digest-pinned reference to
`configure_cloudflare.py --context CHECKED_CONTEXT --image REGISTRY_DIGEST`
to deploy without another image or compiler build. The context and current
launcher checks still apply; never substitute an unverified registry image.

The generated `build/wrangler.containers.json` preserves the Worker name,
budget namespace and existing SQLite migration, adds the execution class,
uses one fixed named execution Durable Object and sets `max_instances=1`.
The provider image is pinned by deployment. The default scheduling policy
keeps ordinary process permissions: the newer Durable Object scheduling
policy currently gives processes root capabilities regardless of their UID,
so it is deliberately not used. See the
[container API's user restriction](https://developers.cloudflare.com/containers/api/durable-object-container/#exec).

The trusted controller starts as root inside the disposable microVM. Each
compiler/program child drops to UID/GID 65532 with no capabilities or
privilege gains. The controller can terminate those children; they cannot
signal or modify the controller. Compiler and launcher files are root-owned.
The children have 512 MiB address-space limits, 64 processes, 64 open files,
16 MiB per-file limits and no core dumps. Compilation gets 15 seconds, the
program gets two seconds, and combined output is limited while reading.
Writable disk is disposable; it is not claimed to be read-only or tmpfs.

The Worker and controller each request a 45-second outer deadline. A durable
alarm survives Worker restarts and destroys the instance; an inactivity
fallback stops abandoned instances too. Idle timeout is not the job deadline.
The controller accepts one job, then exits. The Durable Object destroys the
entire instance and verifies destruction before reopening its slot. Failed
cleanup retains a persistent closed slot and the alarm retries destruction
only. Restart discards any old job; no files, snapshots or processes are
restored for another visitor. Internet access is explicitly disabled; no
credentials, Worker bindings, host mounts or visitor-selected commands,
images, instance sizes or URLs enter the microVM.

Deployment validation must cover returning code, syntax errors, infinite
loops, output flooding, allocation and process pressure, network/credential
access, concurrent requests, cancellation/restart and verified destruction.
Local Docker image checks prove the packaged launcher and native compiler,
not Cloudflare's deployed microVM boundary, alarms, scheduling or billing.
Keep execution disabled until the deployment controls pass privately.

## Optional fixed-server fallback

The following older launcher remains available as an alternative to
Cloudflare Containers; it is not needed for the selected deployment.
Its fixed monthly VM bill is separate from the API budget, and provider
traffic terms still need review. No VM is provisioned automatically.

### Isolated execution VM

Use a dedicated, disposable Linux x86-64 VM, for example Debian 13 with two
vCPUs and 4 GiB RAM. Give it no access to development machines, CI runners,
private repositories or other workloads. Keep the Anthropic key on the
Worker; the VM receives only a separate runner bearer key. Sandbox jobs
receive neither key. A sandbox cannot be an absolute guarantee against an
escape; this VM must be replaceable, patched and isolated even if compromised.

Install Docker and [gVisor's `runsc`](https://gvisor.dev/docs/user_guide/quick_start/docker/)
on that VM. Verify the installed executable and Docker runtime configuration
from the host; text printed by a container is not proof of its runtime.
Only `runsc` is selected by the launcher, with no fallback to the default
shared-kernel container runtime.

Prepare an image context with a Linux x86-64 compiler from a checked artifact
for the same source revision as the documentation and core modules. Supply
its recorded hash; the preparer verifies it and never downloads an unverified
compiler. From the repository root, with a fresh output directory:

```sh
python3 docs/site/ask/runner/prepare_image.py \
  --refine /path/to/checked/refine \
  --sha256 CHECKED_COMPILER_SHA256 \
  --output /tmp/landin-ask-image
. ./environments/pins.sh
docker build --build-arg BASE_IMAGE="$LANDIN_BASE_IMAGE" \
  -f /tmp/landin-ask-image/Containerfile \
  -t landin-ask-runner /tmp/landin-ask-image
docker image inspect --format '{{.Id}}' landin-ask-runner
```

The image uses the repository's existing toolchain pins, contains the checked
`refine` and public core modules, and has an immutable local image ID. No
compiler build occurs during a visitor request.

Provision the VM service environment with `RUNNER_IMAGE` set to that full
`sha256:` image ID, `COMPILER_SHA256` set to the checked compiler's hash,
`RUNNER_KEY` set to a strong random secret, and `RUNNER_STATE` set to a private
persistent directory. Install `server.py` and `container_entry.py` into
`/opt/landin-ask` and use `runner/landin-ask.service` as the supervised service.
Create its `landin-runner` account and store the environment in a protected
`/etc/landin-ask/runner.env` file. The unit owns its private persistent state
directory and binds the Python listener to loopback.
Keep the quota SQLite database across restarts. Docker access is host-level
authority: restrict the service account and expose neither Docker nor the
Python listener publicly. Put a TLS reverse proxy in front of its loopback
listener; `runner/Caddyfile.example` shows the route and body limit. Apply a
host firewall and provider traffic protection before public use.

Every job gets a fresh non-root gVisor sandbox, a read-only root filesystem,
no network, no host mounts, no credentials and two small temporary filesystems.
The job has one CPU, 512 MiB memory without additional swap, 64 processes,
15 seconds to compile, two seconds to run, and a 25-second outer time limit.
Source is capped at 8 KiB and combined diagnostic/program output at 12 KB.
Program stdin is closed. Compiler arguments and the module/file names are
fixed by the launcher; text goes through stdin as JSON data, never a shell.

The host bounds Docker's output while reading it, removes the container after
every attempt, verifies cleanup, and keeps its own persistent 200-job daily
quota. Cleanup uncertainty keeps the job slot closed. Startup refuses if
old labelled sandboxes remain. Do not restart past that refusal before
inspecting and removing the owned leftovers.

On the isolated VM, verify a returning program, a syntax error, an infinite
loop, output flooding, allocation exhaustion, fork pressure, network denial,
host-file denial, concurrent requests and cleanup after cancellation/restart.
Retain the compiler and image identities, commands, statuses and bounded
outputs. These are sandbox controls, not a claim that hostile code can never
escape. Until that evidence exists, keep `EXECUTION_ENABLED=false`.

## Private deployment and public launch

Wrangler authentication is separate from an Anthropic API key. Answer-only
deployment can use Workers Free; Containers needs Workers Paid. Both need these Worker
secrets, supplied through `npx wrangler secret put NAME`: `ANTHROPIC_API_KEY`,
`PREVIEW_KEY` and `RATE_SALT`. No secret is an ordinary Wrangler variable.
For answer-only use, review and commit the deployment inputs, then run
`npm run deploy`. For Containers, first build and check the prepared image on
the native host, review the paid account's billing controls, review and commit
deployment inputs, then explicitly run:

```sh
cd docs/site/ask
python3 build.py --release
npx wrangler deploy --config build/wrangler.containers.json
```

The generated configuration starts private with execution disabled. Enable
`EXECUTION_ENABLED` there only for the bounded private deployment checks,
then review results before public launch. The Worker serves the preview at its own `workers.dev`
URL; this does not change the public Landin website or publish the backend
through the Pages workflow.

For the optional VM fallback, set the tested VM's HTTPS `/run` URL in `RUNNER_URL`, supply its separate
`RUNNER_KEY` through Wrangler secrets, and enable execution privately only
after the sandbox controls pass. For public access, configure a Turnstile
widget for the preview/site hostnames, set `TURNSTILE_SITE_KEY`, supply
`TURNSTILE_SECRET_KEY`, and change `PRIVATE_MODE=false`. Add the public entry
to the reading copies only when the private evaluation and deployment are
reviewed. Publication of those pages remains the existing Pages workflow.

The administrator-only `GET /api/execution/status` endpoint accepts `X-Admin-Key`
and reports the execution slot, durable job deadline and provider container state.
It never starts a container. Verify an empty slot, no durable job and no running
container after private attempts; a preview key cannot access this endpoint.

The private `/api/budget` endpoint accepts `X-Preview-Key` and reports the
current month's API and execution bookings, active reservations and pause status.
It remains protected in public mode. Set `ANSWERS_ENABLED=false` and redeploy
to stop answers and execution; documentation search still works. Set
`EXECUTION_ENABLED=false` to stop execution alone. If access or a secret is
compromised, revoke the relevant provider key and stop the execution service as
needed. Requests already in progress may finish, with their costs reserved.
