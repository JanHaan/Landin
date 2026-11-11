"""The environment a script test runs git in for a temporary repository.

Git 2.54 starts `git maintenance run --auto --detach` after every commit.
On a loaded host one was still at work under .git when a case's cleanup
removed the repository, which then failed with "Directory not empty: .git".
Every test that commits in a temporary repository therefore runs git with
`environment()`, which turns that maintenance and the older automatic
collection off, gives the commit an author so no global configuration is
needed, and signs nothing.  scripts/tests/test_temporary_git.py holds the
tests to it: a module that passes git a commit and does not import this
one fails there.

    from temporary_git import environment
    subprocess.run(["git", "commit", "-q", "-m", "x"], cwd=repository,
                   env=environment(), check=True)

The settings travel in GIT_CONFIG_COUNT and its keys, so a process the
test starts, a build script that commits or a tool that reads the
repository, inherits them when it is given the same environment.
"""
import os

SETTINGS = (("maintenance.auto", "false"), ("gc.auto", "0"),
            ("commit.gpgsign", "false"), ("tag.gpgsign", "false"))

IDENTITY = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
            "GIT_COMMITTER_NAME": "t",
            "GIT_COMMITTER_EMAIL": "t@example.invalid"}


def environment(base=None, **more):
    """BASE, or the caller's environment, with the settings and MORE.

    Settings a caller already passes through GIT_CONFIG_COUNT are kept:
    these are numbered after them.
    """
    result = dict(os.environ if base is None else base)
    result.update(IDENTITY)
    try:
        count = int(result.get("GIT_CONFIG_COUNT", "0"))
    except ValueError:
        count = 0
    for key, value in SETTINGS:
        result[f"GIT_CONFIG_KEY_{count}"] = key
        result[f"GIT_CONFIG_VALUE_{count}"] = value
        count += 1
    result["GIT_CONFIG_COUNT"] = str(count)
    result.update(more)
    return result
