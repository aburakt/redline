---
name: redline
description: Machine resources for coding agents — memory pressure, disk, swap, simulators/emulators, Gradle, containers, dev servers, watch mode and interactive commands that hang. Read before booting devices, builds or containers, when a command seems stuck, or when a "redline:" line appears.
---

# redline

You share one finite machine with a human. Every heavy thing you start, you own: you check
before you start it, you reuse what is already running, and you stop it when you are done.
A frozen laptop costs the human far more than the minute you save by skipping that.

## Reading a redline line

`redline: mem 18% free (WARN) · swap 6.7G · disk 18G free · heavy: ios-sim 8.7G · ports 8081`

- `mem N% free` is memory still available. `WARN` means below 25%, `CRITICAL` below 10% or the OS
  reports critical pressure. Under WARN, ask before starting anything heavy. Under CRITICAL, free
  memory first; heavy commands will be stopped.
- `swap` is information only. High swap with plenty of free memory is normal on macOS.
- `heavy:` lists what is holding memory, largest first. If you started it, stop it.
- `ports` lists dev ports that are already listening. A server may already be running: reuse it.
- `advise` before a command means: read the advice and take the cheaper path unless you have a
  reason not to. `deny` means: do the freeing step first, or ask the human.
- Run `~/.redline/bin/redline status` for a fresh line (`--json` for structured). If only the Claude
  plugin is installed, that path doesn't exist; the session-start line is then your latest reading.

## Situations

**Booting a simulator or emulator**
- Why: an iOS Simulator commonly holds 5–9 GB and keeps background apps running; an Android
  emulator 2–4 GB. Two at once on 16 GB freezes the machine.
- Cheaper path: verify on web / Expo web / unit tests first. If a device is already booted, reuse it.
  One device at a time.
- Cleanup: `xcrun simctl shutdown all` · `adb emu kill`. Do it when you finish, not "later".
- Check: `xcrun simctl list devices booted` · `adb devices` · `pgrep -fl qemu-system`.

**Gradle / Android builds**
- Why: the Gradle daemon stays resident (1–2 GB+) after the build.
- Cheaper path: `--no-daemon` for one-off builds, or `./gradlew --stop` afterwards.

**Containers (docker compose, supabase start, colima, minikube)**
- Why: the VM reserves memory up front, and every service you start adds to it.
- Cheaper path: start only the services you need (`docker compose up db api`); stop with
  `docker compose down` when done. On a remote dev host, run them there.

**Dev servers**
- Why: a second server on a busy port fails or silently binds another port; you then test the
  wrong one. Long-running foreground servers block your shell.
- Cheaper path: check the port first (`lsof -iTCP:<port> -sTCP:LISTEN` / `ss -ltnp` /
  `Get-NetTCPConnection -LocalPort <port>`); reuse a running server. Start new ones in the
  background and poll the port instead of waiting on the process.

**Watch mode and interactive commands**
- Why: `--watch`, `nodemon`, `tsc -w`, `vim`, `less`, `git rebase -i` never return. You wait forever.
- Cheaper path: run once (`vitest run`, `jest --watchAll=false`, `CI=1`), use non-interactive flags
  (`git rebase` with a prepared todo, `GIT_EDITOR=true`, `--yes`, `-y`), pipe pagers (`| cat`,
  `GIT_PAGER=cat`).

**Installs and builds on a full disk**
- Why: below ~3 GB free, installs fail half-way and leave corrupt caches; swap can't grow and the
  OS stalls.
- Cheaper path: free space first. Check what is big before deleting anything; only delete what you
  created or what is clearly a cache (package-manager caches, build outputs,
  `docker system prune` after asking).

**A command seems stuck**
- Check before retrying: is memory critical (`redline status`)? Is it waiting for input? Is it a
  watch/server process that will never exit? Retrying a command that is stuck on memory pressure
  makes things worse.

## Platform notes

- macOS: `memory_pressure`, `vm_stat`, `sysctl vm.swapusage`. Activity Monitor's "Memory
  Pressure" graph is the truth; free memory alone is not.
- Linux: `free -h`, `cat /proc/pressure/memory` (`full avg10` > 20 means real stalls),
  `systemd-cgtop` for containers.
- Windows: `Get-Counter '\Memory\Available MBytes'`, Task Manager → Performance. WSL2's VM
  (`vmmem`) can hold a lot of memory; `wsl --shutdown` releases it (ask first).

## Rules of thumb

1. Before starting something heavy, look (`redline status`). Don't trust what you remember.
2. Reuse before you start: devices, servers, containers.
3. You stop what you start, as soon as you're done with it. Write in your final message what you
   left running.
4. Never kill something you didn't start without asking.
5. When redline advises, either follow it or say why not. Don't ignore it silently.
