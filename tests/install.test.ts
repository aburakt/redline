import { describe, expect, test } from "bun:test";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isWin, ROOT } from "./helpers";

const installer = isWin
  ? ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", join(ROOT, "install.ps1")]
  : ["sh", join(ROOT, "install.sh")];
const engines = isWin ? ["native"] : ["jq", "python3", "node"].filter((e) => Bun.which(e));
const AGENTS = "codex,cursor,gemini,copilot";

function home() {
  const h = mkdtempSync(join(tmpdir(), "redline-home-"));
  for (const d of [".codex", ".cursor", ".gemini", ".copilot"]) mkdirSync(join(h, d));
  return h;
}
function install(h: string, args: string[], engine: string) {
  const p = Bun.spawnSync([...installer, ...args], {
    cwd: ROOT,
    env: { ...process.env, HOME: h, USERPROFILE: h, REDLINE_MERGE: engine, REDLINE_CLAUDE_BIN: "/nonexistent/claude" },
  });
  return { out: p.stdout.toString() + p.stderr.toString(), code: p.exitCode };
}
const J = (h: string, f: string) => JSON.parse(readFileSync(join(h, f), "utf8"));
const cmdsOf = (x: unknown) => JSON.stringify(x).match(/"(command|bash|powershell)":"(?:[^"\\]|\\.)*redline(?:[^"\\]|\\.)*"/g) ?? [];

for (const engine of engines) {
  describe(`install [${engine}]`, () => {
    test("fresh install writes all four configs", () => {
      const h = home();
      const r = install(h, ["--agents", AGENTS], engine);
      expect(r.code).toBe(0);
      const codex = J(h, ".codex/hooks.json");
      expect(Object.keys(codex.hooks).sort()).toEqual(["PreToolUse", "SessionStart"]);
      expect(codex.hooks.PreToolUse[0].matcher).toBe("^Bash$");
      expect(codex.hooks.PreToolUse[0].hooks[0].command).toContain("hook codex pre");
      const cursor = J(h, ".cursor/hooks.json");
      expect(cursor.version).toBe(1);
      expect(cursor.hooks.beforeShellExecution[0].command).toContain("hook cursor pre");
      expect(cursor.hooks.sessionStart[0].command).toContain("hook cursor start");
      const gemini = J(h, ".gemini/settings.json");
      expect(gemini.hooks.BeforeTool[0].matcher).toBe("run_shell_command");
      expect(gemini.hooks.AfterTool[0].hooks[0].command).toContain("hook gemini post");
      expect(gemini.hooks.SessionStart[0].hooks[0].timeout).toBe(10000);
      const copilot = J(h, ".copilot/hooks/redline.json");
      expect(copilot.version).toBe(1);
      expect(copilot.hooks.preToolUse[0].timeoutSec).toBe(10);
      expect(copilot.hooks.preToolUse[0].bash ?? copilot.hooks.preToolUse[0].powershell).toContain("hook copilot pre");
      expect(existsSync(join(h, ".redline", "rules", "rules.tsv"))).toBe(true);
    });

    test("merge preserves existing hooks", () => {
      const h = home();
      const other = { type: "command", command: "/usr/local/bin/my-lint" };
      writeFileSync(join(h, ".codex/hooks.json"), JSON.stringify({ hooks: { PreToolUse: [{ matcher: "^Bash$", hooks: [other] }] } }));
      writeFileSync(join(h, ".gemini/settings.json"), JSON.stringify({ theme: "dark", hooks: { BeforeTool: [{ matcher: "write_file", hooks: [other] }] } }));
      install(h, ["--agents", AGENTS], engine);
      const codex = J(h, ".codex/hooks.json");
      expect(JSON.stringify(codex)).toContain("my-lint");
      expect(cmdsOf(codex).length).toBe(2);
      const gemini = J(h, ".gemini/settings.json");
      expect(gemini.theme).toBe("dark");
      expect(JSON.stringify(gemini)).toContain("my-lint");
    });

    test("idempotent", () => {
      const h = home();
      install(h, ["--agents", AGENTS], engine);
      install(h, ["--agents", AGENTS], engine);
      expect(cmdsOf(J(h, ".codex/hooks.json")).length).toBe(2);
      expect(cmdsOf(J(h, ".cursor/hooks.json")).length).toBe(2);
      expect(cmdsOf(J(h, ".gemini/settings.json")).length).toBe(3);
    });

    test("backup created only when the file existed", () => {
      const h = home();
      writeFileSync(join(h, ".cursor/hooks.json"), JSON.stringify({ version: 1, hooks: {} }));
      install(h, ["--agents", AGENTS], engine);
      expect(readdirSync(join(h, ".cursor")).some((f) => f.startsWith("hooks.json.redline-bak-"))).toBe(true);
      expect(readdirSync(join(h, ".codex")).some((f) => f.includes("redline-bak"))).toBe(false);
    });

    test("dry-run writes nothing", () => {
      const h = home();
      // PowerShell itself creates AppData under USERPROFILE; only agent dirs and .redline matter
      const snap = () => JSON.stringify((readdirSync(h, { recursive: true }) as string[]).filter((f) => !f.startsWith("AppData")).sort());
      const before = snap();
      const r = install(h, ["--dry-run", "--agents", AGENTS], engine);
      expect(r.code).toBe(0);
      expect(snap()).toBe(before);
      expect(r.out).toContain(".codex");
      expect(r.out).toContain("hook codex pre");
    });

    test("uninstall removes only redline entries", () => {
      const h = home();
      const other = { type: "command", command: "/usr/local/bin/my-lint" };
      writeFileSync(join(h, ".codex/hooks.json"), JSON.stringify({ hooks: { PreToolUse: [{ matcher: "^Bash$", hooks: [other] }] } }));
      install(h, ["--agents", AGENTS], engine);
      const r = install(h, ["--uninstall", "--agents", AGENTS], engine);
      expect(r.code).toBe(0);
      const codex = J(h, ".codex/hooks.json");
      expect(cmdsOf(codex).length).toBe(0);
      expect(JSON.stringify(codex)).toContain("my-lint");
      expect(cmdsOf(J(h, ".cursor/hooks.json")).length).toBe(0);
      expect(existsSync(join(h, ".copilot/hooks/redline.json"))).toBe(false);
      expect(existsSync(join(h, ".redline"))).toBe(false);
    });

    test("claude without CLI prints plugin commands", () => {
      const h = home();
      const r = install(h, ["--agents", "claude"], engine);
      expect(r.code).toBe(0);
      expect(r.out).toContain("claude plugin marketplace add aburakt/redline");
      expect(r.out).toContain("claude plugin install redline@redline");
    });
  });
}

test.skipIf(isWin)("no merge engine leaves configs untouched", () => {
  const h = home();
  const seed = JSON.stringify({ hooks: { PreToolUse: [] } });
  writeFileSync(join(h, ".codex/hooks.json"), seed);
  const r = install(h, ["--agents", AGENTS], "none");
  expect(r.code).toBe(0);
  expect(readFileSync(join(h, ".codex/hooks.json"), "utf8")).toBe(seed);
  expect(r.out).toContain("hook codex pre");
  expect(existsSync(join(h, ".copilot/hooks/redline.json"))).toBe(true);
});

test("plugin hooks.json references the plugin root", () => {
  const j = JSON.parse(readFileSync(join(ROOT, "hooks", "hooks.json"), "utf8"));
  expect(j.hooks.SessionStart[0].hooks[0].command).toContain("${CLAUDE_PLUGIN_ROOT}/bin/redline");
  expect(j.hooks.PreToolUse[0].matcher).toBe("Bash");
  expect(j.hooks.PreToolUse[0].hooks[0].command).toContain("hook claude pre");
  const m = JSON.parse(readFileSync(join(ROOT, ".claude-plugin", "marketplace.json"), "utf8"));
  expect(m.plugins[0].name).toBe("redline");
});

for (const engine of engines) {
  test(`mixed hook group keeps the user's hook [${engine}]`, () => {
    const h = home();
    const mine = { type: "command", command: "/usr/local/bin/mine" };
    const theirs = { type: "command", command: "sh /x/bin/redline hook codex pre" };
    writeFileSync(join(h, ".codex/hooks.json"), JSON.stringify({ hooks: { PreToolUse: [{ matcher: "Bash", hooks: [mine, theirs] }] } }));
    install(h, ["--agents", "codex"], engine);
    expect(JSON.stringify(J(h, ".codex/hooks.json"))).toContain("/usr/local/bin/mine");
    install(h, ["--uninstall", "--agents", "codex"], engine);
    const after = J(h, ".codex/hooks.json");
    expect(JSON.stringify(after)).toContain("/usr/local/bin/mine");
    expect(cmdsOf(after).length).toBe(0);
  });
}

test.skipIf(isWin)("a symlinked config stays a symlink", () => {
  const h = home();
  const dotfiles = mkdtempSync(join(tmpdir(), "redline-dotfiles-"));
  writeFileSync(join(dotfiles, "hooks.json"), JSON.stringify({ version: 1, hooks: {} }));
  symlinkSync(join(dotfiles, "hooks.json"), join(h, ".cursor/hooks.json"));
  install(h, ["--agents", "cursor"], engines[0]);
  expect(lstatSync(join(h, ".cursor/hooks.json")).isSymbolicLink()).toBe(true);
  expect(readFileSync(join(dotfiles, "hooks.json"), "utf8")).toContain("hook cursor pre");
});

test("--agents without a value is an error, not auto-detect", () => {
  const h = home();
  const r = install(h, ["--agents"], engines[0]);
  expect(r.code).not.toBe(0);
  expect(existsSync(join(h, ".redline"))).toBe(false);
});
