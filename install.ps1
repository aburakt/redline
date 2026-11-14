# redline installer (Windows). User-level config only; never touches project files.
#   powershell -ExecutionPolicy Bypass -File install.ps1 [--dry-run] [--uninstall] [--agents claude,codex,cursor,gemini,copilot]
# Every edited file is backed up first: <file>.redline-bak-<unix-time>.

$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $Utf8 } catch {}
$Src = Split-Path -Parent $MyInvocation.MyCommand.Path
$H = [Environment]::GetEnvironmentVariable('USERPROFILE'); if (-not $H) { $H = $HOME }
$Dest = Join-Path $H '.redline'
$Dry = $false; $Uninstall = $false; $Agents = ''
$argv = @($args)
for ($i = 0; $i -lt $argv.Count; $i++) {
  switch ($argv[$i]) {
    '--dry-run' { $Dry = $true }
    '--uninstall' { $Uninstall = $true }
    '--agents' {
      $i++
      if ($i -ge $argv.Count -or ([string]$argv[$i]).StartsWith('-') -or -not $argv[$i]) { [Console]::Error.WriteLine('--agents needs a comma-separated list, e.g. --agents codex,cursor'); exit 64 }
      $Agents = [string]$argv[$i]
    }
    default { [Console]::Error.WriteLine("unknown option: $($argv[$i])"); exit 64 }
  }
}
$ClaudeBin = $env:REDLINE_CLAUDE_BIN; if (-not $ClaudeBin) { $ClaudeBin = 'claude' }
$ClaudeSrc = $env:REDLINE_CLAUDE_SOURCE; if (-not $ClaudeSrc) { $ClaudeSrc = 'aburakt/redline' }
$Mark = 'bin[\\/]+redline|redline\.ps1'
$Ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

function Say([string]$s) { [Console]::Out.WriteLine($s) }
function CmdFor($agent, $ev) { return ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Dest 'bin\redline.ps1') + '" hook ' + $agent + ' ' + $ev) }
function Has-Claude { return [bool](Get-Command $ClaudeBin -ErrorAction SilentlyContinue) }

if (-not $Agents) {
  $list = @()
  if ((Has-Claude) -or (Test-Path (Join-Path $H '.claude'))) { $list += 'claude' }
  foreach ($a in 'codex', 'cursor', 'gemini', 'copilot') { if (Test-Path (Join-Path $H ".$a")) { $list += $a } }
  $Agents = $list -join ','
}

function To-Native($o) {
  if ($null -eq $o) { return $null }
  if ($o -is [System.Management.Automation.PSCustomObject]) {
    $h = [ordered]@{}
    foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = To-Native $p.Value }
    return $h
  }
  if ($o -is [System.Collections.IEnumerable] -and -not ($o -is [string]) -and -not ($o -is [System.Collections.IDictionary])) {
    $a = New-Object System.Collections.ArrayList
    foreach ($x in $o) { [void]$a.Add((To-Native $x)) }
    return , $a
  }
  return $o
}

function List { param([object[]]$items) $a = New-Object System.Collections.ArrayList; foreach ($x in $items) { [void]$a.Add($x) }; return , $a }

function Group-Entry($matcher, $agent, $ev, $timeout) {
  $g = [ordered]@{}
  if ($matcher) { $g['matcher'] = $matcher }
  $g['hooks'] = List @([ordered]@{ type = 'command'; command = (CmdFor $agent $ev); timeout = $timeout })
  return $g
}

# Apply-Patch <file> <ordered dict event -> ArrayList of entries> <want version>
function Apply-Patch([string]$f, $patch, [bool]$ver) {
  if ($Uninstall -and -not (Test-Path $f)) { return }
  $d = [ordered]@{}
  if (Test-Path $f) {
    $raw = [IO.File]::ReadAllText($f, $Utf8)
    if ($raw.Trim()) {
      try { $d = To-Native ($raw | ConvertFrom-Json) } catch { Say "! could not parse $f; left untouched"; return }
    }
  }
  if ($ver -and -not $d.Contains('version')) { $d['version'] = 1 }
  $hooks = [ordered]@{}
  if ($d.Contains('hooks') -and $d['hooks']) {
    foreach ($k in @($d['hooks'].Keys)) {
      $keep = New-Object System.Collections.ArrayList
      foreach ($x in $d['hooks'][$k]) {
        # filter individual hooks, not whole matcher groups: a user hook sharing a group survives
        if ($x -is [System.Collections.IDictionary] -and $x.Contains('hooks') -and $x['hooks'] -is [System.Collections.IEnumerable]) {
          $inner = [System.Collections.ArrayList]::new()
          foreach ($y in $x['hooks']) { if (-not ((ConvertTo-Json $y -Depth 20 -Compress) -match $Mark)) { [void]$inner.Add($y) } }
          $x['hooks'] = $inner
          if ($inner.Count -gt 0) { [void]$keep.Add($x) }
        }
        elseif (-not ((ConvertTo-Json $x -Depth 20 -Compress) -match $Mark)) { [void]$keep.Add($x) }
      }
      $hooks[$k] = $keep
    }
  }
  if (-not $Uninstall) {
    foreach ($k in $patch.Keys) {
      if (-not $hooks.Contains($k)) { $hooks[$k] = New-Object System.Collections.ArrayList }
      foreach ($x in $patch[$k]) { [void]$hooks[$k].Add($x) }
    }
  }
  $clean = [ordered]@{}
  foreach ($k in $hooks.Keys) { if ($hooks[$k].Count -gt 0) { $clean[$k] = $hooks[$k] } }
  $d['hooks'] = $clean
  $json = ConvertTo-Json $d -Depth 20
  if ($Dry) { Say "--- would write ${f}:"; Say $json; return }
  if (Test-Path $f) { Copy-Item $f "$f.redline-bak-$Ts" }
  $dir = Split-Path -Parent $f
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $isLink = (Test-Path $f) -and ((Get-Item $f -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
  if ($isLink) { [IO.File]::WriteAllText($f, $json + "`n", $Utf8) }   # keep dotfile symlinks
  else { [IO.File]::WriteAllText("$f.redline-tmp", $json + "`n", $Utf8); Move-Item -Force "$f.redline-tmp" $f }
  if ($Uninstall) { Say "OK uninstall $f" } else { Say "OK install $f" }
}

function Do-Codex {
  $p = [ordered]@{ SessionStart = (List @(Group-Entry '' codex start 10)); PreToolUse = (List @(Group-Entry '^Bash$' codex pre 10)) }
  Apply-Patch (Join-Path $H '.codex\hooks.json') $p $false
  if (-not $Uninstall) { Say '  codex: review and trust the new hooks once (codex asks on next start, or /hooks).' }
}
function Do-Cursor {
  $p = [ordered]@{
    sessionStart = (List @([ordered]@{ command = (CmdFor cursor start); timeout = 10 }))
    beforeShellExecution = (List @([ordered]@{ command = (CmdFor cursor pre); timeout = 10 }))
  }
  Apply-Patch (Join-Path $H '.cursor\hooks.json') $p $true
}
function Do-Gemini {
  $p = [ordered]@{
    SessionStart = (List @(Group-Entry '' gemini start 10000))
    BeforeTool = (List @(Group-Entry 'run_shell_command' gemini pre 10000))
    AfterTool = (List @(Group-Entry 'run_shell_command' gemini post 10000))
  }
  Apply-Patch (Join-Path $H '.gemini\settings.json') $p $false
}
function Do-Copilot {
  $f = Join-Path $H '.copilot\hooks\redline.json'
  if ($Uninstall) {
    if (Test-Path $f) { if ($Dry) { Say "--- would remove $f" } else { Remove-Item -Force $f; Say "OK removed $f" } }
    return
  }
  $body = [ordered]@{ version = 1; hooks = [ordered]@{
      sessionStart = (List @([ordered]@{ type = 'command'; powershell = (CmdFor copilot start); timeoutSec = 10 }))
      preToolUse = (List @([ordered]@{ type = 'command'; powershell = (CmdFor copilot pre); timeoutSec = 10 }))
    } }
  $json = ConvertTo-Json $body -Depth 20
  if ($Dry) { Say "--- would write ${f}:"; Say $json; return }
  $dir = Split-Path -Parent $f
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [IO.File]::WriteAllText($f, $json + "`n", $Utf8); Say "OK install $f"
}
function Do-Claude {
  if ((Has-Claude) -and -not $Dry) {
    if ($Uninstall) { & $ClaudeBin plugin uninstall redline@redline }
    else { & $ClaudeBin plugin marketplace add $ClaudeSrc; & $ClaudeBin plugin install redline@redline }
  }
  elseif ($Uninstall) { Say 'claude: run  claude plugin uninstall redline@redline' }
  else { Say "claude: run  claude plugin marketplace add $ClaudeSrc  &&  claude plugin install redline@redline" }
}

if (-not $Dry -and -not $Uninstall) {
  New-Item -ItemType Directory -Force -Path (Join-Path $Dest 'bin'), (Join-Path $Dest 'rules') | Out-Null
  Copy-Item (Join-Path $Src 'bin\redline'), (Join-Path $Src 'bin\redline.ps1') (Join-Path $Dest 'bin') -Force
  Copy-Item (Join-Path $Src 'rules\*.tsv') (Join-Path $Dest 'rules') -Force
  Say "OK copied redline to $Dest"
}

Say "agents: $Agents  (json engine: native)"
foreach ($a in ($Agents -split ',')) {
  switch ($a) {
    'claude' { Do-Claude } 'codex' { Do-Codex } 'cursor' { Do-Cursor } 'gemini' { Do-Gemini } 'copilot' { Do-Copilot }
    '' {}
    default { Say "! unknown agent: $a" }
  }
}
if ($Uninstall -and -not $Dry -and (Test-Path $Dest)) { Remove-Item -Recurse -Force $Dest; Say "OK removed $Dest" }
exit 0
