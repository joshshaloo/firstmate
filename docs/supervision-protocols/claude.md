Mode: Claude Stop-hook-owned supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
2. Routine watcher arm and re-arm are owned by the Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`), never by you.
   Every turn end while supervision is needed launches or attaches one home-scoped watcher cycle with no model command and no model tokens.
   An actionable close wakes you through the hook's exit-2 rewake, delivered as a `Stop hook feedback` message.
3. On a `Stop hook feedback` wake (`signal:`, `stale:`, `check:`, or `heartbeat`), run `bin/fm-wake-drain.sh` first and handle the wake.
   Do not run `bin/fm-watch-arm.sh` after an ordinary wake; the next turn end re-arms automatically when supervision is still needed.
   Do not invent a wake from an attach-status line alone; drain and act only on real wake records or a real watcher reason line.
   A `firstmate watcher renewal` wake means the hook retired a quiet cycle before its lifetime bound: drain, handle anything returned, and end the turn normally without arming.
4. On a `Stop hook feedback` watcher-failure wake (`watcher: FAILED ...`), treat it as an alarm: drain, then repair supervision before ending the turn.
   Its banner reports supervision down when no live watcher was proven, or an unresolved absorbed-wake chain when one still holds this home but the hook stopped translating its wakes; both need the same repair.
5. Manual arm is recovery only.
   When a repair is genuinely needed - the Stop hook did not claim this home, or a forced restart is required - run `bin/fm-watch-arm.sh` (or `bin/fm-watch-arm.sh --restart`) as its own Claude Code background task, never bundled with other commands, never with shell `&`.
   Source `__FM_X_MODE_ENV__` first when X mode is active.
   A shell `&`, a truncating pipe, or bundling is denied automatically by the PreToolUse seatbelt (`bin/fm-arm-pretool-check.sh`) registered in `.claude/settings.json`.
6. Treat `watcher: started ...` and `watcher: attached ...` inside arm output as proof that one live cycle exists.
   On attach, the arm follows verified identity-matched successors instead of exiting when the first cycle ends.
7. The durable wake queue preserves actionable events between a rewake and the next Stop-launched arm, while the bounded turn-end guard prevents a blind Stop when recovery did not start.
   No PreToolUse hook denies fleet commands based on watcher status.
   [`watcher-continuity.md`](../watcher-continuity.md) owns the exact session-lock recovery boundary.
8. The turn-end guard (`bin/fm-turnend-guard.sh --claude`) remains the final backstop.
   It allows the stop when a watcher is healthy or the auto-arm's own verdict for this turn end shows it owns recovery, waiting for a slow auto-arm; otherwise it re-blocks with the concrete reason, within a bounded budget.
   A `PERSISTENT FAILURE` line in its banner means the auto-arm has repeatedly failed to own recovery: repair supervision, then report it to the captain as a blocker.
9. Waiting on the hook-owned cycle is silent: do not send idle progress while the watcher is parked.

The watcher itself remains `bin/fm-watch.sh`, and `bin/fm-watch-arm.sh` remains the verified arm wrapper that the Stop hook runs as a tracked background child, waits on, and retires at its lifetime bound.
Re-arm attaches to an existing healthy cycle when one is already present and follows its verified successor chain.
See [`watcher-continuity.md`](../watcher-continuity.md) for the arm-layer successor and clean-close failure contract and the Claude ownership model.
