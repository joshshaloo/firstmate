---
name: standup
description: >-
  Run the captain's standup: what shipped in a time window, what is in progress, what is next, and what is blocked, across every project firstmate controls.
  Use when the captain invokes /standup, or asks for a standup, a stand-up, a daily, a 15-minute check-in, "what shipped this week", "what shipped in the last 48 hours", or "what have we shipped and what is stuck".
  /standup defaults to a 72-hour window and accepts an explicit window (/standup 48h, /standup 24h, /standup 1w) and an optional single-project scope (/standup envy-forge).
  Not for "where did I leave off", a morning brief, a catch-up, or a resume digest - that is /bearings.
user-invocable: true
metadata:
  internal: true
---

# standup

Give the captain a spoken standup: what actually reached users lately, what is moving now, what is next, and what is stuck.
It is a meeting, not a digest.
The report is read in about two minutes so the rest of the quarter hour is discussion, which is why every section is short, ranked, and written in the captain's own nouns.

## How this differs from /bearings

Keep both skills; they answer different questions and must never be merged.

- `/bearings` answers **"where do I resume"** from CURRENT state.
  Its Recently Landed list is a count-bounded baseline, not a time window, and it renders as a digest to be read.
- `/standup` answers **"what happened lately, what now, what next, what is stuck"** over an explicit TIME WINDOW, and it is spoken to a human in a meeting.

The practical consequence is the Shipped section.
A resume digest can say "these completions are in the current baseline"; a standup cannot, because the captain is asking about a period, and backlog Done retention is count-bounded (`.tasks.toml` `done_keep`), so the live queue alone cannot answer even 72 hours.
That is why this skill has its own time-windowed reader and Bearings does not.

## Invocation

- Plain `/standup` uses a 72-hour window across every registered project.
- `/standup 48h`, `/standup 24h`, `/standup 1w`, `/standup 7d` set the window; the reader accepts `<N>h`, `<N>d`, and `<N>w`.
- `/standup <project>` restricts every section to one registered project, and composes with a window: `/standup 48h envy-forge`.
- Treat a window token and a registered project name as the ONLY invocation options.
  Do not read a natural-language request such as "just the last two days" or "only the forge work" as an option unless the standalone token was actually typed; ask one short question instead when it matters.
- Chat is the only surface.
  There is deliberately no board mode: the standup is a two-minute read the captain answers by talking, and `/bearings lavish` already owns the interactive surface for acting on open items.
  When the captain wants to click through decisions after the standup, offer `/bearings lavish` rather than building a second board.

## What it does

1. **Gather time-windowed shipped evidence with one deterministic command.**
   Run `shipped=$(bin/fm-standup-shipped.sh --window <spec> [--project <name>] --include-deploy --fields bodies)`.
   Its header and `--help` own its fields, bounds, window argument, sources, and output contract.
   Add `--include-forge` when a project's local copy is reported stale, so merges it has not picked up are still counted.
   Do not write a second reader for this, do not scrape reports or conversation history for it, and do not date shipped work from anything but the evidence it returns.

2. **Gather current fleet state with the existing snapshot.**
   Run `snapshot=$(bin/fm-bearings-snapshot.sh --json)` and take sections 2, 3, and 4 from it: `in_flight`, `gates`, `decisions_open`, and `unhealthy_endpoints`.
   This is the same single deterministic fleet-state source Bearings uses.
   Never add a second reader for current state, never interpret raw status-event tails, and never substitute conversation memory for it.
   **Known dependency:** on a home whose backlog has grown large, this command currently fails with an argument-limit error out of `bin/fm-fleet-snapshot.sh` (tracked separately as `firstmate-fleet-snapshot-jq-arg-limit`).
   When it fails, do NOT work around it and do NOT fall back to a hand-rolled reader.
   Render Shipped from step 1, then say plainly in one line that the current-state reader is broken so in progress, next up, and blockers cannot be reported yet, and name the fix that is already queued.

3. **Compose the four sections.**
   The gathering is deterministic; your judgment is ranking what matters and writing it in the captain's words.

## The four sections, in the captain's order

Every section always renders, in this order, each with an honest empty state.
Bound each to about five to seven items and disclose the rest as "and N more" rather than dumping the list or silently truncating it.

### 1. Shipped

What actually reached users inside the window.
The captain's standing rule is that done means deployed AND verified, never merged, so this section separates three states per item and never blurs them:

- **Merged, not yet deployed** - the reader returned `no`, meaning it read the deploy evidence in full and the change is genuinely not in it.
- **Deployed** - a successful run that recorded a deployment had its head read and the merge commit is proven contained in it; cite the evidence (the deployed head, or the equivalent that project records).
- **Deployed and verified** - a production check actually ran, and the closed record says so in its own words.

Rules that keep this honest:

- Never present a merge as a ship.
  The reader returns `unknown` for every merge it cannot prove deployed; render that as merged, never as shipped.
- `unknown` and `no` are different sentences and must not be collapsed.
  `no` means "merged, not yet deployed"; `unknown` means "we could not tell", so say that plainly and name what could not be read.
  Never speak an `unknown` as "not yet deployed".
- Containment is proven, not assumed.
  If a deploy run was superseded or stopped, the work it carried is shipped only when a LATER successful run contains that commit; the reader checks that against every successful head, so trust its verdict rather than run order.
- A green pipeline is not a deploy.
  The reader only counts a run that recorded a deployment, so when a project's runs record none it says so; report that as "we cannot see a deploy train there", never as shipped.
- Verification is never inferred.
  No durable field records it, so read the closed record's own words (`--fields bodies`) and say "deployed, not yet verified" whenever a production check is not recorded.
- A source that could not be read is disclosed, not silently skipped.
  Read the reader's `omitted` lines and say what they cost in one plain sentence: an unrefreshed local copy, a deploy train that could not be read, a second mate's records on another host, a mainline read that hit its bound.
  Under-reporting silently is the failure this section exists to prevent.
- Under `--include-forge`, a pull request row is timed by `when_means`, not always by its merge.
  A Bitbucket pull request carries last activity rather than a merge time, so never date a ship from it; take the merge time from `merges` and use the forge list for titles and for merges a stale local copy has not picked up.
- Every pull request appears as its full `https://...` URL before any shorthand.

Empty state: "Nothing reached users in the last <window>."

### 2. In progress

Work being done right now and how far along it is, one line each, from the snapshot's `in_flight`.
Say the concrete state in the captain's words - building, in review, waiting on a check, waiting on an external service - never a validation-state label or a pipeline step name.
Never present elapsed time or an unchanged state as progress.

Empty state: "Nothing is being worked right now."

### 3. Next up

What we plan to pick up next and WHY those, from the snapshot's `gates`.
An item is next only when its blocker is gone and any date has arrived; anything still waiting belongs here with the reason, and a fleet-integrity warning is named as a repair notice rather than as queued work.
Give each item one clause of why it is next: it unblocks something, the captain asked for it, or it is the highest-priority work free to start.

Empty state: "Nothing is queued to start next."

### 4. Blockers

What is stuck and on whom, from the snapshot's `decisions_open` and `unhealthy_endpoints`, plus anything in progress that is genuinely waiting on someone.
Name the person or thing it waits on: the captain, a credential, another team, an outside service.
A declared external wait that will clear on its own is not a blocker; say it is waiting and leave it in section 2.

Empty state: "Nothing is blocked."

## Tone and length

- Follow `AGENTS.md` section 9 without exception.
  Use the captain's nouns: the project, the fix, the pull request, the review, the decision, the blocker, the worker, the local copy, the production check.
- Never use internal vocabulary in the report: no crewmate, task id, brief, worktree, cleanup-as-teardown, notification-as-wake, harness, runtime, backend, delivery-mode name, hold, gate, pipeline step name, validation-state label, or compressed safety phrasing such as fail-closed.
  Scout and second mate are accepted house words and need no translation.
- One scannable line per item.
  Detail, evidence, and full reasoning stay out of chat; the captain asks for them in the discussion.
- Every pull request carries its full `https://...` URL.
- Global means global: every registered project appears in the picture even when it was quiet.
  Say a quiet project was quiet rather than dropping it, so silence is never mistaken for not looking.
  Registered second mate homes are included the same way when `data/secondmates.md` exists; when it does not, there are simply no second mates, which is normal and needs no remark.

## Behavior contract

Producing the standup is READ-ONLY.
During the invocation it never merges a pull request, dispatches work, cleans up finished work, steers a worker, answers a decision, or changes any backlog or task record.
It refreshes nothing: a stale local copy is reported as stale rather than updated, because firstmate does not write to a project.

Acting on what the captain decides DURING the standup is ordinary firstmate work and happens only after the captain says so, under the normal authority rules.
End the report by inviting the captain's direction rather than assuming it - one short line, not a menu.
