import { mkdtempSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

export const ROOT = resolve(import.meta.dir, "..");
export const isWin = process.platform === "win32";
export type Impl = { name: string; cmd: string[] };

const which = (b: string) => Bun.which(b) !== null;

/** Every implementation runnable on this machine. REDLINE_IMPLS=sh,pwsh narrows it. */
export function impls(): Impl[] {
  const ps1 = join(ROOT, "bin", "redline.ps1");
  const sh = join(ROOT, "bin", "redline");
  const all: Impl[] = [];
  if (!isWin) {
    all.push({ name: "sh", cmd: ["sh", sh] });
    if (which("dash")) all.push({ name: "dash", cmd: ["dash", sh] });
  } else {
    all.push({ name: "powershell", cmd: ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ps1] });
  }
  if (isWin && which("pwsh") && existsSync(ps1)) all.push({ name: "pwsh", cmd: ["pwsh", "-NoProfile", "-File", ps1] });
  const only = process.env.REDLINE_IMPLS?.split(",");
  return only ? all.filter((i) => only.includes(i.name)) : all;
}

export const freshCache = () => mkdtempSync(join(tmpdir(), "redline-test-"));

export type RunOpts = { env?: Record<string, string>; stdin?: string; clean?: boolean };

/** Runs an implementation with a fresh cache dir and no inherited REDLINE_* vars. */
export function run(impl: Impl, args: string[], opts: RunOpts = {}) {
  const base: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) if (!k.startsWith("REDLINE") && v !== undefined) base[k] = v;
  const env = { ...base, REDLINE_CACHE_DIR: freshCache(), ...opts.env };
  const p = Bun.spawnSync([...impl.cmd, ...args], {
    env,
    cwd: ROOT,
    stdin: opts.stdin !== undefined ? Buffer.from(opts.stdin) : "ignore",
  });
  return { stdout: p.stdout.toString().replace(/\r\n/g, "\n"), stderr: p.stderr.toString(), code: p.exitCode };
}

type F = { mem?: number; pressure?: string; swap?: number; disk?: number; load?: number; procs?: string; ports?: string };
/** Fake metric env. Unset fields default to a calm machine. */
export function fakes(f: F = {}): Record<string, string> {
  return {
    REDLINE_FAKE_MEM_AVAIL_PCT: String(f.mem ?? 70),
    REDLINE_FAKE_PRESSURE: f.pressure ?? "normal",
    REDLINE_FAKE_SWAP_GB: String(f.swap ?? 1),
    REDLINE_FAKE_DISK_FREE_GB: String(f.disk ?? 100),
    REDLINE_FAKE_LOAD_PER_CORE: String(f.load ?? 0.5),
    REDLINE_FAKE_PROCS: f.procs ?? "",
    REDLINE_FAKE_PORTS: f.ports ?? "",
  };
}
