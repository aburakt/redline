#!/bin/sh
# redline installer (macOS / Linux). User-level config only; never touches project files.
#   sh install.sh [--dry-run] [--uninstall] [--agents claude,codex,cursor,gemini,copilot]
# Merges hooks with jq, python3 or node if one exists; otherwise prints what to add.
# Every edited file is backed up first: <file>.redline-bak-<unix-time>.
set -u

SRC=$(cd "$(dirname "$0")" && pwd)
DEST="$HOME/.redline"
DRY=0; UNINSTALL=0; AGENTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --agents)
      shift
      case "${1:-}" in "" | -*) echo "--agents needs a comma-separated list, e.g. --agents codex,cursor" >&2; exit 64 ;; esac
      AGENTS=$1 ;;
    -h | --help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

CLAUDE_BIN=${REDLINE_CLAUDE_BIN:-claude}
CLAUDE_SRC=${REDLINE_CLAUDE_SOURCE:-aburakt/redline}
MARK='bin/redline|redline\.ps1'
TS=$(date +%s)

say() { printf '%s\n' "$*"; }
q() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }   # JSON-escape (no quotes)
cmd_for() { printf "sh '%s/bin/redline' hook %s %s" "$DEST" "$1" "$2"; }

if [ -z "$AGENTS" ]; then
  { command -v "$CLAUDE_BIN" >/dev/null 2>&1 || [ -d "$HOME/.claude" ]; } && AGENTS="claude"
  for a in codex cursor gemini copilot; do [ -d "$HOME/.$a" ] && AGENTS="$AGENTS,$a"; done
  AGENTS=${AGENTS#,}
fi

engine() {
  e=${REDLINE_MERGE:-}
  if [ -z "$e" ]; then
    for c in jq python3 node; do command -v "$c" >/dev/null 2>&1 && { e=$c; break; }; done
  fi
  [ -z "$e" ] && e=none
  printf '%s' "$e"
}
ENGINE=$(engine)

# merge <file> <mode install|uninstall> <patch-json> <want-version 0|1>  -> prints new JSON
merge() {
  f=$1; mode=$2; patch=$3; ver=$4
  in=$(cat "$f" 2>/dev/null); [ -z "$in" ] && in='{}'
  case "$ENGINE" in
    jq)
      printf '%s' "$in" | jq --argjson p "$patch" --arg mode "$mode" --arg mark "$MARK" --argjson ver "$ver" '
        def ours: tostring | test($mark);
        # filter individual hooks, not whole matcher groups: a user hook sharing a group survives
        def clean: map(if (.hooks | type) == "array" then .hooks |= map(select(ours | not)) else . end
                       | select(if (.hooks | type) == "array" then (.hooks | length) > 0 else (ours | not) end));
        (if $ver == 1 and .version == null then .version = 1 else . end)
        | .hooks = (.hooks // {})
        | .hooks |= with_entries(.value |= clean)
        | if $mode == "install" then reduce ($p | to_entries[]) as $e (.; .hooks[$e.key] = ((.hooks[$e.key] // []) + $e.value)) else . end
        | .hooks |= with_entries(select(.value | length > 0))' ;;
    python3)
      printf '%s' "$in" | python3 -c '
import json, re, sys
d = json.load(sys.stdin); p = json.loads(sys.argv[1]); mode = sys.argv[2]; mark = re.compile(sys.argv[3]); ver = sys.argv[4] == "1"
if ver and "version" not in d: d["version"] = 1
h = d.get("hooks") or {}
def clean(v):
    out = []
    for x in v:
        if isinstance(x, dict) and isinstance(x.get("hooks"), list):
            x = dict(x, hooks=[y for y in x["hooks"] if not mark.search(json.dumps(y))])
            if x["hooks"]: out.append(x)
        elif not mark.search(json.dumps(x)): out.append(x)
    return out
h = {k: clean(v) for k, v in h.items()}
if mode == "install":
    for k, v in p.items(): h[k] = h.get(k, []) + v
d["hooks"] = {k: v for k, v in h.items() if v}
print(json.dumps(d, indent=2, ensure_ascii=False))' "$patch" "$mode" "$MARK" "$ver" ;;
    node)
      printf '%s' "$in" | node -e '
const [p, mode, mark, ver] = [JSON.parse(process.argv[1]), process.argv[2], new RegExp(process.argv[3]), process.argv[4] === "1"];
const d = JSON.parse(require("fs").readFileSync(0, "utf8"));
if (ver && d.version === undefined) d.version = 1;
const h = {};
const ours = (x) => mark.test(JSON.stringify(x));
for (const [k, v] of Object.entries(d.hooks || {}))
  h[k] = v.map((x) => (x && Array.isArray(x.hooks) ? { ...x, hooks: x.hooks.filter((y) => !ours(y)) } : x))
          .filter((x) => (x && Array.isArray(x.hooks) ? x.hooks.length > 0 : !ours(x)));
if (mode === "install") for (const [k, v] of Object.entries(p)) h[k] = (h[k] || []).concat(v);
d.hooks = Object.fromEntries(Object.entries(h).filter(([, v]) => v.length));
console.log(JSON.stringify(d, null, 2));' "$patch" "$mode" "$MARK" "$ver" ;;
    *) return 2 ;;
  esac
}

# apply <file> <patch-json> <want-version>
apply() {
  f=$1; patch=$2; ver=$3
  mode=install; [ "$UNINSTALL" = 1 ] && mode=uninstall
  if [ "$mode" = uninstall ] && [ ! -f "$f" ]; then return 0; fi
  if [ "$ENGINE" = none ]; then
    if [ "$mode" = install ]; then
      say "! no jq/python3/node found: add these hooks to $f yourself:"; say "$patch"
    else say "! no jq/python3/node found: remove redline entries from $f yourself"; fi
    return 0
  fi
  new=$(merge "$f" "$mode" "$patch" "$ver") || { say "! could not parse $f; left untouched"; return 0; }
  if [ "$DRY" = 1 ]; then say "--- would write $f:"; say "$new"; return 0; fi
  [ -f "$f" ] && cp -p "$f" "$f.redline-bak-$TS"
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$new" > "$f.redline-tmp" || return 0
  if [ -L "$f" ]; then cat "$f.redline-tmp" > "$f" && rm -f "$f.redline-tmp"   # keep dotfile symlinks
  else mv -f "$f.redline-tmp" "$f"; fi
  say "✓ $mode $f"
}

group() { # group <matcher-or-empty> <agent> <event> <timeout>
  c=$(q "$(cmd_for "$2" "$3")")
  if [ -n "$1" ]; then printf '{"matcher":"%s","hooks":[{"type":"command","command":"%s","timeout":%s}]}' "$1" "$c" "$4"
  else printf '{"hooks":[{"type":"command","command":"%s","timeout":%s}]}' "$c" "$4"; fi
}

do_codex() {
  apply "$HOME/.codex/hooks.json" "{\"SessionStart\":[$(group "" codex start 10)],\"PreToolUse\":[$(group '^Bash$' codex pre 10)]}" 0
  [ "$UNINSTALL" = 0 ] && say "  codex: review and trust the new hooks once (codex asks on next start, or /hooks)."
}
do_cursor() {
  s=$(q "$(cmd_for cursor start)"); p=$(q "$(cmd_for cursor pre)")
  apply "$HOME/.cursor/hooks.json" "{\"sessionStart\":[{\"command\":\"$s\",\"timeout\":10}],\"beforeShellExecution\":[{\"command\":\"$p\",\"timeout\":10}]}" 1
}
do_gemini() {
  apply "$HOME/.gemini/settings.json" "{\"SessionStart\":[$(group "" gemini start 10000)],\"BeforeTool\":[$(group run_shell_command gemini pre 10000)],\"AfterTool\":[$(group run_shell_command gemini post 10000)]}" 0
}
do_copilot() {
  f="$HOME/.copilot/hooks/redline.json"
  if [ "$UNINSTALL" = 1 ]; then
    [ -f "$f" ] && { if [ "$DRY" = 1 ]; then say "--- would remove $f"; else rm -f "$f"; say "✓ removed $f"; fi; }
    return 0
  fi
  s=$(q "$(cmd_for copilot start)"); p=$(q "$(cmd_for copilot pre)")
  body="{\"version\":1,\"hooks\":{\"sessionStart\":[{\"type\":\"command\",\"bash\":\"$s\",\"timeoutSec\":10}],\"preToolUse\":[{\"type\":\"command\",\"bash\":\"$p\",\"timeoutSec\":10}]}}"
  if [ "$DRY" = 1 ]; then say "--- would write $f:"; say "$body"; return 0; fi
  mkdir -p "$(dirname "$f")"; printf '%s\n' "$body" > "$f"; say "✓ install $f"
}
do_claude() {
  if command -v "$CLAUDE_BIN" >/dev/null 2>&1 && [ "$DRY" = 0 ]; then
    if [ "$UNINSTALL" = 1 ]; then "$CLAUDE_BIN" plugin uninstall redline@redline
    else "$CLAUDE_BIN" plugin marketplace add "$CLAUDE_SRC" && "$CLAUDE_BIN" plugin install redline@redline; fi
  elif [ "$UNINSTALL" = 1 ]; then say "claude: run  claude plugin uninstall redline@redline"
  else say "claude: run  claude plugin marketplace add $CLAUDE_SRC  &&  claude plugin install redline@redline"; fi
}

if [ "$DRY" = 0 ]; then
  if [ "$UNINSTALL" = 1 ]; then :
  else
    mkdir -p "$DEST/bin" "$DEST/rules"
    cp "$SRC/bin/redline" "$SRC/bin/redline.ps1" "$DEST/bin/" && cp "$SRC"/rules/*.tsv "$DEST/rules/" && chmod +x "$DEST/bin/redline"
    say "✓ copied redline to $DEST"
  fi
fi

say "agents: ${AGENTS:-none found}  (json engine: $ENGINE)"
IFS=','
for a in $AGENTS; do
  case "$a" in
    claude) do_claude ;; codex) do_codex ;; cursor) do_cursor ;; gemini) do_gemini ;; copilot) do_copilot ;;
    *) say "! unknown agent: $a" ;;
  esac
done
unset IFS

if [ "$UNINSTALL" = 1 ] && [ "$DRY" = 0 ]; then rm -rf "$DEST"; say "✓ removed $DEST"; fi
exit 0
