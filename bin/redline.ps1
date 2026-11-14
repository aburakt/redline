# redline.ps1 - PowerShell twin of bin/redline (Windows PowerShell 5.1+ and pwsh 7).
# Same subcommands, same output. No dependencies.
#   redline.ps1 status [--json] | check -- <command> | hook <agent> <event> | probe
# ASCII-only source on purpose: PowerShell 5.1 misreads BOM-less UTF-8 literals.

$Sw = [Diagnostics.Stopwatch]::StartNew()
$Prof = [bool][Environment]::GetEnvironmentVariable('REDLINE_PROFILE')
function Prof([string]$label) { if ($Prof) { [Console]::Error.WriteLine('profile ' + $label + ' ' + $Sw.ElapsedMilliseconds + ' ms') } }
$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Utf8 = [System.Text.UTF8Encoding]::new($false)   # ::new, not New-Object: New-Object auto-loads a module
$Dot = ' ' + [string][char]0x00B7 + ' '
# The hot path avoids cmdlets that trigger module auto-loading (Join-Path, Test-Path, ConvertFrom-Json,
# Sort-Object, ...): each costs 100+ ms on Windows. Plain .NET calls, except in the background probe.
$Self = $MyInvocation.MyCommand.Path
$Root = [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($Self))
$RulesDir = [IO.Path]::Combine($Root, 'rules')

function EnvOr([string]$name, $def) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if ([string]::IsNullOrEmpty($v)) { return $def }
  return $v
}

# Windows probes are expensive (CIM queries take seconds of CPU), so the cache lives longer here.
# Numbers from env are parsed leniently ("25%" -> 25) and never throw: a hook must not fail on config.
function EnvNum([string]$name, [double]$def) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if ([string]::IsNullOrEmpty($v)) { return $def }
  $mt = [regex]::Match($v, '^\s*\d+(\.\d+)?')
  if ($mt.Success) { return [double]::Parse($mt.Value.Trim(), [Globalization.CultureInfo]::InvariantCulture) }
  return $def
}
$Ttl = [int](EnvNum 'REDLINE_TTL' 30)
$MemWarn = EnvNum 'REDLINE_MEM_WARN_PCT' 25
$MemCrit = EnvNum 'REDLINE_MEM_CRIT_PCT' 10
$DiskWarn = EnvNum 'REDLINE_DISK_WARN_GB' 10
$DiskCrit = EnvNum 'REDLINE_DISK_CRIT_GB' 3
$CpuWarn = EnvNum 'REDLINE_CPU_WARN' 2
$PortsScan = @(3000, 3001, 4321, 5173, 8000, 8080, 8081, 8787, 19000)
$Off = (EnvOr 'REDLINE' '') -eq 'off'

# Raw UTF-8 bytes to stdout: no console code-page switching (slow, and wrong on legacy consoles).
$StdOut = [Console]::OpenStandardOutput()
function Write-Out([string]$s) { $b = $Utf8.GetBytes($s + "`n"); $StdOut.Write($b, 0, $b.Length); $StdOut.Flush() }
function F1($x) { return ([double]$x).ToString('0.0', $Inv) }
function Num([string]$s) { return [double]::Parse($s, $Inv) }
function NumStr([string]$s) { return (Num $s).ToString($Inv) }   # like awk (x + 0)

function Get-CacheDir {
  $d = EnvOr 'REDLINE_CACHE_DIR' ''
  if ($d) { return $d }
  $t = $env:TEMP
  if (-not $t) { $t = [IO.Path]::GetTempPath() }
  return [IO.Path]::Combine($t, 'redline')
}

function Read-Tsv([string]$file) {
  $rows = @()
  foreach ($l in [IO.File]::ReadAllLines([IO.Path]::Combine($RulesDir, $file), $Utf8)) {
    if ($l) { $rows += , ($l -split "`t") }
  }
  return , $rows
}

function Get-Groups {
  $out = @()
  foreach ($f in (Read-Tsv 'groups.tsv')) {
    if ($f.Count -ge 3 -and $f[0]) { $out += [pscustomobject]@{ name = $f[0]; re = $f[1]; free = $f[2] } }
  }
  return , $out
}

# ---------- probing ----------

function Invoke-Probe {
  $m = [ordered]@{}
  try {
    $os = Get-CimInstance Win32_OperatingSystem
    $m['mem_avail_pct'] = [string][math]::Floor([double]$os.FreePhysicalMemory * 100 / [double]$os.TotalVisibleMemorySize)
  } catch {}
  $m['pressure'] = 'normal'
  try {
    $u = 0.0
    foreach ($p in @(Get-CimInstance Win32_PageFileUsage)) { $u += [double]$p.CurrentUsage }
    $m['swap_gb'] = F1 ($u / 1024)
  } catch {}
  try {
    $cpu = @(Get-CimInstance Win32_Processor); $s = 0.0
    foreach ($c in $cpu) { $s += [double]$c.LoadPercentage }
    # approximation: 100% busy ~ load 2.0 per core (warn level)
    $m['load_per_core'] = F1 (($s / $cpu.Count) / 50)
  } catch {}
  try {
    $drv = Get-PSDrive -Name ($HOME.Substring(0, 1))
    $m['disk_free_gb'] = [string][math]::Floor([double]$drv.Free / 1073741824)
  } catch {}
  $groups = Get-Groups; $kb = @{}
  try {
    foreach ($p in @(Get-CimInstance Win32_Process)) {
      $c = [string]$p.CommandLine
      if (-not $c) { $c = [string]$p.ExecutablePath }
      if (-not $c) { $c = [string]$p.Name }
      foreach ($g in $groups) {
        if ($c -cmatch $g.re) { $kb[$g.name] = [double]$kb[$g.name] + [double]$p.WorkingSetSize / 1024; break }
      }
    }
  } catch {}
  $parts = @()
  foreach ($g in $groups) { if ([double]$kb[$g.name] -gt 0) { $parts += ($g.name + ':' + [math]::Floor([double]$kb[$g.name] / 1024)) } }
  $m['procs'] = $parts -join ','
  $found = @()
  try { $found = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | ForEach-Object { [int]$_.LocalPort }) }
  catch {
    try { $found = @(netstat -ano -p tcp | Select-String 'LISTENING' | ForEach-Object { if ("$_" -match ':(\d+)\s') { [int]$matches[1] } }) } catch {}
  }
  $m['ports'] = (@($PortsScan | Where-Object { $found -contains $_ } | Sort-Object)) -join ','
  $m['ts'] = [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  return $m
}

function Test-Fakes {
  foreach ($k in [Environment]::GetEnvironmentVariables().Keys) { if ($k -like 'REDLINE_FAKE_*' -and $k -ne 'REDLINE_FAKE_UNAME') { return $true } }
  return $false
}

function Get-FakeMetrics {
  $m = [ordered]@{}
  $v = EnvOr 'REDLINE_FAKE_MEM_AVAIL_PCT' ''; if ($v) { $m['mem_avail_pct'] = $v }
  $m['pressure'] = EnvOr 'REDLINE_FAKE_PRESSURE' 'normal'
  $v = EnvOr 'REDLINE_FAKE_SWAP_GB' ''; if ($v) { $m['swap_gb'] = $v }
  $v = EnvOr 'REDLINE_FAKE_DISK_FREE_GB' ''; if ($v) { $m['disk_free_gb'] = $v }
  $v = EnvOr 'REDLINE_FAKE_LOAD_PER_CORE' ''; if ($v) { $m['load_per_core'] = $v }
  $m['procs'] = EnvOr 'REDLINE_FAKE_PROCS' ''
  $m['ports'] = EnvOr 'REDLINE_FAKE_PORTS' ''
  return $m
}

function ConvertTo-Kv($m) { return (($m.Keys | ForEach-Object { $_ + '=' + $m[$_] }) -join "`n") + "`n" }

function ConvertFrom-Kv([string]$text) {
  $m = [ordered]@{}
  foreach ($l in ($text -split "`n")) {
    $i = $l.IndexOf('=')
    if ($i -gt 0) { $m[$l.Substring(0, $i)] = $l.Substring($i + 1).TrimEnd("`r") }
  }
  return $m
}

# Probes, writes the cache atomically (tmp + replace), returns the metrics.
function Write-Cache {
  $m = Invoke-Probe
  $dir = Get-CacheDir
  $tmp = [IO.Path]::Combine($dir, 'metrics.' + $PID); $f = [IO.Path]::Combine($dir, 'metrics')
  try {
    [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText($tmp, (ConvertTo-Kv $m), $Utf8)
    if ([IO.File]::Exists($f)) { [IO.File]::Replace($tmp, $f, $null) } else { [IO.File]::Move($tmp, $f) }
  } catch { try { [IO.File]::Delete($tmp) } catch {} }
  try { [IO.File]::Delete([IO.Path]::Combine($dir, 'lock')) } catch {}
  return $m
}

# One background refresh at a time (exclusive lock file; locks older than 60 s are broken).
function Start-Refresh([string]$dir) {
  $lock = [IO.Path]::Combine($dir, 'lock')
  try {
    if ([IO.File]::Exists($lock) -and ([DateTime]::UtcNow - [IO.File]::GetLastWriteTimeUtc($lock)).TotalSeconds -gt 60) { [IO.File]::Delete($lock) }
    $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew); $fs.Close()
  } catch { return }
  try {
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Self + '" probe'
    # ShellExecute: the child must NOT inherit our stdout handle, or the agent waits for the probe.
    $psi.UseShellExecute = $true; $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    [void][Diagnostics.Process]::Start($psi)
  } catch { try { [IO.File]::Delete($lock) } catch {} }
}

# Only well-formed values pass: the cache is data, never text that may reach the agent's context.
$Valid = @{
  mem_avail_pct = '^\d+$'; ts = '^\d+$'; pressure = '^(normal|warn|critical)$'
  swap_gb = '^\d+(\.\d+)?$'; disk_free_gb = '^\d+(\.\d+)?$'; load_per_core = '^\d+(\.\d+)?$'
  procs = '^([a-z-]+:\d+(,[a-z-]+:\d+)*)?$'; ports = '^(\d+(,\d+)*)?$'
}
function Get-Metrics {
  $raw = Get-RawMetrics; $m = [ordered]@{}
  foreach ($k in $raw.Keys) { if ($Valid.ContainsKey($k) -and ([string]$raw[$k]) -cmatch $Valid[$k]) { $m[$k] = [string]$raw[$k] } }
  return $m
}

function Get-RawMetrics {
  if (Test-Fakes) { return Get-FakeMetrics }
  $dir = Get-CacheDir; $f = [IO.Path]::Combine($dir, 'metrics')
  $m = $null
  try { if ([IO.File]::Exists($f)) { $m = ConvertFrom-Kv ([IO.File]::ReadAllText($f, $Utf8)) } } catch { $m = $null }
  if ($m -and $m['ts']) {
    $ts = 0L; [void][long]::TryParse([string]$m['ts'], [ref]$ts)
    if (([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $ts) -gt $Ttl) { Start-Refresh $dir }
    return $m
  }
  return Write-Cache
}

# ---------- evaluation ----------

function Get-State {
  $m = Get-Metrics
  Prof 'metrics'
  $free = @{}
  foreach ($g in (Get-Groups)) { $free[$g.name] = $g.free }
  $s = @{ m = $m; heavy = @() }
  if ($m.Contains('mem_avail_pct')) {
    $a = Num $m['mem_avail_pct']; $p = $m['pressure']
    if ($a -lt $MemCrit -or $p -eq 'critical') { $s.mem = 'critical' }
    elseif ($a -lt $MemWarn -or $p -eq 'warn') { $s.mem = 'warn' }
    else { $s.mem = 'ok' }
  }
  if ($m.Contains('disk_free_gb')) {
    $d = Num $m['disk_free_gb']
    if ($d -lt $DiskCrit) { $s.disk = 'critical' } elseif ($d -lt $DiskWarn) { $s.disk = 'warn' } else { $s.disk = 'ok' }
  }
  if ($m.Contains('load_per_core')) { if ((Num $m['load_per_core']) -ge $CpuWarn) { $s.cpu = 'warn' } else { $s.cpu = 'ok' } }
  $h = @()
  if ($m['procs']) {
    foreach ($pair in ($m['procs'] -split ',')) {
      $f = $pair -split ':'
      if ($f.Count -ge 2 -and (Num $f[1]) -ge 300) { $h += [pscustomobject]@{ group = $f[0]; mb = [long](Num $f[1]); free = $free[$f[0]] } }
    }
  }
  for ($i = 0; $i -lt $h.Count; $i++) { for ($j = $i + 1; $j -lt $h.Count; $j++) { if ($h[$j].mb -gt $h[$i].mb) { $t = $h[$i]; $h[$i] = $h[$j]; $h[$j] = $t } } }
  $s.heavy = $h
  return $s
}

function JStr([string]$s) {
  return '"' + $s.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`t", '\t').Replace("`r", '\r') + '"'
}

function Get-StatusJson {
  $s = Get-State; $m = $s.m; $o = @()
  if ($m.Contains('mem_avail_pct')) { $o += '"mem":{"avail_pct":' + (NumStr $m['mem_avail_pct']) + ',"level":"' + $s.mem + '"}' }
  if ($m.Contains('swap_gb')) { $o += '"swap_gb":' + $m['swap_gb'] }
  if ($m.Contains('disk_free_gb')) { $o += '"disk":{"free_gb":' + (NumStr $m['disk_free_gb']) + ',"level":"' + $s.disk + '"}' }
  if ($m.Contains('load_per_core')) { $o += '"cpu":{"load_per_core":' + $m['load_per_core'] + ',"level":"' + $s.cpu + '"}' }
  $h = @($s.heavy | ForEach-Object { '{"group":' + (JStr $_.group) + ',"mb":' + $_.mb + ',"free":' + (JStr $_.free) + '}' })
  $o += '"heavy":[' + ($h -join ',') + ']'
  $o += '"ports":[' + $m['ports'] + ']'
  return '{' + ($o -join ',') + '}'
}

function Tag($l) { if ($l -eq 'warn') { return ' (WARN)' } elseif ($l -eq 'critical') { return ' (CRITICAL)' } else { return '' } }

function Get-StatusLine {
  $s = Get-State; $m = $s.m; $o = @()
  if ($m.Contains('mem_avail_pct')) { $o += 'mem ' + (NumStr $m['mem_avail_pct']) + '% free' + (Tag $s.mem) }
  if ($m.Contains('swap_gb')) { $o += 'swap ' + $m['swap_gb'] + 'G' }
  if ($m.Contains('disk_free_gb')) { $o += 'disk ' + (NumStr $m['disk_free_gb']) + 'G free' + (Tag $s.disk) }
  if ($s.cpu -eq 'warn') { $o += 'load ' + (F1 (Num $m['load_per_core'])) + '/core (WARN)' }
  if ($s.heavy.Count -eq 0) { $o += 'nothing heavy running' }
  else { $o += 'heavy: ' + ((@($s.heavy | ForEach-Object { $_.group + ' ' + (F1 ($_.mb / 1000)) + 'G' })) -join ', ') }
  if ($m['ports']) { $o += 'ports ' + $m['ports'] }
  return 'redline: ' + ($o -join $Dot)
}

# ---------- check ----------

function Test-Bad($l) { return ($l -eq 'warn' -or $l -eq 'critical') }

# Returns @(verdict, message).
function Invoke-Check([string]$cmd) {
  if ($Off) { return @('ok', '') }
  $s = Get-State; $m = $s.m
  $script:sum = [System.Collections.ArrayList]::new()
  function AddSum([string]$x) { if (-not $script:sum.Contains($x)) { [void]$script:sum.Add($x) } }
  $verdict = 0; $adv = [System.Collections.ArrayList]::new()
  foreach ($r in (Read-Tsv 'rules.tsv')) {
    if ($r.Count -lt 4) { continue }
    if (-not ($cmd -cmatch $r[2])) { continue }
    $when = $r[1]; $hit = 0
    if ($when -eq 'always') { $hit = 1 }
    elseif ($when.StartsWith('running:')) {
      $g = $when.Substring(8)
      foreach ($x in $s.heavy) { if ($x.group -eq $g) { $hit = 1 } }
    }
    elseif ($when -eq 'ports') { if ($m['ports']) { $hit = 1; AddSum ('listening: ' + $m['ports']) } }
    elseif ($when -eq 'pressure') {
      if ($s.mem -eq 'critical' -or $s.disk -eq 'critical') { $hit = 2 }
      elseif ((Test-Bad $s.mem) -or (Test-Bad $s.disk) -or $s.cpu -eq 'warn') { $hit = 1 }
      if ($hit) {
        if (Test-Bad $s.mem) { AddSum ('memory ' + $s.mem + ', ' + (NumStr $m['mem_avail_pct']) + '% free') }
        if (Test-Bad $s.disk) { AddSum ('disk ' + $s.disk + ', ' + (NumStr $m['disk_free_gb']) + 'G free') }
        if ($s.cpu -eq 'warn') { AddSum ('load ' + (F1 (Num $m['load_per_core'])) + '/core') }
        if ($s.heavy.Count -gt 0) { $t = $s.heavy[0]; AddSum ('top: ' + $t.group + ' ' + (F1 ($t.mb / 1000)) + 'G (free: ' + $t.free + ')') }
      }
    }
    elseif ($when -eq 'disk') {
      if ($s.disk -eq 'critical') { $hit = 2 } elseif ($s.disk -eq 'warn') { $hit = 1 }
      if ($hit) { AddSum ('disk ' + $s.disk + ', ' + (NumStr $m['disk_free_gb']) + 'G free') }
    }
    if (-not $hit) { continue }
    if ($hit -gt $verdict) { $verdict = $hit }
    if (-not $adv.Contains($r[3])) { [void]$adv.Add($r[3]) }
  }
  if ($verdict -eq 0) { return @('ok', '') }
  $msg = 'redline: '
  if ($script:sum.Count -gt 0) { $msg += ($script:sum -join '; ') + '. ' }
  $msg += ($adv -join ' | ')
  if ($verdict -eq 2) { return @('deny', $msg) } else { return @('advise', $msg) }
}

# ---------- hooks ----------

# First "command" string value (same algorithm as the sh version; no ConvertFrom-Json in the hot path).
function Read-JsonCommand([string]$s) {
  $mt = [regex]::Match($s, '"command"\s*:\s*"((?:[^"\\]|\\.)*)')
  if (-not $mt.Success) { return '' }
  return (Unescape-Json $mt.Groups[1].Value)
}

function Unescape-Json([string]$v) {
  if ($v.IndexOf('\') -lt 0) { return $v }
  return [regex]::Replace($v, '\\(u[0-9a-fA-F]{4}|.)', {
      param($x)
      $e = $x.Groups[1].Value
      if ($e -eq 'n') { return "`n" } elseif ($e -eq 't') { return "`t" } elseif ($e -eq 'r') { return '' }
      elseif ($e.Length -eq 5) { return '?' } else { return $e }
    })
}

# Also handles a JSON-string-encoded args object (Copilot toolArgs): unescape once, retry.
function Get-PayloadCommand([string]$raw) {
  $c = Read-JsonCommand $raw
  if (-not $c -and $raw.Contains('\"command\"')) { $c = Read-JsonCommand (Unescape-Json $raw) }
  if ($c.Length -gt 4000) { $c = $c.Substring(0, 4000) }
  return $c
}

function Get-OkOut($agent, $ev) { if ($agent -eq 'cursor' -and $ev -eq 'pre') { return '{"permission":"allow"}' } return '' }

function Invoke-Hook([string]$agent, [string]$ev) {
  if (@('claude', 'codex', 'cursor', 'gemini', 'copilot') -notcontains $agent) { throw 'agent' }
  $raw = ''
  try { $raw = [IO.StreamReader]::new([Console]::OpenStandardInput(), $Utf8).ReadToEnd() } catch {}
  switch ($ev) {
    'start' {
      if ($Off) { return '' }
      $l = JStr (Get-StatusLine)
      if ($agent -eq 'cursor') { return '{"additional_context":' + $l + '}' }
      if ($agent -eq 'copilot') { return '{"additionalContext":' + $l + '}' }
      return '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":' + $l + '}}'
    }
    'pre' {
      $c = Get-PayloadCommand $raw
      if (-not $c) { return (Get-OkOut $agent 'pre') }
      Prof 'payload'
      $res = Invoke-Check $c; $msg = $res[1]; $j = JStr $msg
      Prof 'check'
      if ($res[0] -eq 'advise') {
        if ($agent -eq 'claude' -or $agent -eq 'codex') { return '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":' + $j + '}}' }
        if ($agent -eq 'cursor') { return '{"permission":"allow","agent_message":' + $j + '}' }
        if ($agent -eq 'gemini') {
          $d = Get-CacheDir
          [void][IO.Directory]::CreateDirectory($d)
          [IO.File]::WriteAllText([IO.Path]::Combine($d, 'pending-gemini'), $msg, $Utf8)
        }
        return ''
      }
      if ($res[0] -eq 'deny') {
        if ($agent -eq 'claude' -or $agent -eq 'codex') { return '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":' + $j + '}}' }
        if ($agent -eq 'cursor') { return '{"permission":"deny","user_message":' + $j + ',"agent_message":' + $j + '}' }
        if ($agent -eq 'gemini') { return '{"decision":"deny","reason":' + $j + '}' }
        return '{"permissionDecision":"deny","permissionDecisionReason":' + $j + '}'
      }
      return (Get-OkOut $agent 'pre')
    }
    'post' {
      $f = [IO.Path]::Combine((Get-CacheDir), 'pending-gemini')
      if ($agent -eq 'gemini' -and [IO.File]::Exists($f)) {
        $j = JStr ([IO.File]::ReadAllText($f, $Utf8)); [IO.File]::Delete($f)
        return '{"hookSpecificOutput":{"hookEventName":"AfterTool","additionalContext":' + $j + '}}'
      }
      return ''
    }
    default { throw 'event' }
  }
}

# ---------- main ----------

Prof 'init'

$argv = @($args)
$sub = 'status'
if ($argv.Count -gt 0) { $sub = [string]$argv[0] }
$rest = @()
if ($argv.Count -gt 1) { $rest = @($argv[1..($argv.Count - 1)]) }

try {
switch ($sub) {
  'probe' { [void](Write-Cache); exit 0 }
  'status' {
    if ($Off) { exit 0 }
    if ($rest.Count -gt 0 -and $rest[0] -eq '--json') { Write-Out (Get-StatusJson) } else { Write-Out (Get-StatusLine) }
    exit 0
  }
  'check' {
    if ($rest.Count -gt 0 -and $rest[0] -eq '--') { if ($rest.Count -gt 1) { $rest = @($rest[1..($rest.Count - 1)]) } else { $rest = @() } }
    $res = Invoke-Check ($rest -join ' ')
    Write-Out $res[0]
    if ($res[0] -ne 'ok') { Write-Out $res[1] }
    exit 0
  }
  'hook' {
    $agent = ''; $ev = ''
    if ($rest.Count -gt 0) { $agent = [string]$rest[0] }
    if ($rest.Count -gt 1) { $ev = [string]$rest[1] }
    $out = ''
    try { $out = Invoke-Hook $agent $ev } catch { $out = Get-OkOut $agent $ev }
    if ($out) { Write-Out $out }
    Prof 'done'
    exit 0
  }
  default { [Console]::Error.WriteLine('usage: redline status [--json] | check -- <command> | hook <agent> <event> | probe'); exit 64 }
}
} catch {
  # fail open: a broken hook must never block the agent (Copilot treats non-zero as deny)
  if ($sub -eq 'hook') {
    $a = ''; $e = ''; if ($rest.Count -gt 0) { $a = [string]$rest[0] }; if ($rest.Count -gt 1) { $e = [string]$rest[1] }
    try { $o = Get-OkOut $a $e; if ($o) { Write-Out $o } } catch {}
    exit 0
  }
  [Console]::Error.WriteLine('redline: ' + $_.Exception.Message); exit 1
}
