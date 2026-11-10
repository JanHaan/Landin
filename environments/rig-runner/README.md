# The rig runner's job hooks

The gate's physical board jobs run on a self-hosted GitHub Actions runner on
rigpi, labelled `landin-rig`. This repository is public, and a pull request
from a fork runs the workflow files of its own merge commit, so no `if:` in
`.github/workflows/gate.yml` can keep that pull request off the runner: it
can delete the condition, or add a workflow that names the label.

[hook.py](hook.py) is the control the runner itself applies. The runner runs
`hook.py started` before each job it is assigned and `hook.py completed`
after it. `started` refuses every job except:

- a push to `refs/heads/main`;
- a schedule on `refs/heads/main`;
- a manual dispatch from a branch, by an allowed actor who also triggered
  the run.

Each of those must be a job of this repository's `gate.yml` at the ref
being run, with no pull request in its environment or event payload.
`completed` removes the job's workspace. It never fails a finished job: what
it could not remove it reports, and records as `kept` in its log.

## What a refusal does

A refused job must run none of its steps. The hook's nonzero exit fails the
job, but the runner runs the hook as a step of the job, and a later step
under `if: always()`, or the `pre:` entry of an action the job names, has a
condition that a failed earlier step can satisfy. So `started` does not
leave a refusal to step conditions:

1. It removes `_actions` beside the repository's work directory. The runner
   downloads every action a job names while it sets the job up, which is
   before the hook runs, so a refused job has already written there.
2. It finds the runner's worker process for the job among its own
   ancestors: the nearest one whose command name, or first or second
   argument, contains `Runner.Worker`.
3. It writes the reason to standard error, waits `--grace` seconds (two by
   default) so the worker can send that line to the job's log, and kills the
   worker with `SIGKILL`.

The worker is the process that evaluates each step's condition and runs the
step, and it waits for the hook meanwhile; once it is gone no step of the
job can run. The runner's listener, which started the worker, reports the
job failed and waits for the next job. When no ancestor is a worker, as
when the hook is run by hand, the hook says that only its exit status
refuses the job, and its log entry has `"worker": null`.

The deployed copy is in the maintainer's NixOS configuration, outside the
runner's directory and every checkout. A change here reaches the rig only
when the maintainer deploys it, and the two copies must stay identical.
`scripts/tests/test_rig_runner_hook.py` holds the rules to simulated pushes,
schedules, dispatches, pull requests and forks, and runs a refusal against a
stand-in worker that goes on to its next step after a failed hook:

```sh
python3 scripts/tests/test_rig_runner_hook.py
```

Those controls cannot show what the deployed runner does. After deploying a
change to the hook, push a branch whose `gate.yml` holds one job on
`[landin-rig]` with the single step `if: always()` and `run: echo ran`. The
job must fail without that step's output, the hook's log on the rig must
show the refusal with a `worker` that is a process number, and the next
trusted job must be taken by the same runner.
