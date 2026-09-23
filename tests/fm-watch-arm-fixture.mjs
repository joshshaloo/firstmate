// Test-only deadline control for the Pi/OpenCode arm-lifecycle fixtures.
// Real child processes and retry scheduling still run normally. Only the two
// failure deadlines are held until the fixture has published its trap-ready
// marker (and, for retirement failure, acknowledged TERM). A slow shell startup
// must not decide which lifecycle branch this test exercises.
import { setTimeout as sleep } from "node:timers/promises";

export async function waitFor(predicate, label) {
  for (let i = 0; i < 500; i += 1) {
    if (predicate()) return;
    await sleep(10);
  }
  // This is a failure watchdog, never evidence that a fixture is ready.
  throw new Error(`timeout waiting for ${label}`);
}

export function controlArmDeadlines() {
  const ready = Number(process.env.FM_PI_ARM_READY_TIMEOUT_MS ?? process.env.FM_OPENCODE_ARM_READY_TIMEOUT_MS);
  const retire = Number(process.env.FM_WATCH_ARM_RETIRE_TIMEOUT_MS ?? 1000);
  if (!(ready > 0) || !(retire > 0) || ready === retire) {
    throw new Error("fixture needs distinct positive readiness and retirement deadlines");
  }
  const set = globalThis.setTimeout;
  const clear = globalThis.clearTimeout;
  const pending = new Map();
  globalThis.setTimeout = (callback, delay, ...args) => {
    if (delay !== ready && delay !== retire) return set(callback, delay, ...args);
    const handle = { unref() { return this; } };
    pending.set(handle, { delay, run: () => callback(...args) });
    return handle;
  };
  globalThis.clearTimeout = (handle) => {
    if (!pending.delete(handle)) clear(handle);
  };
  return {
    ready,
    retire,
    async expire(delay) {
      await waitFor(() => [...pending.values()].some((timer) => timer.delay === delay), `${delay}ms deadline registration`);
      const timers = [...pending].filter(([, timer]) => timer.delay === delay);
      if (timers.length !== 1) throw new Error(`expected one ${delay}ms deadline, got ${timers.length}`);
      const [handle, timer] = timers[0];
      pending.delete(handle);
      timer.run();
    },
    assertIdle() {
      if (pending.size) throw new Error(`uncleared arm deadlines: ${[...pending.values()].map((timer) => timer.delay)}`);
    },
  };
}
