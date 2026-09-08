# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current portable parallel candidate timings came from the 2026-07-29 concurrent proof recorded in [fm-test-isolation-proof.md](fm-test-isolation-proof.md).
The proof ran 24 candidates with four workers and no failures.
The current portable serial shard timings came from the uploaded `fm-test-timing-portable-serial` artifact in main run 34169543250 for commit 775500ab08ed05ccef73fc99444608bc300cc314.
The tracked copy at [fm-test-portable-serial-timing.json](fm-test-portable-serial-timing.json) is the single measured-duration input for portable serial shard assignment.

| duration_ms | script |
|---:|---|
| 52939 | `tests/fm-x-mode.test.sh` |
| 48294 | `tests/fm-backend-herdr.test.sh` |
| 46788 | `tests/fm-arm-pretool-check.test.sh` |
| 34207 | `tests/fm-cd-pretool-check.test.sh` |
| 30771 | `tests/fm-decision-hold-lifecycle.test.sh` |
| 25365 | `tests/fm-crew-state.test.sh` |
| 15674 | `tests/fm-test-run.test.sh` |
| 15422 | `tests/fm-herdr-lab.test.sh` |
| 9065 | `tests/fm-composer-ghost.test.sh` |
| 8564 | `tests/fm-pr-merge.test.sh` |
| 6251 | `tests/fm-grok-harness.test.sh` |
| 5644 | `tests/fm-send-popup-settle.test.sh` |
| 5237 | `tests/fm-lint.test.sh` |
| 4816 | `tests/fm-tmux-submit-busy.test.sh` |
| 2945 | `tests/fm-pi-primary-types.test.sh` |
| 2911 | `tests/fm-send-settle.test.sh` |
| 2875 | `tests/fm-review-diff.test.sh` |
| 2747 | `tests/fm-send-strict.test.sh` |
| 2224 | `tests/fm-brief.test.sh` |
| 855 | `tests/fm-spawn-batch.test.sh` |
| 703 | `tests/fm-supervision-instructions.test.sh` |
| 581 | `tests/fm-ensure-agents-md.test.sh` |
| 248 | `tests/fm-transition-lib.test.sh` |
| 64 | `tests/fm-composer-lib.test.sh` |

## Parallel lanes

The two parallel lanes use longest-processing-time assignment from those measured durations.

| Lane | Script count | Estimated duration |
|---|---:|---:|
| `portable-parallel-1` | 11 | 162436 ms (~162.4 s) |
| `portable-parallel-2` | 13 | 162754 ms (~162.8 s) |
| imbalance | | 318 ms |

`bin/fm-test-run.sh` contains the exact ordered memberships in `list_portable_parallel_1` and `list_portable_parallel_2`.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, live-harness opt-in, GUI-backend, and other unproven work serial.
CI runs that remainder as `portable-serial-1` and `portable-serial-2`.
Those two lanes are generated with longest-processing-time assignment from [fm-test-portable-serial-timing.json](fm-test-portable-serial-timing.json), not from hand-maintained lane lists.
Assignment is pure `awk` over the artifact, so lane listing and the coverage guard stay portable on hosts without `python3`.
New serial-remainder tests with no recorded duration still land automatically in one serial shard, and the budget guard catches timing drift after they run.

### Before and after

Before this split, the whole remainder ran as one `Behavior portable serial` job against a 20-minute timeout.
The tracked artifact records `summary.duration_ms` 1143564 for that single lane, and the job wall clock on main runs 34169543250, 34165091768, and 34162488434 was 19m13s, 19m17s, and 19m43s - roughly 96% of the budget, with cancellation rather than a test failure as the next outcome.

| Lane | Script count | Duration | Share of 20 min |
|---|---:|---:|---:|
| `portable-serial` (before) | 68 | 1143564 ms (~19.1 min), job wall 19m13s | ~96% |
| `portable-serial-1` (after) | 33 | 570780 ms (~9.5 min) | ~48% |
| `portable-serial-2` (after) | 35 | 570767 ms (~9.5 min) | ~48% |
| imbalance | | 13 ms | |

The after figures are the shard sums generated from run 34169543250 durations, not a fresh measurement; the budget guard re-checks each shard's real measured duration against its budget on every run.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that:

- both parallel lanes partition the proven-isolated set;
- the two generated serial shards are disjoint and their union equals the `portable-serial` remainder;
- the parallel lanes, both serial shards, and the real-Herdr family are disjoint and cover every `tests/*.test.sh` script.

## Refreshing the serial timing artifact

When the budget guard reports timing drift, or the serial shards have absorbed enough unmeasured tests to skew, replace the measured-duration input:

1. Take a green main run and download its `fm-test-timing-portable-serial-1` and `fm-test-timing-portable-serial-2` artifacts.
2. Merge them with `bin/fm-test-run.sh --aggregate-json <out>`, or run `bin/fm-test-run.sh --lane portable-serial --json <out>` locally for a single-lane artifact. Shard assignment reads only the `scripts[].path` and `scripts[].duration_ms` rows, so either shape works.
   The parser validates the whole document, so an artifact that is malformed, reshaped away from a top-level `scripts` array, missing a `path` or numeric `duration_ms`, nesting a container inside a `scripts[]` entry, or carrying an empty script list makes lane listing and `--check-coverage` refuse with exit 2 and a concrete reason instead of silently producing a degraded partition.
3. Copy the result over [fm-test-portable-serial-timing.json](fm-test-portable-serial-timing.json), commit it, and update the Verification inputs run id plus the after rows of the Before and after table with the new shard sums. The before row is the historical baseline for this split and stays as recorded.
4. Confirm the reassignment with `bin/fm-test-run.sh --check-coverage`.

## Timing artifacts

Portable shards, the portable serial lanes, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts and budget guard

| Job | timeout-minutes | Guard threshold | Rationale |
|---|---:|---:|---|
| portable parallel 1/2 | 10 | 7.5 min | The measured shard sums are about three minutes and the timeout is a hang tripwire. |
| portable serial 1/2 | 20 | 15 min | The measured serial shards are about 9.5 minutes each and the timeout is a hang tripwire. |
| Herdr | 40 | 30 min | The real-Herdr lane keeps its dedicated timeout. |

Timeouts are hang tripwires rather than expected healthy durations.
The CI test-lane guard fails when a timing artifact exceeds 3/4 of the job's timeout budget.
`bin/fm-test-run.sh --ci-budget-fraction` is the single owner of that fraction, and `bin/fm-ci-budget-guard.sh` enforces it in the workflow.
The per-job budget stays single-owned too: workflow steps call the guard with the timing artifact only, and the guard reads `timeout-minutes` for the running `$GITHUB_JOB` out of the workflow file, so raising a job's timeout moves its guard threshold with it.
An explicit `fm-ci-budget-guard.sh <timing-json> <timeout-minutes>` second argument remains for local runs outside GitHub Actions.
