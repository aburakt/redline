import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { impls, ROOT, run } from "./helpers";

const readme = readFileSync(join(ROOT, "README.md"), "utf8");
// <!-- example: KEY=V KEY=V :: arg arg -->  followed by a ```text block
const EX = /<!-- example: (.*?) :: (.*?) -->\s*```text\n([\s\S]*?)```/g;
const examples = [...readme.matchAll(EX)].map(([, env, args, out]) => ({
  env: Object.fromEntries(env.trim().split(/\s+/).filter(Boolean).map((kv) => kv.split("=") as [string, string])),
  args: args.trim().match(/'[^']*'|\S+/g)!.map((a) => a.replace(/^'|'$/g, "")),
  out,
}));

test("readme has at least four live examples", () => {
  expect(examples.length).toBeGreaterThanOrEqual(4);
});

for (const impl of impls()) {
  for (const [i, ex] of examples.entries()) {
    test(`readme example ${i + 1} matches real output [${impl.name}]: ${ex.args.join(" ")}`, () => {
      expect(run(impl, ex.args, { env: ex.env }).stdout).toBe(ex.out);
    });
  }
}

test("skill frontmatter", () => {
  const s = readFileSync(join(ROOT, "skills", "redline", "SKILL.md"), "utf8");
  const fm = s.match(/^---\n([\s\S]*?)\n---\n/);
  expect(fm).not.toBeNull();
  expect(fm![1]).toMatch(/^name: redline$/m);
  expect(fm![1]).toMatch(/^description: .{40,}$/m);
  expect(s.split("\n").length).toBeLessThanOrEqual(150);
});

test("agents snippet is short", () => {
  const s = readFileSync(join(ROOT, "AGENTS.md.snippet"), "utf8");
  expect(s.trim().split("\n").length).toBeLessThanOrEqual(12);
});
