# redline — design

*AI coding agents that know what the machine can take.* (Working name; repo `aburakt/redline`.)

## Intent

AI coding agents are blind to the machine they run on. On 2026-11-14 the author's 16 GB MacBook Air froze repeatedly: an agent-booted iOS Simulator sat at ~8.7 GB for a day, Android `qemu`, Gradle and the Claude desktop app took the rest, swap hit 6.7/8 GB, load average 67, nine JetsamEvents in five days. Nothing in the agent loop knew. The agent kept starting heavy things on top of a choking machine and never shut them down.

redline makes every agent aware of system state **without anyone invoking a skill**: it plugs into each agent's lifecycle hooks, tells the agent the machine's state at session start, and when a heavy or blocking command is about to run on a machine that can't take it, suggests a different path (or, at critical levels, stops it with the reason and the alternative).

## Two tracks

1. **Public (everyone):** zero-dependency, readable, auditable scripts. POSIX `sh` for macOS/Linux, PowerShell for Windows. No runtime to install, no binary to download — a hook that runs before every shell command must be something a user can read in five minutes and trust.
2. **Author's machine:** uses the public hooks unchanged, plus the author's existing machine-specific pieces (a launchd memory notifier and personal agent rules). Nothing author-specific goes into the public repo.

## Goals

- **G1 Session briefing.** At session start, inject one compact line: memory headroom, swap, disk free, heavy dev processes running (simulators, emulators, Gradle/JVM daemons, container VMs), occupied dev ports. ≤ ~40 tokens.
- **G2 Guard heavy/blocking commands.** Before a shell command, classify it. If it is *heavy* (simulator/emulator boot, `xcodebuild`, Gradle, `docker compose up`, dev servers, big installs) and the machine is under pressure → inject advice with a concrete alternative. If *critical* → deny with reason + alternative. If it is *blocking* (watch mode, interactive flags, starting a server on an occupied port, foreground long-runner) → advise the non-blocking form regardless of pressure.
- **G3 Silence when fine.** No output on pre-command hooks when nothing is wrong. Context is the agent's scarcest resource.
- **G4 Cheap.** p95 hook latency ≤ 100 ms; metrics cached (TTL ~10 s) in a temp state file.
- **G5 Every major agent.** Adapters for Claude Code, Codex CLI, Cursor, Gemini CLI, GitHub Copilot CLI (all verified to have session-start + pre-shell hooks). Fallback `AGENTS.md` snippet for agents without hooks.
- **G6 Playbook.** `SKILL.md` (Agent Skills standard) explaining the *why* and the alternative paths per situation; optional depth, never required for the hooks to work.
- **G7 Cross-OS metrics.** macOS (`kern.memorystatus_level`, `vm_pressure_level`, `vm.swapusage`, `simctl`), Linux (`/proc/pressure/memory` PSI, `MemAvailable`, swap), Windows (CIM `Win32_OperatingSystem`, page file). Disk free, load/CPU, listening ports, known heavy process patterns on all three.

## Non-goals

- Killing or stopping processes on its own. It informs and blocks the agent's *next* action; the human (or the agent, on advice) acts.
- A background daemon in v1 (possible v2: per-OS service for notifications and trends).
- Telemetry, network calls, accounts.
- Replacing OS monitors or Activity Monitor.

## Anti-goals (failure even if it "works")

- Noise: briefing every command, or advice that fires when the machine is fine.
- False blocks of legitimate work. Deny only at critical pressure, always with an override (`REDLINE=off` env or a config threshold).
- Slow agents: anything that makes each tool call noticeably slower.
- Requiring Node/Python/Bun/Go to be installed.
- Installer that silently rewrites a user's agent config. It must back up, show a diff/dry-run, and uninstall cleanly.

## Approaches considered

- **A. Hooks + on-demand cached probe (picked).** Proactive through the agent's own lifecycle; no background process; fast via cache.
- **B. A + background daemon.** Catches trends and notifies when no agent runs, but needs launchd/systemd/Task Scheduler per OS. Deferred to v2; the author's machine already has a local notifier.
- **C. Instructions only (AGENTS.md + skill).** Not proactive — depends on the agent remembering; the incident showed this fails. Kept only as fallback for hookless agents.
- Language: `sh` + PowerShell picked over a `bun build --compile` binary (~60 MB, opaque) and Go (small binary, still a download users must trust). The author asked for the most reasonable path for everyone rather than his own Bun standard.

## Shape (builder decides details)

```
redline/
  README.md            # what, why, 60-second install, what it injects (examples), uninstall
  SKILL.md             # playbook (Agent Skills format)
  AGENTS.md.snippet    # fallback for hookless agents
  bin/redline         # POSIX sh: `status`, `check -- <cmd>`, `hook <agent> <event>`
  bin/redline.ps1     # PowerShell equivalent
  install.sh / install.ps1   # detect agents, back up config, merge hooks, --dry-run, --uninstall
  adapters/            # per-agent hook config templates + I/O mapping notes
  rules/               # heavy/blocking command patterns + advice text (data, shared by sh/ps1)
  tests/               # fixture-driven: fake metrics in, expected advice out
  .github/workflows/ci.yml   # macos, ubuntu, windows matrix
```

- Thresholds (defaults, configurable): pressure **warn** when available memory < 25 % or OS pressure level ≥ warn; **critical** when < 10 % or OS critical; disk warn < 10 GB, critical < 3 GB. Swap is reported, never a trigger on its own (macOS keeps swap high long after pressure ends — measured).
- Advice is concrete and short: what's eating memory (top 1–2 groups with GB), the command to free it, and the alternative path (e.g. "verify on web/Expo web first", "reuse the booted simulator instead of a new one", "run the server in background and poll the port", "use `--no-watch`/`CI=1`").
- Testability: every metric source overridable by env (`REDLINE_FAKE_*`) so tests run deterministically on CI runners.

## Deliverables

1. Repo at `~/Projects/pets/redline`, public on GitHub `aburakt/redline`, MIT.
2. Author's machine: installed via the public installer; the existing local notifier stays.
3. Blog post in `aburakt.com` (`apps/web/src/content/articles/`, English like the existing five): the freeze story → measurement → why skills alone can't be proactive → hooks. Written, built locally; **pushed only after the author approves** (push deploys the site).
4. Short humanized posts for X and LinkedIn (TR + EN), drafts only.

## Left to the builder

Exact hook JSON per agent (verify against current official docs; Codex PreToolUse fires only for Bash, Cursor uses `beforeShellExecution`), rule pattern syntax, cache location per OS, output wording.

## Calls made after builder check (author may override)

1. **Allow/deny-only pre-shell hooks** (if an agent can't attach a note to an allowed command): *advise* moves to the session briefing and to a one-line note on the next hook that can carry context; *deny* at critical stays. Never upgrade advise to deny or to "ask the user" — that would break the no-false-blocks anti-goal. Builder verifies per agent which outcome shapes exist.
2. **Windows:** Windows PowerShell 5.1 supported (only zero-install option), language limited accordingly; pwsh 7 used when present. Pre-command path reads the cache only and refreshes it out of band, so the cold start is the cost. Budget on Windows: p95 ≤ 300 ms; macOS/Linux stay ≤ 100 ms.
3. **Publishing order:** the author asked for a public repo, so it is created and pushed once tests pass on the CI matrix, before the blog post (which links to it). The blog push to aburakt.com stays gated on the author's approval.
4. **Install:** user-level config only (never project-level — that would land in team repos). Use an agent's native plugin/extension packaging where it exists; otherwise merge with a backup + `--dry-run` + `--uninstall`.
5. **Author's machine:** the local notifier and personal agent rules stay. They don't duplicate the briefing: the rules are static, the notifier tells the human, redline informs the agent.
