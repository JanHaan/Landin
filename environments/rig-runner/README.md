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
being run, with no pull request in its environment or event payload. A
refused job fails before its first step, so none of the repository's code
runs on the rig. `completed` removes the job's workspace.

The deployed copy is in the maintainer's NixOS configuration, outside the
runner's directory and every checkout. A change here reaches the rig only
when the maintainer deploys it, and the two copies must stay identical.
`scripts/tests/test_rig_runner_hook.py` holds the rules to simulated pushes,
schedules, dispatches, pull requests and forks:

```sh
python3 scripts/tests/test_rig_runner_hook.py
```
