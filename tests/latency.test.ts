import { expect, test } from "bun:test";
import { freshCache, impls, isWin, ROOT } from "./helpers";

const N = 50;
const p95 = (xs: number[]) => xs.sort((a, b) => a - b)[Math.ceil(xs.length * 0.95) - 1];
const time = (cmd: string[], env: Record<string, string>, stdin?: string) => {
  const t = performance.now();
  Bun.spawnSync(cmd, { cwd: ROOT, env, stdin: stdin ? Buffer.from(stdin) : "ignore" });
  return performance.now() - t;
};
const payload = JSON.stringify({ hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "./gradlew assembleDebug" } });

for (const impl of impls()) {
  // Budget: unix 100 ms total. Windows: interpreter start-up alone is ~0.4 s on CI runners, so
  // the budget is redline's own overhead: 300 ms above an empty run of the same interpreter.
  test(`warm-cache hook p95 within budget [${impl.name}]`, () => {
    const env = { ...process.env, REDLINE_CACHE_DIR: freshCache() } as Record<string, string>;
    Bun.spawnSync([...impl.cmd, "probe"], { cwd: ROOT, env }); // warm the cache
    const runs = Array.from({ length: N }, () => time([...impl.cmd, "hook", "claude", "pre"], env, payload));
    let budget = 100;
    if (isWin) {
      const empty = impl.cmd.slice(0, impl.cmd.indexOf("-File")).concat(["-Command", "exit 0"]);
      budget = p95(Array.from({ length: 20 }, () => time(empty, env))) + 300;
    }
    const got = p95(runs);
    console.log(`${impl.name}: p95 ${got.toFixed(0)} ms (budget ${budget.toFixed(0)} ms)`);
    expect(got).toBeLessThanOrEqual(budget);
  });
}
