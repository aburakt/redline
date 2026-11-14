import { describe, expect, test } from "bun:test";
import { fakes, freshCache, impls, run } from "./helpers";

type Agent = "claude" | "codex" | "cursor" | "gemini" | "copilot";
const AGENTS: Agent[] = ["claude", "codex", "cursor", "gemini", "copilot"];

/** stdin payloads shaped like each agent's documented hook input */
function pre(agent: Agent, command: string, cwd = "/work/app"): string {
  switch (agent) {
    case "claude":
      return JSON.stringify({ session_id: "s", transcript_path: "/tmp/t.jsonl", cwd, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command, description: "x" }, tool_use_id: "t1" });
    case "codex":
      return JSON.stringify({ session_id: "s", turn_id: "u", cwd, hook_event_name: "PreToolUse", model: "m", tool_name: "Bash", tool_input: { command }, tool_use_id: "t1" });
    case "cursor":
      return JSON.stringify({ command, cwd, sandbox: false, hook_event_name: "beforeShellExecution" });
    case "gemini":
      return JSON.stringify({ session_id: "s", cwd, hook_event_name: "BeforeTool", tool_name: "run_shell_command", tool_input: { command } });
    case "copilot":
      return JSON.stringify({ timestamp: 1, cwd, toolName: "bash", toolArgs: JSON.stringify({ command }) });
  }
}
const start = (agent: Agent) => JSON.stringify({ session_id: "s", cwd: "/work/app", hook_event_name: "SessionStart", source: "startup", sessionId: "s" });

const LINE = "redline: mem 71% free · swap 4.3G · disk 18G free · heavy: ios-sim 8.7G · ports 3000";
const busy = fakes({ mem: 71, swap: 4.3, disk: 18, procs: "ios-sim:8700", ports: "3000" });
const ADV = fakes({ mem: 20, procs: "ios-sim:8700" });
const DENY = fakes({ mem: 5 });

const startShape = (a: Agent, l: string) =>
  a === "cursor" ? { additional_context: l } : a === "copilot" ? { additionalContext: l } : { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: l } };

for (const impl of impls()) {
  const hook = (a: Agent, ev: string, stdin: string, env: Record<string, string>) => {
    const r = run(impl, ["hook", a, ev], { env, stdin });
    expect(r.code).toBe(0);
    return r.stdout.trim();
  };
  const okOut = (a: Agent) => (a === "cursor" ? JSON.stringify({ permission: "allow" }) : "");

  describe(`hook [${impl.name}]`, () => {
    for (const a of AGENTS) {
      test(`${a}: start emits briefing`, () => {
        expect(JSON.parse(hook(a, "start", start(a), busy))).toEqual(startShape(a, LINE));
      });

      test(`${a}: pre ok`, () => {
        expect(hook(a, "pre", pre(a, "ls -la"), busy)).toBe(okOut(a));
      });

      test(`${a}: pre advise`, () => {
        const out = hook(a, "pre", pre(a, "npx expo run:ios"), ADV);
        const msg = "redline: memory warn, 20% free; top: ios-sim 8.7G (free: xcrun simctl shutdown all). Prefer verifying on web or an already-booted device; shut down simulators when done (xcrun simctl shutdown all).";
        if (a === "claude" || a === "codex") expect(JSON.parse(out)).toEqual({ hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: msg } });
        else if (a === "cursor") expect(JSON.parse(out)).toEqual({ permission: "allow", agent_message: msg });
        else expect(out).toBe("");
      });

      test(`${a}: pre deny`, () => {
        const j = JSON.parse(hook(a, "pre", pre(a, "./gradlew assembleDebug"), DENY));
        const msg = expect.stringContaining("redline: memory critical, 5% free");
        if (a === "claude" || a === "codex") expect(j).toEqual({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: msg } });
        else if (a === "cursor") expect(j).toEqual({ permission: "deny", user_message: msg, agent_message: msg });
        else if (a === "gemini") expect(j).toEqual({ decision: "deny", reason: msg });
        else expect(j).toEqual({ permissionDecision: "deny", permissionDecisionReason: msg });
      });

      test(`${a}: REDLINE=off`, () => {
        const off = { ...DENY, REDLINE: "off" };
        expect(hook(a, "start", start(a), off)).toBe("");
        expect(hook(a, "pre", pre(a, "./gradlew build"), off)).toBe(okOut(a));
      });

      test(`${a}: hook ignores rule words outside command`, () => {
        expect(hook(a, "pre", pre(a, "ls", "/work/gradle-app"), DENY)).toBe(okOut(a));
      });

      test(`${a}: output json is valid with hostile command`, () => {
        const out = hook(a, "pre", pre(a, 'echo "a\\"b" \\\\ $(x)\nvitest --watch'), fakes());
        if (a === "gemini" || a === "copilot") return expect(out).toBe("");
        const j = JSON.parse(out);
        expect(JSON.stringify(j)).toContain("Watch mode never exits");
      });

      test(`${a}: internal error fails open`, () => {
        expect(hook(a, "pre", "{not json", { REDLINE_CACHE_DIR: "/nonexistent/ro" })).toBe(okOut(a));
      });
    }

    test("gemini advise then post", () => {
      const env = { ...ADV, REDLINE_CACHE_DIR: freshCache() };
      expect(hook("gemini", "pre", pre("gemini", "npx expo run:ios"), env)).toBe("");
      const j = JSON.parse(hook("gemini", "post", "{}", env));
      expect(j.hookSpecificOutput.hookEventName).toBe("AfterTool");
      expect(j.hookSpecificOutput.additionalContext).toContain("Prefer verifying on web");
      expect(hook("gemini", "post", "{}", env)).toBe("");
    });
  });
}
