import { describe, expect, test } from "bun:test";
import { mkdtempSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fakes, freshCache, impls, isWin, ROOT } from "./helpers";
import { run } from "./helpers";

const busy = fakes({ mem: 71, swap: 4.3, disk: 18, load: 0.6, procs: "ios-sim:8700,gradle:1200,dev-server:120", ports: "3000,8081" });

for (const impl of impls()) {
  describe(`status [${impl.name}]`, () => {
    test("status json from fakes", () => {
      const r = run(impl, ["status", "--json"], { env: busy });
      expect(r.code).toBe(0);
      expect(JSON.parse(r.stdout)).toEqual({
        mem: { avail_pct: 71, level: "ok" },
        swap_gb: 4.3,
        disk: { free_gb: 18, level: "ok" },
        cpu: { load_per_core: 0.6, level: "ok" },
        heavy: [
          { group: "ios-sim", mb: 8700, free: "xcrun simctl shutdown all" },
          { group: "gradle", mb: 1200, free: "./gradlew --stop" },
        ],
        ports: [3000, 8081],
      });
    });

    test("levels", () => {
      const lv = (f: Parameters<typeof fakes>[0]) => JSON.parse(run(impl, ["status", "--json"], { env: fakes(f) }).stdout);
      expect(lv({ mem: 24 }).mem.level).toBe("warn");
      expect(lv({ mem: 9 }).mem.level).toBe("critical");
      expect(lv({ mem: 50, pressure: "critical" }).mem.level).toBe("critical");
      expect(lv({ mem: 50, pressure: "warn" }).mem.level).toBe("warn");
      expect(lv({ disk: 9 }).disk.level).toBe("warn");
      expect(lv({ disk: 2 }).disk.level).toBe("critical");
      expect(lv({ load: 2.1 }).cpu.level).toBe("warn");
    });

    test("threshold override", () => {
      const r = run(impl, ["status", "--json"], { env: { ...fakes({ mem: 71 }), REDLINE_MEM_WARN_PCT: "80" } });
      expect(JSON.parse(r.stdout).mem.level).toBe("warn");
    });

    test("briefing line", () => {
      expect(run(impl, ["status"], { env: busy }).stdout).toBe(
        "redline: mem 71% free · swap 4.3G · disk 18G free · heavy: ios-sim 8.7G, gradle 1.2G · ports 3000,8081\n",
      );
      expect(run(impl, ["status"], { env: fakes({ mem: 71, swap: 4.3, disk: 18 }) }).stdout).toBe(
        "redline: mem 71% free · swap 4.3G · disk 18G free · nothing heavy running\n",
      );
      expect(run(impl, ["status"], { env: fakes({ mem: 20, swap: 4.3, disk: 2, load: 3 }) }).stdout).toBe(
        "redline: mem 20% free (WARN) · swap 4.3G · disk 2G free (CRITICAL) · load 3.0/core (WARN) · nothing heavy running\n",
      );
    });

    test("REDLINE=off silences status", () => {
      const r = run(impl, ["status"], { env: { ...busy, REDLINE: "off" } });
      expect(r.code).toBe(0);
      expect(r.stdout).toBe("");
    });

    test.skipIf(isWin)("probe survives missing tools", () => {
      const bin = mkdtempSync(join(tmpdir(), "redline-path-"));
      for (const t of [impl.cmd[0], "sh", "cat", "sed", "awk", "grep", "mv", "date", "mkdir", "rm", "tr", "sort", "head"]) {
        const src = Bun.which(t);
        if (src && !Bun.file(join(bin, t)).size) try { symlinkSync(src, join(bin, t)); } catch {}
      }
      const r = run(impl, ["status", "--json"], { env: { PATH: bin } });
      expect(r.code).toBe(0);
      expect(() => JSON.parse(r.stdout)).not.toThrow();
    });

    test("cache write is atomic", async () => {
      const dir = freshCache();
      const procs = Array.from({ length: 20 }, () =>
        Bun.spawn([...impl.cmd, "status", "--json"], { cwd: ROOT, env: { ...process.env, REDLINE_CACHE_DIR: dir }, stdout: "pipe" }),
      );
      const outs = await Promise.all(procs.map((p) => new Response(p.stdout).text()));
      for (const o of outs) expect(() => JSON.parse(o)).not.toThrow();
    });

    test("real probe smoke", () => {
      const j = JSON.parse(run(impl, ["status", "--json"]).stdout);
      expect(j.mem.avail_pct).toBeGreaterThan(0);
      expect(j.mem.avail_pct).toBeLessThanOrEqual(100);
      expect(j.disk.free_gb).toBeGreaterThan(0);
    });
  });
}
