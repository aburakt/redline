# redline

AI coding agents don't know what the machine they run on can take. redline tells them.

It hooks into Claude Code, Codex, Cursor, Gemini CLI and Copilot CLI. When a session starts, it gives the agent one line about the machine. Before a heavy or blocking shell command, it suggests a better path, and it stops the command only when memory or disk is critical. When nothing is wrong, it says nothing. It never kills a process. It has no dependencies: one `sh` script and one PowerShell script.

## Why

My 16 GB MacBook Air kept freezing. When I measured, I found:

- An iOS Simulator that an agent had booted a day earlier, still holding **8.7 GB**.
- Next to it, an Android emulator, Gradle and a desktop app.
- **Swap at 6.7 of 8 GB**, a load average of **67**, and **9 out-of-memory kills in 5 days**.

The agents had no idea. They kept starting heavy things on a machine that was already choking, and they never shut down what they started.

A skill alone can't fix this, because an agent loads a skill only when it decides to. Hooks run every time. So redline lives in the hooks, and the skill is there for the reasons behind the advice.

## What the agent sees

At session start, one line (example: a busy machine):

<!-- example: REDLINE_FAKE_MEM_AVAIL_PCT=18 REDLINE_FAKE_SWAP_GB=6.7 REDLINE_FAKE_DISK_FREE_GB=18 REDLINE_FAKE_LOAD_PER_CORE=1.2 REDLINE_FAKE_PROCS=ios-sim:8700,android-emu:3100,gradle:1400 REDLINE_FAKE_PORTS=8081 :: status -->
```text
redline: mem 18% free (WARN) · swap 6.7G · disk 18G free · heavy: ios-sim 8.7G, android-emu 3.1G, gradle 1.4G · ports 8081
```

The agent then tries to boot Android on top of that:

<!-- example: REDLINE_FAKE_MEM_AVAIL_PCT=18 REDLINE_FAKE_SWAP_GB=6.7 REDLINE_FAKE_DISK_FREE_GB=18 REDLINE_FAKE_LOAD_PER_CORE=1.2 REDLINE_FAKE_PROCS=ios-sim:8700,android-emu:3100,gradle:1400 REDLINE_FAKE_PORTS=8081 :: check -- 'npx expo run:android' -->
```text
advise
redline: memory warn, 18% free; top: ios-sim 8.7G (free: xcrun simctl shutdown all). Only one device at a time; stop it when done (adb emu kill). | iOS simulator is running: shut it down before starting Android.
```

At 7% free memory, a Gradle build is stopped, with the reason and the way out:

<!-- example: REDLINE_FAKE_MEM_AVAIL_PCT=7 REDLINE_FAKE_DISK_FREE_GB=18 REDLINE_FAKE_PROCS=ios-sim:8700 :: check -- './gradlew assembleDebug' -->
```text
deny
redline: memory critical, 7% free; top: ios-sim 8.7G (free: xcrun simctl shutdown all). Run with --no-daemon or stop the daemon afterwards (./gradlew --stop).
```

Commands that would hang the agent get advice even on an idle machine:

<!-- example: REDLINE_FAKE_MEM_AVAIL_PCT=70 :: check -- 'vitest --watch' -->
```text
advise
redline: Watch mode never exits and will block the agent: run once (e.g. vitest run, CI=1), or start it in the background.
```

For everything else, nothing happens:

<!-- example: REDLINE_FAKE_MEM_AVAIL_PCT=18 :: check -- 'ls -la' -->
```text
ok
```

## Install

macOS / Linux:

```sh
git clone https://github.com/aburakt/redline && sh redline/install.sh --dry-run   # see what it would change
sh redline/install.sh
```

Windows (PowerShell 5.1+ or pwsh 7):

```powershell
git clone https://github.com/aburakt/redline; powershell -ExecutionPolicy Bypass -File .\redline\install.ps1
```

The installer:

- Copies the two scripts and the rule files to `~/.redline`.
- Finds the agents you have and adds hooks to their **user-level** config. It never touches project files.
- Backs up every file before changing it (`<file>.redline-bak-<time>`).
- Removes everything it added with `--uninstall`.
- Runs only the agents you name with `--agents codex,cursor`.

On macOS/Linux it merges JSON with `jq`, `python3` or `node`, whichever it finds first. With none of them, it prints what to add and changes nothing.

Claude Code installs redline as a plugin (the installer runs this for you if `claude` is on your PATH):

```sh
claude plugin marketplace add aburakt/redline && claude plugin install redline@redline
```

## Agent support

| Agent | Session briefing | Advice before a command | Stop at critical | Config | Verified |
|---|---|---|---|---|---|
| Claude Code | ✓ | ✓ | ✓ | plugin | live, macOS (Claude Code 2.1.325) |
| Codex CLI | ✓ | ✓ | ✓ | `~/.codex/hooks.json` (Codex asks you to trust new hooks once) | tests |
| Cursor | ✓ | ✓ via `agent_message`¹ | ✓ | `~/.cursor/hooks.json` | tests |
| Gemini CLI² | ✓ | after the command (`AfterTool`) | ✓ | `~/.gemini/settings.json` | tests |
| Copilot CLI | ✓ | in the briefing only³ | ✓ | `~/.copilot/hooks/redline.json` | tests |
| anything else | paste [`AGENTS.md.snippet`](AGENTS.md.snippet) into your `AGENTS.md` | | | | |

1. Cursor's docs don't say whether `agent_message` reaches the model when a command is allowed.
2. Google replaced Gemini CLI with Antigravity CLI in June 2026. The adapter follows Gemini CLI's documented hook format.
3. Copilot's `preToolUse` hook can't attach a note to a command it allows. redline won't turn advice into a stop just because it can't attach a note.

The hook formats come from each agent's official docs (fetched 2026-11-14). Each adapter is covered by tests that use payloads shaped like those docs. **live** means it was checked in a real session of that agent; **tests** means only the tests have checked it so far. Reports from other agents are welcome.

## What it watches

| | macOS | Linux | Windows |
|---|---|---|---|
| memory | `kern.memorystatus_level`, VM pressure level | `MemAvailable`, PSI `/proc/pressure/memory` | `Win32_OperatingSystem` |
| swap | `vm.swapusage` | `/proc/meminfo` | page file usage |
| load | `vm.loadavg` / cores | `/proc/loadavg` / cores | CPU % (100% ≈ 2.0 per core) |
| disk | `df` on `$HOME` | `df` on `$HOME` | drive of `%USERPROFILE%` |
| heavy processes | iOS Simulator, Android emulator, Gradle daemon, VMs/containers, dev servers ([`rules/groups.tsv`](rules/groups.tsv)) | same | same |
| ports | common dev ports (3000, 5173, 8081, …) | same | same |

The commands it reacts to are in [`rules/rules.tsv`](rules/rules.tsv): one line per rule (`id`, `when`, regex, advice). Add your own.

## Configuration

| env | default | |
|---|---|---|
| `REDLINE=off` | | disable everything |
| `REDLINE_MEM_WARN_PCT` / `REDLINE_MEM_CRIT_PCT` | 25 / 10 | % of memory available |
| `REDLINE_DISK_WARN_GB` / `REDLINE_DISK_CRIT_GB` | 10 / 3 | free GB |
| `REDLINE_CPU_WARN` | 2 | load per core (advice only, never a stop) |
| `REDLINE_TTL` | 10 (Windows 30) | seconds a metrics snapshot is reused |

Swap is reported but never triggers anything. macOS keeps swap high long after memory pressure is gone (I measured 4.3 GB still in swap with 71% of memory free).

Run `~/.redline/bin/redline status` yourself any time.

## How it works

- The metrics are cached in `~/.cache/redline` (Windows: `%TEMP%\redline`), a private directory. Every value is checked against a strict format before use, so nothing written there can reach the agent as text. The cache lasts 10 s (30 s on Windows), written atomically. When the cache goes stale, the old values are served while a background refresh runs, so a hook usually only reads a file.
- `check` reads the rules and returns `ok`, `advise` or `deny`. Each adapter turns that into the JSON its agent expects.
- If any internal step fails, the hook exits 0 with no output. A broken hook must never block your agent.
- The same test suite runs against `sh`, `dash`, Windows PowerShell 5.1 and pwsh 7 on macOS, Linux and Windows CI, so both implementations have to produce the same output.

## Limitations

- **No background daemon.** redline acts when an agent runs. On its own machine the author pairs it with a small launchd notifier.
- **Windows is slower.** Measured on GitHub's Windows runners, a hook call takes about 0.5 s with Windows PowerShell 5.1 and 0.65 s with pwsh 7. About 0.25 s of that is redline; the rest is PowerShell starting up. Gathering the metrics (CIM queries) costs 3–6 s of CPU, so on Windows it runs at most every 30 s, in the background. The very first call after boot waits for it. Set `REDLINE_PROFILE=1` to print timings to stderr.
- **Windows CPU is approximate.** It maps CPU % to a load-per-core figure.
- **Pattern matching.** It matches the command text against rules, anchored to where a command starts, so `cat build.gradle` isn't treated as a build. It doesn't parse shell scripts.
- **Containers.** Inside a Linux container it reports the host's memory, not the container's cgroup limit.
- **Not tested live:** Claude Code on Windows, and the four agents marked *tests* above.

## Uninstall

```sh
sh redline/install.sh --uninstall        # or: install.ps1 --uninstall
```

MIT © Ahmet Burak Tekin
