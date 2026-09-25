---
name: jev-routing
description: >-
  Agent-only routing rule for bounded, closed-outcome decisions.
  Load before deciding whether such a decision should be answered by a model call through bin/fm-jev.sh rather than by reasoning.
  Owns the routing test, the refusal list, the composition rule, the degradation path, and the calibration loop.
user-invocable: false
metadata:
  internal: true
---

# jev-routing

This skill is the single owner of when a decision goes to Jev instead of a reasoning model.
`bin/fm-jev.sh --help` owns the call mechanics, the credential path, and the fail-closed contract.
The `typesafe-jev` skill owns the request and answer shapes, the question types, and the Score-criteria-is-an-array trap; read it before writing questions and do not restate it here.
`AGENTS.md` sections 1, 7, and 9 own authority, delivery, and escalation, and nothing here changes them.

Jev is a System One decision model.
It answers typed questions over a state and returns calibrated probabilities.
It does not generate text, use tools, or reason in steps.
The point of routing to it is that a bounded classification stops consuming a frontier reasoning model: this home measured about 214 ms and roughly a hundredth of the per-call cost against seconds on a reasoning model.

## The routing test

Route to Jev only when all of these hold.

1. The outcome set is closed and known before the call.
2. The inputs are text or JSON already available at decision time.
3. No tool use, retrieval, or multi-step reasoning is needed to answer.
4. The caller can act on a probability against a threshold the caller owns.
5. Either the volume or the latency matters, or the decision currently costs an agent turn.

Any one of those failing sends the decision back to the reasoning path.
This is a routing rule, not a conversion mandate: convert one decision at a time, each with its own measured calibration.

## Never route to Jev

- The answer is prose.
- The option set is not known up front.
- Answering needs tools or investigation.
- The decision is the final word on anything destructive, irreversible, security-sensitive, or a merge.

Jev may pre-screen that last class - triaging, ordering, or flagging candidates for a reasoning model or the captain.
It never closes it.
A probability is evidence, never authority, and never satisfies an approval boundary that `AGENTS.md` places with the captain or with firstmate's configured authority.

## Compose, do not classify

This is the load-bearing rule.

Decompose the decision into narrow questions and ask them together over one state.
Independent questions run in parallel against one ingestion of the state and cannot see one another's answers, so the composed form costs one request.
Then keep the policy and its thresholds in code, where they can be read, changed, and tested without re-running inference.

Do not ask one broad classifier to encode the policy.
A single question that already contains the weighting, the exclusions, and the escalation rule buries all of them in an opaque probability.
On the same request, this home measured the composed form nine points more accurate than the single classifier.

A weight, a threshold, or a display filter that changes must not require new inference when the evidence and the question meanings are unchanged.
If it does, the policy leaked into the questions.

## Degradation

When `bin/fm-jev.sh` fails for any reason, the caller falls back to the reasoning path and says so in its report.
The helper refuses loudly and prints no answer precisely so this stays possible: absence has exactly one meaning, which is no answer available.
A failed classifier never silently becomes a default answer, and a missing answer is never read as a negative one.

## Watcher shadow calibration

The declared-wait recheck observer is **shadow only**: it records Jev evidence without changing any wake the watcher surfaces.
`bin/fm-watch-jev.sh --help` owns its eligible snapshot, bounded-call configuration, provisional thresholds, simulated consecutive-absorb bound, and private audit artifacts.
There is no suppression switch; enabling suppression requires a separate code change and explicit captain approval based on the recorded wake-triage shadow outcomes.
The review-authority benchmark below is not evidence that absorbing supervision wakes is safe: a missed escalation is the dangerous error for this decision.
The observer's audit records the provider-returned usage and cost of each observed wake exactly as returned, with absent and malformed fields marked rather than estimated, so wake spend is measured rather than extrapolated from a benchmark.
`tests/fm-watch-jev.test.sh` verifies the observer and the unchanged watcher surface without network calls.

## Calibration

Thresholds are set against recorded outcomes for that specific decision, never carried over from another decision, a cookbook, or a demo number.
The response's `model` field is in the helper's output for this reason: re-check the thresholds when that version changes, because an alias can move under a calibrated threshold.

The worked example of that loop is this home's private `data/jev-evaluation/`, which measured 23 real review-authority decisions taken from this repository's own records: 87 percent agreement with the recorded outcome and zero missed escalations.
Read it before calibrating a new decision, because it also records the correction that mattered most.
The first version of the security question conflated security subject matter with security consequence, so a decision that merely discussed security scored like one that carried security risk.
Rewording the question fixed it.
When agreement is poor, suspect the question wording before the model: inspect the exact state, questions, answers, and composition, and separate a missing-evidence failure from a model failure from a code failure.
