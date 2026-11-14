import { expect, test } from "bun:test";
import { chmodSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isWin, ROOT } from "./helpers";

test.skipIf(isWin)("sh dispatches to redline.ps1 on Git Bash/MSYS", () => {
  const bin = mkdtempSync(join(tmpdir(), "redline-stub-"));
  writeFileSync(join(bin, "powershell"), '#!/bin/sh\necho "STUB $*"\n');
  chmodSync(join(bin, "powershell"), 0o755);
  const p = Bun.spawnSync(["sh", join(ROOT, "bin", "redline"), "status"], {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, REDLINE_FAKE_UNAME: "MINGW64_NT-10.0" },
  });
  const out = p.stdout.toString();
  expect(out).toContain("STUB -NoProfile -ExecutionPolicy Bypass -File");
  expect(out).toContain("redline.ps1 status");
});
