import { describe, expect, test } from "bun:test";
import { fakes, impls, run } from "./helpers";

for (const impl of impls()) {
  describe(`check [${impl.name}]`, () => {
    const check = (cmd: string, f: Parameters<typeof fakes>[0] = {}, extra: Record<string, string> = {}) => {
      const r = run(impl, ["check", "--", cmd], { env: { ...fakes(f), ...extra } });
      expect(r.code).toBe(0);
      const [verdict, msg = ""] = r.stdout.split("\n");
      return { verdict, msg };
    };

    test("ok when fine", () => {
      const r = run(impl, ["check", "--", "xcrun simctl boot X"], { env: fakes({ mem: 70 }) });
      expect(r.stdout).toBe("ok\n");
    });

    test("advise on warn", () => {
      const { verdict, msg } = check("npx expo run:ios", { mem: 20, procs: "ios-sim:8700" });
      expect(verdict).toBe("advise");
      expect(msg.startsWith("redline: memory warn, 20% free; top: ios-sim 8.7G (free: xcrun simctl shutdown all).")).toBe(true);
      expect(msg).toContain("Prefer verifying on web");
    });

    test("deny on critical", () => {
      expect(check("./gradlew assembleDebug", { mem: 8 }).verdict).toBe("deny");
    });

    test("cpu never denies", () => {
      const { verdict, msg } = check("./gradlew assembleDebug", { mem: 70, load: 5 });
      expect(verdict).toBe("advise");
      expect(msg).toContain("load 5.0/core");
    });

    test("reuse booted sim", () => {
      const { verdict, msg } = check("xcrun simctl boot Y", { mem: 70, procs: "ios-sim:5000" });
      expect(verdict).toBe("advise");
      expect(msg).toContain("already booted");
    });

    test("cross device", () => {
      const { verdict, msg } = check("npx expo run:android", { mem: 70, procs: "ios-sim:5000" });
      expect(verdict).toBe("advise");
      expect(msg).toContain("shut it down before starting Android");
    });

    test("watch always", () => {
      expect(check("vitest --watch", { mem: 90 }).verdict).toBe("advise");
      expect(check("vitest run", { mem: 90 }).verdict).toBe("ok");
    });

    test("interactive", () => {
      expect(check("git rebase -i HEAD~3").verdict).toBe("advise");
      expect(check("git rebase main").verdict).toBe("ok");
      expect(check("cat less.txt").verdict).toBe("ok");
    });

    test("ports", () => {
      const { verdict, msg } = check("bun run dev", { ports: "5173" });
      expect(verdict).toBe("advise");
      expect(msg).toContain("5173");
      expect(check("bun run dev", { ports: "" }).verdict).toBe("ok");
    });

    test("disk critical install", () => {
      const { verdict, msg } = check("bun install", { disk: 2 });
      expect(verdict).toBe("deny");
      expect(msg).toContain("disk critical, 2G free");
    });

    test("multiple advise joined", () => {
      const { verdict, msg } = check("npm run dev -- --watch", { mem: 20, ports: "3000" });
      expect(verdict).toBe("advise");
      expect(msg).toContain(" | ");
    });

    test("REDLINE=off", () => {
      expect(check("./gradlew build", { mem: 5 }, { REDLINE: "off" }).verdict).toBe("ok");
    });
  });
}
