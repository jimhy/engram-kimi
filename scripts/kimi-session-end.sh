#!/usr/bin/env bash
# engram x kimi - SessionEnd hook (posix). Mirror of kimi-session-end.ps1.
#   kimi 有真正的 SessionEnd（matcher: exit），于是与 Claude 主插件同构：会话收尾时
#     - 由 session_id 解析本场 wire.jsonl（session_index.jsonl → glob 兜底）；
#     - review-prepare 算自水位线以来的增量切片并落 pending；
#     - plan 为 review 时起一个完全脱管的 headless `kimi -p` 复盘者。
#   增量不够也照样落 pending，留给下次 SessionStart 的 catch-up（攒够或重启时巩固）。
#   ENGRAM_REVIEWER guard：复盘者自己的 SessionEnd 直接退出（不递归）。
# Best-effort：任何失败都不得影响会话收尾，恒 exit 0。
[ "$ENGRAM_REVIEWER" = "1" ] && exit 0

# Windows（Git Bash / msys / cygwin 被当作 hook shell 时）→ 转调同名 .ps1；macOS / Linux 继续。
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
  msys*|cygwin*|MINGW*|MSYS*|CYGWIN*|Windows_NT)
    exec powershell -NoProfile -ExecutionPolicy Bypass -File "$script_dir/kimi-session-end.ps1"
    ;;
esac

# 读 hook stdin（session_id / cwd / reason）。3s 硬超时防挂起。
if command -v timeout >/dev/null 2>&1; then
  raw="$(timeout 3 cat 2>/dev/null || true)"
else
  raw="$(cat 2>/dev/null || true)"
fi
jget() { printf '%s' "$raw" | sed -n "s/.*\"$1\"[ ]*:[ ]*\"\\([^\"]*\\)\".*/\\1/p"; }
sid="$(jget session_id)"
cwd="$(jget cwd)"; [ -n "$cwd" ] || cwd="$(pwd)"
[ -n "$sid" ] || exit 0

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_root="${KIMI_PLUGIN_ROOT:-$(dirname "$script_dir")}"
case "$(uname -s)" in
  Darwin) case "$(uname -m)" in arm64|aarch64) bin="engram-macos-aarch64" ;; *) bin="engram-macos-x86_64" ;; esac ;;
  *)      bin="engram-linux-x86_64" ;;
esac
engram="${ENGRAM_BIN:-$plugin_root/bin/$bin}"
[ -x "$engram" ] || exit 0

base="$HOME/.engram/kimi"; work="$base/pending"; wm="$base/watermark.json"

resolve_wire() {
  _sid="$1"; _kh="${KIMI_CODE_HOME:-$HOME/.kimi-code}"; _idx="$_kh/session_index.jsonl"; _sdir=""
  if [ -f "$_idx" ]; then
    _sdir="$(sed -n "s/.*\"sessionId\"[ ]*:[ ]*\"$_sid\".*\"sessionDir\"[ ]*:[ ]*\"\([^\"]*\)\".*/\1/p" "$_idx" | tail -1)"
  fi
  if [ -n "$_sdir" ] && [ -f "$_sdir/agents/main/wire.jsonl" ]; then
    printf '%s' "$_sdir/agents/main/wire.jsonl"; return 0
  fi
  for _f in "$_kh"/sessions/*/"$_sid"/agents/main/wire.jsonl; do
    [ -f "$_f" ] && { printf '%s' "$_f"; return 0; }
  done
  return 1
}

wire="$(resolve_wire "$sid" 2>/dev/null)"
[ -n "$wire" ] || exit 0

# 经引擎解析当前作用域的库路径（从 hook 给的 cwd 向上锚定 .engram/）。
paths="$("$engram" resolve --project-dir "$cwd" --format json 2>/dev/null)"
pget() { printf '%s' "$paths" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\1/p"; }
gdb="$(pget general_db)"; pdb="$(pget project_db)"; pname="$(pget project_name)"

# 切增量 + 落 pending；plan 为 review 时起脱管复盘者（不够本轮增量也留着，攒到下次补跑）。
plan="$("$engram" review-prepare --transcript "$wire" --session-id "$sid" \
  --watermark "$wm" --work-dir "$work" --general-db "$gdb" --project-db "$pdb" --project-name "$pname" 2>/dev/null)"
case "$plan" in
  *'"action":"review"'*)
    bash "$script_dir/kimi-launch-reviewer.sh" "$plan" >/dev/null 2>&1
    ;;
esac
exit 0
