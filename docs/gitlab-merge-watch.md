# GitLab and Bitbucket merge watch verification

Empirical record for the merge watch on GitLab and Bitbucket Cloud, alongside the existing GitHub watch.
The GitLab command transcript below was run on 2026-07-21 and its output is reproduced exactly.
The Bitbucket Cloud behavior was added on 2026-09-08 and is covered by hermetic bkt JSON fixtures in `tests/fm-pr-check-security.test.sh` and `tests/fm-pr-merge.test.sh`.

## Versions

```
$ glab --version
Current glab version: 1.53.0

$ bash --version | head -1
GNU bash, version 5.3.9(1)-release (x86_64-pc-linux-gnu)
```

## The evidence project

All live evidence here reads <https://gitlab.com/KarotKris/gitlab-merge-watch-fixture>, a public project that exists only to be this evidence.
It holds one deliberately merged merge request and one deliberately open one, so both outcomes can be shown against real data.
Every command against it reads a public merge request and needs no credential, so a reader can rerun each one and see the same output.
Its README asks that the open merge request be left open.

A non-default host appears below only as the placeholder `gitlab.example`, which resolves nowhere.
That is deliberate: the host-agnostic property is a property of the stored record and the poll's URL reconstruction, so it is demonstrated by inspecting those rather than by reaching any private instance.

## Why the host is data rather than a constant

GitLab runs mostly on self-hosted instances, so a merge request can live under any host.
A GitLab project also sits under at least one group at no fixed depth, so no owner-and-repository pair can address one the way it can on GitHub.
The stored record therefore carries `provider`, `url`, `host`, `path`, and `number`, and every consumer rebuilds the URL from those parts and refuses any record that does not reconstruct the stored URL exactly.
`tests/fm-pr-check-security.test.sh` asserts that neither `bin/fm-pr-lib.sh` nor `bin/fm-pr-poll.sh` contains the string `gitlab.com` at all.

## How plain glab is invoked, and why

Two things about plain `glab` were established by running it, because assuming either one would have failed silently into a permanent "not merged".

First, plain `glab` has no field selector.
`gh` reads one field with `--json state -q .state`; `glab mr view` offers only `-F, --output string  Format output as: text, json`.
Its JSON would need a JSON processor, and `jq` is not one of firstmate's common tools, so the state is read from glab's own field output instead.
Only an exact `merged` wakes firstmate, so a changed output format produces no wake rather than a false merge.

Second, `glab` cannot take a merge request URL the way `gh pr view` can.
That form shells out to git for the current repository, and the watcher runs in no repository:

```
$ cd /tmp && glab mr view https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
fatal: not a git repository (or any parent up to mount point /)
Stopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).
git: exit status 128
```

Passing the project URL to `-R` with the merge request number works from anywhere, and resolves the instance from that URL rather than from glab's configured default:

```
$ cd /tmp && glab mr view 1 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture
title:	Add the merged example file
state:	merged
author:	KarotKris
labels:	
assignees:	
reviewers:	
comments:	0
number:	1
url:	https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
--
This merge request is the merged half of the fixture. It is merged on purpose, so that reading its state returns merged.

$ cd /tmp && glab mr view 2 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture | sed -n 's/^state:[[:space:]]*//p'
open
```

## End to end: arming and polling a real merge request

Three tasks were armed, two against the fixture and one against the placeholder host:

```
$ fm-pr-check.sh e1 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
armed: state/e1.check.sh
$ fm-pr-check.sh e2 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/e2.check.sh
$ fm-pr-check.sh e3 https://gitlab.example/group/subgroup/project/-/merge_requests/7
armed: state/e3.check.sh
```

The stored record for each, showing the host and the full project namespace as data:

```
$ cat state/e1.pr-poll
gitlab
https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
gitlab.com
KarotKris/gitlab-merge-watch-fixture
1

$ cat state/e3.pr-poll
gitlab
https://gitlab.example/group/subgroup/project/-/merge_requests/7
gitlab.example
group/subgroup/project
7
```

The provenance record for the non-default host, showing the bumped version tag:

```
$ cat state/e3.pr-poll-registration
fm-pr-poll-registration-v2
e3
gitlab
https://gitlab.example/group/subgroup/project/-/merge_requests/7
gitlab.example
group/subgroup/project
7
514b7e04f0cca3e2c913c9fd504c54dfe54c8a51a7f5ebc57279bbd4db5d4a60
1817b0f95db7148246434a4afa0b2c8e7b81fd8f74ef7d473bbd62023e47c439
70:957243
70:957244
```

Running each published poll the way the watcher does, where an empty result means the poll stayed silent and produced no wake:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
merged
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e2.pr-poll)
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

The merged fixture merge request produces exactly one `merged` line.
The open one produces nothing, and the unreachable placeholder host produces nothing rather than a false merge.

The same bytes work in the watcher's sidecar-driven mode, where the published check locates its own record:

```
$ state/e1x.check.sh
merged
```

## A missing CLI produces no wake, never a false merge

The poll is silent on every error by design, so a missing `glab` would otherwise be indistinguishable from a merge request that is never merged.
With `glab` removed from `PATH`, the poll stays silent even for the merge request that is genuinely merged:

```
$ PATH="$noglab" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
$ PATH="$noglab" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

Arming is the one point where that can be reported, so it refuses there instead of arming a watch that can never fire:

```
$ PATH="$noglab" fm-pr-check.sh e5 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
error: watching a GitLab merge request requires glab on PATH
$ echo $?
1
```

A GitHub task is unaffected by a missing `glab`:

```
$ PATH="$noglab" fm-pr-check.sh e6 https://github.com/kunchenguid/firstmate/pull/750
armed: state/e6.check.sh
```

## Upgrade path from an existing armed watch

The stored record gained the provider tag, so its version moved to `fm-pr-poll-registration-v2` and a record written by the previous release no longer parses.
The existing non-executing migration handles that: it never runs the old artifact, and rebuilds the poll from the task's recorded pull request URL.
Starting from a poll armed exactly as the previous release wrote it:

```
$ head -1 state/t1.pr-poll-registration
fm-pr-poll-registration-v1
$ fm-pr-check-migrate.sh --checks-safe
PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home
$ head -2 state/t1.pr-poll-registration
fm-pr-poll-registration-v2
t1
$ cat state/.pr-check-migration.log
task t1: migration outcome tracking started before legacy poll handling
task t1: canonical legacy poll rebuilt and armed
```

The rebuilt poll works, verified against a pull request that is genuinely merged:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/t1.pr-poll)
merged
```

No armed watch is lost by upgrading.

## Bitbucket Cloud pull requests

Bitbucket Cloud pull requests are accepted only in the canonical form `https://bitbucket.org/<workspace>/<repo>/pull-requests/<number>`.
`bin/fm-pr-lib.sh` is the single forge owner and parses that URL into the same provider-tagged sidecar fields as GitHub and GitLab: `provider`, `url`, `host`, `path`, and `number`.
The host is fixed to `bitbucket.org`, and `path` is the two-segment `<workspace>/<repo>` value.

The Bitbucket Cloud path uses `bkt` for all remote reads and writes.
The supported authentication shape is environment-backed, not keychain-backed.
The exact required environment is `BKT_HOST=https://bitbucket.org`, `BKT_USERNAME`, `BKT_TOKEN`, and `BKT_AUTH_METHOD=basic`.
If those variables are not already in the process environment, the scripts source `~/.config/firstmate/bkt.env` only when it is an ordinary mode-0600 file.
Secret values are never printed, stored in state, or copied into tests.

`bin/fm-pr-check.sh` refuses a Bitbucket watch before arming when `bkt` is absent, `jq` is absent, the required environment is absent or wrong, the pull request details cannot be read, or the full source commit hash cannot be resolved.
The refusal names the concrete missing requirement, for example `bkt on PATH`, `jq on PATH`, or the missing `BKT_*` variable names.
It never arms a silent poll when the authenticated Bitbucket context is missing.
If that environment disappears after arming, the poll emits `bitbucket-auth-missing: ...` with the missing variable names instead of silently skipping the check.

The Bitbucket poll first reads the pull request state through `bkt api /repositories/<workspace>/<repo>/pullrequests/<number> --json`.
A `MERGED` state emits `merged` and uses the same watcher retirement path as the other forges.
An open pull request reads the full source head through `bkt api /repositories/<workspace>/<repo>/commit/<hash> --json`, then reads attached build statuses through `bkt pr checks <number> --json --workspace <workspace> --repo <repo>`.
A fully successful set emits `green`.
A failed, stopped, cancelled, or errored status emits `red: <build name> <state>`.
Pending, running, unreadable, malformed, or absent statuses produce no readiness wake.
When no build status exists yet, the poll falls back to the latest source-branch pipeline from `bkt pipeline list --json --workspace <workspace> --repo <repo> --limit 20` and emits the same `green` or `red: pipeline <number> <result>` result only when that pipeline is terminal.
Only `merged` retires the poll, so `green`, `red: ...`, and `bitbucket-auth-missing: ...` all describe conditions that hold across sweeps.
The watcher surfaces such a line once and wakes again only when the emitted line changes, so a pull request left red does not wake firstmate every `FM_CHECK_INTERVAL`; this is the watcher's shared rule for every forge, not a Bitbucket special case.

`bin/fm-pr-merge.sh` merges Bitbucket Cloud pull requests through `bkt pr merge <number> --workspace <workspace> --repo <repo>` after first recording the same metadata through `bin/fm-pr-check.sh`.
The default Bitbucket merge strategy is `--strategy squash`, unless the caller passes an explicit `--strategy` after `--`.
Repository selector overrides such as `--workspace`, `--repo`, `--project`, and `-R` are refused because the repository identity comes only from the validated URL.

## What this change does not cover

`bin/fm-pr-merge.sh` still refuses a GitLab merge request URL rather than sending it to the wrong forge, so merging a GitLab merge request stays a deliberate manual step until merge parity lands separately.
Teaching no-mistakes to open Bitbucket pull requests is a separate no-mistakes change; it would need the same environment-backed `bkt` context available inside the no-mistakes run.

A GitLab task records no `pr_head=` or `landing_branch=`.
`gh` exposes the head commit and base branch as selectable fields, while plain `glab` exposes equivalent data only inside its JSON output, which would need a JSON processor firstmate does not require.
Both consumers already treat the head as optional: `bin/fm-teardown.sh` reads it from the forge at teardown and falls back to its content check, and `bin/fm-review-diff.sh` resolves the head from the remote when none is recorded.
For a GitLab merge request aimed away from the default branch, pass `fm-teardown.sh --landing-branch <branch>` so the content check compares against the directed branch.
